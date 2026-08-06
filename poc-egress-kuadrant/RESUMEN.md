# Egreso seguro entre clusters con Kuadrant — resumen técnico

**PoC cerrada en `paas-arqlab` el 2026-08-05. 37 chequeos automatizados, todos en verde.**

Cómo mover un servicio a otro cluster sin tocar a quien lo consume, con el salto autenticado y
la migración reversible en cualquier momento.

---

## 1. El problema

`server` consume `http://server2.echoserver.svc.cluster.local:8080`. Queremos mover `server2` a
otro cluster (EKS) con tres condiciones:

1. **Sin tocar el código ni la URL de `server`.** Mismo host, misma IP, mismo puerto.
2. **Con el salto entre clusters autenticado**, sin depender de un IdP ni de conectividad
   permanente entre los dos lados.
3. **Migración progresiva y reversible**, no big-bang con ventana.

## 2. La idea

Tres piezas, ninguna nueva:

**Interceptar por selector.** El `Service server2` no se recrea: se le cambia el `selector` para
que sus endpoints pasen a ser los pods de un gateway de egreso. Misma ClusterIP, mismo nombre,
mismo puerto. Para el cliente no cambió nada. El rollback es el mismo `patch` al revés, en
aproximadamente un segundo y sin arranque en frío.

**Firmar en la salida.** Ese gateway, con una `AuthPolicy` de Kuadrant, emite un JWT de corta
vida (300 s) firmado con una clave que vive sólo en el cluster origen, y lo inyecta en el header
`x-egress-token`. Al destino se le copia únicamente la clave **pública**.

**Repartir por peso.** Con el `Service` ya interceptado, todo el reparto local/remoto se controla
desde el `HTTPRoute`: espejo → canary por header → 1/5/25/50/100 %. El `Service` no se vuelve a
tocar.

```
cliente ──► F5 ──► Envoy ingress ──► server ──► [Service server2]
                                                      │  selector cambiado
                                                      ▼
                                            Gateway de egreso ── firma el JWT
                                                 │        │
                                          peso   │        │  peso
                                                 ▼        ▼
                                          server2 local   TLS ──► destino
                                                                    valida firma
                                                                    y claims
```

## 3. Qué se probó, y con qué resultado

La batería [`sim-destino/run-escenarios.sh`](sim-destino/run-escenarios.sh) corre 37 chequeos con
veredicto por línea. Última corrida:

| Escenario | Qué demuestra | Resultado |
|---|---|---|
| **E0** Entorno | el punto de partida es el que la PoC asume, incluido el assert anti-loop | ✅ |
| **E1** Camino local | el tráfico atraviesa el Envoy de egreso, el `Host` no se reescribe, el wristband se emite con sus 5 claims y vive 300 s | ✅ |
| **E2** Destino | valida la firma contra el JWKS pineado; rechaza sin token, con firma alterada y con basura | ✅ |
| **E3** Canary | `x-canary: true` va al destino **y el destino lo autoriza**; sin el header, el tráfico normal ni se entera | ✅ |
| **E4** Pesos | reparto 75/25 sobre un `backendRef kind: Hostname` → 71/29 medido, cero errores | ✅ |

Números que importan:

- **Costo de la intercepción:** 10,4 ms directo → ~12 ms con el Envoy en el medio → ~21 ms con
  Authorino firmando. Sobre tráfico interno, sin RTT real.
- **La ClusterIP nunca cambió** (`172.30.169.54`) y los pods de `server2` nunca se detuvieron.
- **La señal de que la intercepción tomó efecto** es que la IP de origen que ve el backend pasa
  de la del pod `server` a la del pod del gateway. No hay que instrumentar nada para verla.

Para que esto fuera verificable hizo falta un workload que realmente encadene: un echo server
suelto no hace llamadas salientes, así que el salto a migrar no existía. Ver
[`../echoserver-cascada/`](../echoserver-cascada/) y [H1](HALLAZGOS.md#h1).

## 4. Qué NO se probó

Verde acá significa *"la mecánica funciona"*. No significa:

- **El tramo de punta a punta contra el destino real.** El cluster EKS está alcanzable, con la
  política desplegada y enforceando, y el certificado válido — pero **la clave pública pineada allá
  quedó de una versión anterior**, así que todavía rechaza los tokens. Falta sincronizarla
  ([`pedido-jwks-eks.md`](pedido-jwks-eks.md)); nada del lado origen cambia. Todo lo que se validó
  hasta ahora se hizo contra un stand-in local ([`sim-destino/`](sim-destino/)) que conserva el
  FQDN real.
- **RTT inter-cluster ni skew de reloj.** El token nace y muere bajo el mismo reloj, así que el
  modo de falla del `exp: 300` entre clusters queda intacto. Es de los que más se pagan en
  producción.
- **Capacidad.** Ninguna prueba de carga. El gateway pasa a estar en el camino crítico de la app.
- **Clientes con pool de conexiones.** El BFF abre una conexión TCP por request, así que el
  cutover se ve instantáneo y sin errores. Un cliente con pool persistente (JVM, Go) va a tener
  una cola que esta PoC no puede mostrar.

## 5. Tres hallazgos que cambian decisiones

El detalle completo, con evidencia, está en [HALLAZGOS.md](HALLAZGOS.md). Los que afectan
decisiones ya tomadas:

**Authorino no valida su propio wristband con la configuración obvia** ([H9](HALLAZGOS.md#h9)).
Su verificador acepta sólo RS256; su firmador acepta RS256 pero lee la clave sólo en PKCS#1, y
`openssl genrsa` emite PKCS#8 por default. Con EC —el diseño original— el destino rechaza el
100 % de los tokens con un 401 indistinguible de "falta el token", con todo lo demás en verde.
La única combinación que cierra es **RSA 2048 en PKCS#1**. Esto **aplica igual al destino real**:
la Opción B del ADR es viable, pero no como está documentada hoy.

**La `AuthPolicy` de egreso es un punto único de falla del camino de la app.** Una clave que
Authorino no puede parsear deja su `AuthConfig` sin reconciliar, el `ext_authz` falla cerrado y
`server` deja de responder — aunque el destino no tenga nada que ver. Por eso el cutover va en
dos pasos: primero el selector, después la política.

**`x-request-id` no sirve para correlacionar entre clusters** ([H10](HALLAZGOS.md#h10)): el
gateway de egreso lo regenera. Hay que resolverlo con `traceparent` o un `EnvoyFilter`, y
conviene decidirlo antes de que existan dos clusters.

Un patrón que se repitió y vale como advertencia: **todos los problemas daban verde en algún
lado**. Ningún objeto en rojo, ningún error visible. Los detectaron chequeos que miran el efecto
—qué pod contestó, qué IP vio el backend, qué headers llegaron— y no el estado declarado.

## 6. Qué falta para producción

Por orden de peso:

1. **Identidad real del llamador.** Hoy el gateway de egreso autentica con `anonymous` y el
   control de quién puede pedir un token es la `NetworkPolicy`. Lo correcto es mTLS de la malla o
   `kubernetesTokenReview`, con el principal en el claim `sub` y el destino autorizando por ahí.
   Ojo: ya aparece un `sub` en los tokens, pero lo deriva Authorino de `anonymous` y **no
   identifica a nadie** ([H11](HALLAZGOS.md#h11)).
2. **Multi-tenancy de la clave de firma.** Kuadrant obliga a que viva en `kuadrant-system`, o sea
   en un namespace de plataforma y no del equipo de la app. Es una **limitación abierta**: sin
   resolverla, el patrón no es multi-tenant. Ver §8bis del README.
3. **Sincronizar la clave pública en el destino.** Es lo único que falta para cerrar el camino de
   punta a punta contra EKS, y no depende de nosotros: ver [`pedido-jwks-eks.md`](pedido-jwks-eks.md).
   En la misma ventana conviene cargar la cadena de la CA del destino en el Secret `destino-ca`
   del origen, para poder validar TLS sin `insecureSkipVerify`.
4. **Subdominio privado y estrategia de tráfico east-west.** Hoy el salto usa la zona de
   publicación de aplicaciones, con nombres de laboratorio. Conviene una zona interna dedicada al
   tráfico entre clusters, on-prem ↔ cloud: no mezcla clases de exposición y no publica IPs
   privadas de la VPC en la zona de apps. Se puede cambiar sin rediseño —ese FQDN no viaja en
   ningún header, sólo resuelve una IP y elige un certificado— pero hay que definir convención de
   nombres, emisión y rotación de certificados, y resolución desde CoreDNS. Ver §8.5 del README.
5. **Rotación de la clave**, y un `aud` por destino **desacoplado del hostname**: hoy el `aud`
   *es* el FQDN, así que renombrar el dominio rompe el contrato del token. Va junto con el punto 4.
6. **Observabilidad**: métricas por backend y trazas propagadas, que además son el criterio
   objetivo para avanzar de fase en el rollout.

## 7. Por dónde seguir

| Quiero… | Ir a |
|---|---|
| el diseño y el procedimiento completos | [README.md](README.md) |
| el detalle de los hallazgos, con evidencia | [HALLAZGOS.md](HALLAZGOS.md) |
| correr la batería de escenarios | [`sim-destino/run-escenarios.sh`](sim-destino/run-escenarios.sh) |
| montar el destino simulado | [`sim-destino/README.md`](sim-destino/README.md) |
| lo que hay que pedirle al admin de EKS | [pedido-jwks-eks.md](pedido-jwks-eks.md) |
| el workload que hace la cascada | [`../echoserver-cascada/`](../echoserver-cascada/) |
