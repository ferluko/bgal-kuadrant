# PoC — Egreso seguro con Kuadrant/RHCL: mover `server2` a otro cluster sin tocar `server`

## 1. Objetivo

`server` consume `http://server2.echoserver.svc.cluster.local:8080`. Queremos mover
`server2` a otro cluster **sin modificar la URL de consumo ni el código de `server`**,
que el salto entre clusters sea autenticado y autorizado, y que la migración se pueda
hacer **progresiva y reversible**.

Estrategia (calcada del patrón de [egress gateway de Kuadrant](https://kuadrant.io/blog/egress-gateway-ai-workloads/),
que usa el egress gw para inyectar credenciales en el request saliente):

1. El `Service server2` **no se recrea**: se le cambia el `selector` para que sus endpoints
   pasen a ser los pods del **gateway de egreso** en lugar de los pods de la app. Misma
   ClusterIP, mismo nombre, mismo puerto.
2. El gateway de egreso, con una `AuthPolicy` de Kuadrant, **firma e inyecta un JWT de
   corta vida** (Festival Wristband de Authorino) en el header `x-egress-token`.
3. El gateway origina TLS y manda el request a `app2.paas-demo.bancogalicia.com.ar`, que por
   CNAME apunta al **NLB del cluster EKS destino**.
4. Ahí, el gateway de ingreso **valida la firma contra la clave pineada** y autoriza por claims
   (`iss`, `aud`, `src_cluster`, `src_namespace`). En EKS eso lo hace Kuadrant upstream,
   habilitado por la enmienda del ADR — ver §5.3.
5. El reparto local/remoto se controla con **pesos en el HTTPRoute** del gateway de egreso:
   espejo → canary por header → 1/5/25/50/100%.

Para `server` nada cambió: mismo host, misma IP, mismo puerto, mismo protocolo.

> Para que ese consumo exista de verdad, `server` corre el BFF en cascada de
> [`../echoserver-cascada/`](../echoserver-cascada/) — un `ealen/echo-server` no hace
> llamadas salientes. Ver **§7.0**, que es requisito de toda la validación.

## 1bis. Parámetros

Los manifiestos están escritos con estos valores. Cambiar acá y en los archivos si se
reutiliza el patrón para otro consumidor.

| Parámetro | Valor | Dónde |
|---|---|---|
| Subdominio de la PoC | `*.paas-demo.bancogalicia.com.ar` | certificado wildcard, cubre `app1` y `app2` |
| FQDN de entrada | `app1.paas-demo.bancogalicia.com.ar` | `origen/00` → `gw-hostnet` → `server` |
| FQDN del destino | `app2.paas-demo.bancogalicia.com.ar` | CNAME al NLB de EKS |
| URL interna que NO cambia | `http://server2.echoserver.svc.cluster.local:8080` | lo que consume `server` |
| Cluster origen | `paas-arqlab` — OCP 4.20, IPI vSphere, RHCL 1.3 | |
| Cluster destino | **EKS** | Istio + Gateway API; ver §5.3 |
| Gateway de ingress (origen) | `gw-hostnet` / ns `connlink-ingress` / class `ingress-hostnet` | hostNetwork, publicado por F5 |
| Gateway de egreso (origen) | `egress-gw` / ns `echoserver` / class `openshift-default` | ClusterIP |
| Gateway de ingreso (destino) | `ingress-gw` / ns `echoserver` / class `istio` | NLB internal, passthrough |
| Claim `iss` | `https://egress.paas-arqlab.bancogalicia.com.ar` | |
| Claim `aud` | `app2.paas-demo.bancogalicia.com.ar` | un `aud` por destino |
| Claves de firma | Secret `egress-echoserver-1` en `kuadrant-system` (origen) | ver §2 y §8bis |

## 2. Una corrección al planteo inicial: par de claves en vez de secreto simétrico

Pediste compartir un secreto local al ns que firme el JWT saliente y ese mismo secreto
para reconocerlo en destino. **Authorino no firma HS256** — el wristband soporta
ES256/ES384/ES512 y RS256/384/512 — y su verificador JWT tampoco está pensado para HMAC.

La PoC conserva tu modelo de confianza (clave preacordada, sin IdP, sin dependencia de red
entre clusters) usando un par EC P-256: la **privada vive sólo en el cluster origen** y al destino
se le copia únicamente el **JWKS público**, servido desde un ConfigMap local. Ganás además que un
compromiso del cluster destino no permite falsificar tokens de salida.

**Corrección sobre "local al ns"** (verificado en `paas-arqlab`): esa parte de tu planteo no es
alcanzable con Kuadrant. El operador traduce cada `AuthPolicy` a un `AuthConfig` en
`kuadrant-system`, y Authorino resuelve `signingKeyRefs` contra el namespace del **`AuthConfig`**,
no el del `AuthPolicy`. La clave de firma vive en `kuadrant-system` — namespace de plataforma, no
del equipo de la app.

Esto **no es sólo un cambio de ubicación**: rompe el modelo de aislamiento que buscabas y deja el
patrón sin multi-tenancy hasta que se resuelva. Es una limitación abierta, desarrollada en §8bis y
registrada como **OQ-11**. Si aun así querés HMAC estricto, está el camino en §8.6 (requiere un firmador propio) y
la variante Istio, que sí acepta JWKS `oct`, en
[destino/13a-istio-jwt-validation.yaml](destino/13a-istio-jwt-validation.yaml).

## 3. Arquitectura

```
                    app1.paas-demo.bancogalicia.com.ar
   cliente ──► F5 ──────────────────► gw-hostnet (Envoy hostNetwork, infra-3/4/5)
                                            │  ns connlink-ingress
CLUSTER ORIGEN (paas-arqlab, OCP 4.20)      ▼
ns echoserver                          ┌────────┐
                                       │ server │
                                       └───┬────┘
   GET http://server2.echoserver.svc.cluster.local:8080/   (URL sin cambios)
                                           │
      (1) Service server2 -> selector = pods del gateway (ClusterIP intacta)
                                           ▼
  ┌──────────────────────┐        ┌───────────────┐
  │ Gateway egress-gw    │ peso   │ server2-local │  (pods reales, sin tocar)
  │ listener HTTP :8080  ├───────►│   Service     │
  │ class openshift-def. │        └───────────────┘
  ├──────────────────────┤
  │ AuthPolicy           │  (2) Authorino firma wristband ES256 con el Secret
  │  wristband ES256     │      egress-echoserver-1 (ns kuadrant-system, §8bis)
  │  → x-egress-token    │      claims: iss, aud, src_cluster, src_ns, exp=300s
  └──────────┬───────────┘
             │ peso  (3) TLS origination (DestinationRule).
             │           Host: server2.echoserver.svc.cluster.local  (NO se reescribe)
             │           SNI:  app2.paas-demo.bancogalicia.com.ar
             ▼
   app2.paas-demo.bancogalicia.com.ar  ──CNAME──►  k8s-istiosys-kuadrant-c44863e1bd-bb81ccbd5c06a391.elb.us-east-1.amazonaws.com 
             │
═════════════╪═══════ Direct Connect / VPN hacia la VPC ═══════════════
             ▼
   NLB internal (passthrough L4, NO termina TLS)
             │                              CLUSTER DESTINO — EKS
             ▼                              ns echoserver
                                    ┌──────────────────────────┐
                                    │ Gateway ingress-gw :443  │ class istio
                                    │ listener sin hostname    │ Envoy termina TLS
                                    ├──────────────────────────┤     con el wildcard
                                    │ AuthPolicy (Kuadrant)    │ (4) valida firma
                                    │  jwt.jwksUrl -> local    │     contra JWKS pineado
                                    │  (Opción B, 13b)         │     + claims esperados
                                    └───────────┬──────────────┘
                                                ▼
                                          ┌──────────┐
                                          │ server2  │ :8080
                                          └──────────┘
```

## 4. Decisiones de diseño (y por qué)

| Decisión | Motivo |
|---|---|
| Gateway de egreso **dedicado, en el ns `echoserver`** | (a) Los selectores de Service son namespace-scoped: los pods del gateway tienen que estar en `echoserver` para que `server2` pueda seleccionarlos. (b) `gw-one` en `connlink` queda intacto cumpliendo su rol de ingress. (Este motivo **no** incluye la clave de firma: con Kuadrant vive en `kuadrant-system` — ver §2 y §8bis.) |
| Interceptar cambiando el **`selector`** del Service | Es un `oc patch` de un campo: la ClusterIP no cambia, no hay delete/recreate, no interviene la capa DNS, y el `Deployment server2` **no se toca en ningún momento**. Rollback = el mismo patch al revés, ~1s, sin arranque en frío. Fallback en [alternativas/](alternativas/interceptacion-externalname.yaml). |
| Listener de egreso en **HTTP:8080** | El Service `server2` publica 8080; el cliente no cambia de puerto. |
| `ServiceEntry` con puerto 443 declarado **`protocol: HTTP`** | Patrón oficial de TLS origination en egress gateway: Envoy rutea L7 (necesario para inyectar el header) y el `DestinationRule` hace el upgrade a TLS. Con `HTTPS` sería TCP opaco y no habría inyección. |
| **Sin `URLRewrite` del Host** en el egreso | Con dos backends en la misma rule el filtro aplicaría a los dos, e Istio no soporta filtros a nivel de `backendRef` ([istio#39136](https://github.com/istio/istio/issues/39136)). El Host viaja sin reescribir y el listener del destino no declara `hostname`; el ruteo por F5 y el cert no se ven afectados porque el **SNI lo fija el `DestinationRule`**. |
| Header propio `x-egress-token`, no `Authorization` | El wristband se inyecta crudo, sin prefijo `Bearer`, y así no se pisa una eventual credencial de negocio del request original. |
| `authentication: anonymous` en el egreso | `server` no manda credenciales y no se modifica. El control de quién puede pedir token es la `NetworkPolicy` (07). Endurecimiento en §8. |
| En el destino EKS, validar con **Kuadrant** (`AuthPolicy`) | La enmienda 2026-08-04 del ADR acepta Kuadrant upstream en EKS mientras RHCL/EKS no exista (2027). Mantiene un solo plano de políticas de los dos lados y da convergencia directa a RHCL sin rediseño. A cambio: sin SLA de CVE en el tramo AWS, y hace falta el servidor de JWKS porque Authorino no acepta inline. Ver §5.3. |
| **NLB en passthrough**, TLS terminado por Envoy y no por el balanceador | Mantiene el mismo modelo de confianza que on-prem: el origen valida el wildcard del banco, no un certificado de ACM. Además evita el ruteo por Host de un ALB, que rompería el diseño sin `URLRewrite`. |
| JWKS pineado en el destino (inline o por ConfigMap) | Cero dependencia de red del destino hacia el origen. Con Kuadrant hace falta el ConfigMap + servidor (Authorino no acepta inline); con Istio va inline. |
| `tokenDuration: 300` | Ventana chica de replay sin castigar la latencia (Authorino firma por request; no hay round-trip externo). |

## 5. Pre-requisitos y chequeos previos

### 5.1. Verificación bloqueante — RESUELTA en `paas-arqlab` (2026-08)

Decidía la variante de intercepción. Ambas condiciones dieron a favor de la variante por
**selector**, que es la del camino principal.

```console
$ oc get pods -A -l gateway.networking.k8s.io/gateway-name=gw-one -o wide
NAMESPACE   NAME                                       READY   STATUS    IP            NODE
connlink    gw-one-openshift-default-846df5d46f-xjr8z  1/1     Running   10.129.2.79   ...worker-0-lgp2q
```
El data plane que autodespliega el deployment controller de istiod queda **en el namespace del
Gateway**, no en `openshift-ingress`, y sus pods llevan la label
`gateway.networking.k8s.io/gateway-name`. Es exactamente lo que necesita el selector del Service.

```console
$ oc -n echoserver get svc server2 -o jsonpath='{.spec.selector}{"\n"}{.spec.ports}{"\n"}'
{"app":"server2"}
[{"name":"server-port","port":8080,"protocol":"TCP","targetPort":8080}]
```
`targetPort` es **numérico**, así que el cutover es un patch de un solo campo: el `selector`.
El nombre del puerto (`server-port`) ya está reflejado en `origen/06` y `origen/09`.

> [alternativas/interceptacion-externalname.yaml](alternativas/interceptacion-externalname.yaml)
> queda como contingencia por si en otro cluster el data plane cae en `openshift-ingress`.

### 5.1bis. Por qué NO se usa `spec.infrastructure.labels`

La otra forma de que los pods del gateway lleven la label del selector sería `infrastructure.labels`
en el `Gateway`. **No funciona con `openshift-default`**: el istiod gestionado por el
`cluster-ingress-operator` corre con `PILOT_ENABLE_GATEWAY_API_COPY_LABELS_ANNOTATIONS=false`, así
que ni labels ni annotations del `Gateway` se propagan al pod
(ver [runbook del ingress hostNetwork §1](../poc-ingress-kuadrant/runbook-gw-istio-hostnetwork.md)).
La variante por selector no depende de eso: usa la label que istiod pone de fábrica.

### 5.2. Resto de pre-requisitos

```bash
# RHCL operativo en ambos clusters (guía: 01_apim/13_guia_instalacion_rhcl_ocp420.md)
oc -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'

# CRDs de Istio disponibles (ServiceEntry/DestinationRule los usa el egreso)
oc get crd serviceentries.networking.istio.io destinationrules.networking.istio.io

# Resolución DNS y salida TCP/443 del origen hacia el FQDN del destino
```

> **Riesgo abierto:** el `GatewayClass` `openshift-default` es el Istio gestionado por el
> Ingress Operator. Aplicar `ServiceEntry`/`DestinationRule` propios contra esa malla
> gestionada funciona técnicamente, pero conviene confirmar el alcance de soporte con Red Hat
> antes de llevar el patrón a producción. Si aparece fricción, la salida es un `GatewayClass`
> `istio` propio vía Sail/OSSM sólo para el gateway de egreso.

### 5.2bis. Convivencia con el gateway de ingress hostNetwork

En `paas-arqlab` ya conviven dos implementaciones de Gateway API:

| Clase | Control plane | Gateway | Data plane |
|---|---|---|---|
| `openshift-default` | istiod del `cluster-ingress-operator` (`openshift-ingress`) | `gw-one` (`connlink`) | Deployment autodesplegado, pod CIDR |
| `ingress-hostnet` | `ingress-gw` propio (`istio-ingress-cp`, Sail/OSSM 3.4.0, Istio v1.30.1) | `gw-hostnet` (`connlink-ingress`) | DaemonSet hostNetwork en infra-3/4/5 |

El gateway de egreso de esta PoC usa **`openshift-default`**, no `ingress-hostnet`. El egreso
escucha en 8080 dentro del cluster: no necesita bindear puertos privilegiados ni preservar la IP
de origen, así que no paga ninguno de los costos del camino manual documentados en el
[runbook del ingress](../poc-ingress-kuadrant/runbook-gw-istio-hostnetwork.md) — render+extract del
pod porque el inyector saltea `hostNetwork`, sysctl vía `Tuned`, DaemonSet estático. Y el
autodespliegue es justamente lo que pone la label que usa el cutover.

Dos hallazgos de ese runbook que sí conviene tener presentes acá:

- **El bloqueo de entrega del certificado por SDS** (§7.2 del runbook) está acotado al gateway de
  **despliegue manual**; el de ingreso del cluster destino es autodesplegado y a priori no lo
  hereda. Verificarlo igual antes de dar por bueno el listener 443: `ResolvedRefs=True` **no**
  prueba que el certificado haya llegado al proxy, el indicador confiable es
  `dynamic_active_secrets` en el config dump.
- **Listener 443 sin `hostname`**: el runbook §7.1 llega a la misma conclusión por otro camino
  (con cert multi-SAN conviene omitir `hostname` y dejar el matching a los `HTTPRoute`). Es lo que
  hace `destino/10`, ahí por necesidad del split por peso.

### 5.2ter. Gate previo: Kuadrant sobre `openshift-default`

Toda la PoC asume que una `AuthPolicy` de RHCL attachea y se **enforcea** sobre un Gateway de la
clase `openshift-default`. **Confirmado en agosto 2026: nunca se probó una `AuthPolicy` en este
cluster.** Y el smoke test de la guía de instalación, aunque lo cubriría, no valida la pieza más
incierta de esta PoC: `response.success.headers` con `wristband`.

Por eso está [`00-smoke-wristband/`](00-smoke-wristband/README.md): valida en un solo cluster, sin
TLS ni F5 ni segundo cluster, que (1) la clase rutea, (2) Kuadrant **enforcea** de verdad,
(3) el wristband se firma y se **inyecta** en el request al upstream, y (4) el JWKS que se va a
pinear en el destino verifica esa firma. **Correrlo antes de cualquier otra cosa.**

### 5.3. Pre-requisitos del cluster destino (EKS)

Que el destino sea EKS y no otro OpenShift cambia cuatro cosas. Ninguna es opcional.

1. **Gateway API + Istio en EKS.** `openshift-default` no existe ahí. Hace falta Istio con
   Gateway API habilitado (`gatewayClassName: istio`) y el AWS Load Balancer Controller para
   que las annotations del NLB tengan efecto.

2. **Kuadrant upstream en EKS: aceptado.** RHCL sobre EKS recién estará soportado en 2027, así
   que la condición del ADR de anclar a versiones RHCL es inaplicable en el tramo AWS. La
   [enmienda 2026-08-04 del ADR](../../01_apim/ADR-kuadrant-rhcl-componentes-upstream.md) acepta
   Kuadrant upstream ahí, acotado y con migración comprometida.

   Por eso el destino valida el JWT con `AuthPolicy`
   ([13b](destino/13b-authpolicy-jwt-kuadrant.yaml), **opción recomendada**): mismo plano de
   políticas de los dos lados y convergencia directa cuando salga RHCL/EKS. Requiere también
   `destino/11-jwks-static.yaml` (Authorino no acepta JWKS inline) y habilita
   `destino/14-ratelimitpolicy.yaml`.

   Lo que la excepción **no** cubre y hay que asumir en el tramo AWS: no hay SLA de CVE ni
   respaldo de Red Hat. Fijar versión explícita del operador (no `latest`/`main`) y montar
   vigilancia propia de CVE sobre operator/Authorino/Limitador.

   La alternativa de menor huella —validar con `RequestAuthentication` de Istio, sin Kuadrant en
   EKS— queda documentada en [13a](destino/13a-istio-jwt-validation.yaml).

3. **Conectividad y DNS — el riesgo operativo más grande de la migración.**
   - Ruteo L3 a la VPC: Direct Connect o VPN.
   - `app2.paas-demo.bancogalicia.com.ar` CNAME al NLB. Con NLB `internal` el nombre resuelve
     a IPs privadas: el DNS corporativo tiene que resolver la zona de AWS (forwarding a
     Route53 Resolver o zona privada compartida). **Verificarlo desde un pod del cluster
     origen**, no desde el bastión — el resolver del pod es CoreDNS.
   - **Proxy corporativo:** si la salida obligatoria es por proxy HTTP, este patrón no funciona
     tal cual (Envoy origina TLS directo). O excepción para el rango del NLB, o configurar el
     egress gateway con upstream proxy. Definirlo antes de avanzar.

4. **Certificado.** El wildcard `*.paas-demo.bancogalicia.com.ar` cubre `app1` y `app2` (un
   solo nivel de subdominio), así que sirve el mismo cert del banco de los dos lados. Va como
   Secret TLS en el ns del Gateway de EKS. **No usar ACM**: si el balanceador terminara TLS, el
   origen validaría un certificado de Amazon y habría que cambiar la CA del `DestinationRule`
   (`origen/04`). Es una decisión válida, pero explícita.

### 5.4. Placeholders a reemplazar

| Placeholder | Dónde |
|---|---|
| `app2.paas-demo.bancogalicia.com.ar` | `origen/02`, `origen/03`, `origen/04`, `origen/08-rollout/*`, `destino/10` |
| labels reales del pod `server` | `origen/07` |
| `x` / `y` del JWKS | `destino/11` |

El selector (`app: server2`) y el nombre del puerto (`server-port`) ya están fijados con los
valores reales del cluster en `origen/06` y `origen/09`.

## 6. Orden de aplicación

**Etapa 0 — smoke test.** Sin los cuatro pasos de
[`00-smoke-wristband/`](00-smoke-wristband/README.md) en verde, no arrancar la etapa A: valida
routing, enforcement de Kuadrant, emisión e inyección del wristband, y la verificación de la firma
contra el JWKS que después se pinea en el destino.

**Claves (una vez, desde el bastión):**
```bash
./keys/gen-signing-key.sh
oc --context=origen apply -f keys/out/secret.yaml    # ns kuadrant-system, NO el ns de la app
```

**Etapa A — preparación, cero impacto.** El `Service server2` sigue intacto apuntando a los
pods reales; nada cambia para `server`.

```bash
# Destino (EKS) primero — requiere Istio + Gateway API + Kuadrant upstream (versión fijada)
kubectl --context=eks apply -f destino/10-gateway-ingress.yaml
# cargar el Secret TLS con el wildcard, y crear el CNAME app2 -> NLB (ver destino/10)
# desplegar server2 (mismo manifiesto que en origen) en ns echoserver
kubectl --context=eks apply -f destino/11-jwks-static.yaml            # con x/y del JWKS pegados
kubectl --context=eks apply -f destino/12-httproute-server2.yaml
kubectl --context=eks apply -f destino/13b-authpolicy-jwt-kuadrant.yaml
kubectl --context=eks apply -f destino/14-ratelimitpolicy.yaml        # opcional
#   Alternativa sin Kuadrant en EKS (menor huella, plano de políticas partido):
#   kubectl --context=eks apply -f destino/13a-istio-jwt-validation.yaml   # y omitir 11 y 14

# Origen, sin tocar todavía el Service server2
oc --context=origen apply -f origen/00-httproute-ingress-app1.yaml   # entrada por app1
oc --context=origen apply -f origen/01-gateway-egress.yaml
oc --context=origen apply -f origen/02-serviceentry-destino.yaml
oc --context=origen apply -f origen/03-httproute-egress.yaml
oc --context=origen apply -f origen/04-destinationrule-tls.yaml
oc --context=origen apply -f origen/05-authpolicy-wristband.yaml
oc --context=origen apply -f origen/06-service-server2-local.yaml
oc --context=origen apply -f origen/07-networkpolicy.yaml
```

Validar la cadena completa a mano (§7.1). **Sin esto verde, no se sigue.**

**Etapa B — cutover de la intercepción.** Dos pasos, ambos reversibles:

```bash
# 1) el HTTPRoute vuelve al backend local: el camino cambia, el destino todavía no
oc --context=origen apply -f origen/08-rollout/fase0-espejo.yaml

# 2) el Service pasa a apuntar al gateway (ver origen/09 para el patch exacto)
oc --context=origen -n echoserver get svc server2 -o yaml > /tmp/server2-svc.bak.yaml
oc --context=origen -n echoserver patch svc server2 --type merge -p \
  '{"spec":{"selector":{"gateway.networking.k8s.io/gateway-name":"egress-gw"}}}'
```

Acá el 100% del tráfico entra al gateway y vuelve al `server2` local. Es el momento de
verificar que el Envoy en el medio no rompió nada — latencia, headers, keep-alive, códigos de
error — **antes de mover un solo request al otro cluster**.

**Etapa C — progresivo.** §6bis.

**Etapa D — cierre.** 100% remoto estable N días → escalar a 0 y borrar el `Deployment server2`
del origen y el `Service server2-local`. Punto de no retorno.

## 6bis. Migración progresiva

Una vez hecho el cutover de la intercepción, **todo el reparto se controla desde el HTTPRoute**.
El `Service` no se vuelve a tocar.

| Fase | Manifiesto | % usuarios al destino | Criterio para avanzar | Rollback |
|---|---|---|---|---|
| 0 — espejo | `08-rollout/fase0-espejo.yaml` | 0% (copia descartada) | error rate del espejo ≈ 0, p99 destino aceptable, 0 respuestas 401 | quitar el bloque `filters` |
| 1 — canary dirigido | `08-rollout/fase1-canary-header.yaml` | 0% (opt-in por header) | suite funcional en verde contra el destino, incluidos errores y timeouts | borrar la rule `canary` |
| 2 — pesos | `08-rollout/fase2-pesos.yaml` | 1 → 5 → 25 → 50 → 100 | sin regresión de error rate ni p99 vs el escalón previo, 24-48h por escalón | `weight: 0` al backendRef remoto |
| 3 — por método | `08-rollout/fase3-por-metodo.yaml` | GET primero, escrituras al final | idem | borrar la rule `lecturas-remoto` |
| 4 — 100% | `03-httproute-egress.yaml` | 100% | estable N días | reaplicar la fase 2 con peso bajo |

### Rollback

| Nivel | Acción | Tiempo | Efecto sobre los pods reales |
|---|---|---|---|
| Peso | `weight: 0` al backendRef remoto | segundos, sin rollout | ninguno |
| Fase | reaplicar la fase anterior | segundos | ninguno |
| Intercepción | `oc patch svc server2` restaurando `selector: {app: server2}` | ~1s | ninguno: nunca se detuvieron |

Los tres niveles son reversibles sin recrear objetos y sin cambiar la ClusterIP.

### Condiciones que habilitan el progresivo

Sin esto no hay canary posible, sólo big-bang con ventana. **Verificar antes de la fase 2**:

1. **Datos.** Durante el split hay dos instancias vivas de `server2`. Ambas tienen que llegar a
   los mismos backing stores (DB, colas, cache) y tolerar escrituras concurrentes. Si el destino
   tiene su propia DB, el split por peso parte los datos: no aplica.
2. **Sin estado en memoria/sesión.** El reparto por peso es por request, no pegajoso. Con sesión
   en memoria hace falta consistent hashing o directamente saltear la fase 2.
3. **Latencia.** Cada request al destino suma RTT inter-cluster + handshake TLS. Medir el delta
   en la fase 0 antes de exponer usuarios; el pooling del gateway amortiza el handshake, no el RTT.
4. **Observabilidad.** Hay que poder comparar error rate y p99 local vs destino *durante* el
   split. Sin eso el canary es ciego y no hay criterio objetivo de avance.
5. **Capacidad del gateway.** Con la intercepción activa el gateway entra al camino crítico de
   `server`. Dimensionar réplicas, HPA y PDB antes de la etapa B.

### El otro eje: por consumidor

En la migración real el eje más útil no es el porcentaje sino el **consumidor**. La intercepción
es un `Service` en el ns del consumidor, así que se puede migrar `server2` para un namespace
consumidor a la vez (dev → stg → qas → prd, o por app), dejando el resto sin tocar. Encaja con
la matriz de waves US×CAS; el split por peso queda como herramienta *dentro* de cada wave.

## 7. Validación

### 7.0. Requisito: que `server` realmente llame a `server2`

Toda la PoC asume que `server` consume `http://server2.echoserver.svc.cluster.local:8080`.
**Un `ealen/echo-server` no hace llamadas salientes**: no tiene `BACKEND_URL`, `PROXY` ni
`FORWARD`, sólo refleja el request entrante. Si `server` es un echo-server puro, el salto que
esta PoC migra **no existe**, y toda la validación se apoya en `oc exec ... curl`, que prueba
la red del pod pero no el camino de la aplicación.

El workload de cascada de [`../echoserver-cascada/`](../echoserver-cascada/) lo resuelve:
`server` pasa a ser un BFF mínimo que refleja su propio request **y** le cuelga abajo, en
`.upstream`, la respuesta completa de `server2` (status, headers, body, latencia). `server2`
sigue siendo `ealen/echo-server` sin tocar.

```bash
oc apply -n echoserver \
  -f ../echoserver-cascada/00-configmap-bff.yaml \
  -f ../echoserver-cascada/01-server-bff.yaml
```

Mantiene `app: server` y el puerto 8080, así que el `Service server`, el `HTTPRoute app1`
(`origen/00`) y las policies siguen enganchando sin cambios. Respaldar el Deployment actual
antes de aplicar. Con esto, `curl` desde el bastión a `app1` recorre y muestra los dos hops
en una sola respuesta — que es lo que usan §7.2, §7.3 y §7.4.

### 7.1. Etapa A — pegarle al gateway de egreso a mano

El `Service server2` todavía apunta a los pods locales, así que se prueba el camino nuevo en
paralelo, forzando el `Host`:

```bash
oc -n echoserver run curl --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sS -D- -H 'Host: server2.echoserver.svc.cluster.local' \
  http://egress-gw-openshift-default.echoserver.svc.cluster.local:8080/
```

Esperado: **200** y, en el cuerpo reflejado por el echo server del destino, el header
`x-egress-token` con un JWT y los `x-forwarded-src-cluster` / `x-forwarded-src-namespace`
que agrega la `AuthPolicy` del destino.

Decodificar el token reflejado y **confirmar el `kid`** (ver aviso en `gen-signing-key.sh`):
```bash
echo '<jwt>' | cut -d. -f1 | base64 -d 2>/dev/null; echo
echo '<jwt>' | cut -d. -f2 | base64 -d 2>/dev/null; echo
```

### 7.2. Etapa B — la intercepción tomó efecto sin recrear el Service

```bash
oc -n echoserver get svc server2 -o jsonpath='{.spec.clusterIP}{"\n"}'      # la MISMA de antes
oc -n echoserver get endpointslice -l kubernetes.io/service-name=server2 \
  -o jsonpath='{.items[*].endpoints[*].targetRef.name}{"\n"}'               # pods del gateway
oc -n echoserver exec deploy/server -- \
  curl -sS -o /dev/null -w '%{http_code}\n' http://server2.echoserver.svc.cluster.local:8080/
```
Esperado: ClusterIP intacta, endpoints = pods del gateway, y **200 servido por el `server2`
local** (fase 0).

El mismo chequeo de punta a punta desde el bastión, sin `exec`, si `server` corre el BFF en
cascada (§7.0):

```bash
curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ \
  | jq '{status: .upstream.status, ms: .upstream.latencyMs,
         token: (.upstream.body.request.headers["x-egress-token"] != null)}'
```

### 7.3. Etapa C — reparto efectivo

> **Corrección (2026-08-04).** La versión anterior de esta sección contaba pods con
> `grep -o 'server2[a-z0-9-]*'` sobre la respuesta, dando por hecho que "el echo server
> refleja el hostname del pod que atiende". **No lo hace.** Verificado contra
> `ealen/echo-server:0.9.2`: `.host.hostname` es el **header `Host`** del request y
> `.host.ip` es la **IP del cliente**. Como el request va con
> `Host: server2.echoserver.svc.cluster.local`, ese `grep` matcheaba el propio Host y daba
> 100 % "local" viniera la respuesta de donde viniera — el reparto se veía siempre correcto
> aunque el canary estuviera roto.
>
> El único dato del pod es `.environment.HOSTNAME`, que exige `ENABLE__ENVIRONMENT=true` en
> el `server2` de **los dos** clusters (ver
> [`echoserver-cascada/02-server2-echo.yaml`](../echoserver-cascada/02-server2-echo.yaml)).

Con eso, el reparto se cuenta desde el bastión sin instrumentar nada:

```bash
for i in $(seq 1 100); do
  curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ \
    | jq -r '.upstream.body.environment.HOSTNAME'
done | sort | uniq -c
```
Con `weight` 75/25 esperar ~75 respuestas del pod local y ~25 del pod del destino. Si alguna
línea sale `null`, a ese `server2` le falta `ENABLE__ENVIRONMENT=true`.

Sanity check obligatorio antes de creerle al conteo: los dos hostnames tienen que ser
**distintos entre sí** y distintos del FQDN del Service.

Canary por header (fase 1):
```bash
curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' -H 'x-canary: true' http://10.254.28.68/ \
  | jq '{pod: .upstream.body.environment.HOSTNAME, ip_origen: .upstream.body.host.ip}'
```
`ip_origen` es la IP de origen **tal como la ve `server2`**: con tráfico local es la IP del
pod `server`; una vez interceptado, la del pod del gateway de egreso. Es la señal más directa
de que la intercepción tomó efecto.

### 7.4. Pruebas negativas (sin esto la PoC no prueba nada)

Correrlas **en cada fase**: el bypass tiene que seguir dando 401 aunque el split esté al 50%.

```bash
# a) Bypass del gateway: request directo al destino sin token -> 401
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://app2.paas-demo.bancogalicia.com.ar/

# b) Token manipulado (cambiar un char de la firma) -> 401
# c) Token expirado (esperar >300s y reusar uno viejo) -> 401
# d) Token válido con claims de otro consumidor -> 403
# e) Otro pod del ns origen intentando obtener token -> bloqueado por NetworkPolicy
```

### 7.5. Rollback en caliente

Con carga corriendo, peso remoto a 0 y verificar 100% local sin errores en el cliente; después
probar el rollback de intercepción (`patch` del selector) y verificar lo mismo.

## 8. Qué falta para producción

1. **Identidad de workload real en el egreso.** Hoy es `anonymous` + `NetworkPolicy`. Lo correcto
   es que el gateway autentique al llamador: con `server` en la malla, mTLS y
   `authentication.x509` / principal de Istio; o `kubernetesTokenReview` del SA token si se
   acepta tocar la app. Ese principal debe ir al claim `sub` del wristband, y el destino
   autorizar por `sub` en vez de por constantes.
2. **Rotación de la clave de firma.** `signingKeyRefs` acepta lista: se agrega la clave nueva, se
   publica el JWKS con ambas en el destino, se rota y se retira la vieja. Distribuir la privada
   con ESO/Vault (ver ADR-0004) hacia `kuadrant-system`, nunca en git.
3. **Un gateway de egreso por dominio, no por ns.** Un gateway compartido con una `AuthPolicy`
   por `HTTPRoute` escala mejor, y ahora es más simple de lo que parecía: como las claves viven
   en `kuadrant-system` de todos modos, no hay nada que "repartir" por namespace. Ojo: con un
   gateway compartido el listener del destino vuelve a necesitar `hostname` y se pierde el split
   por peso (§4).
4. **Observabilidad.** Métricas del gateway de egreso por backend + trazas con `traceparent`
   propagado, para poder responder "¿el 500 fue de `server2` o del salto entre clusters?".
   Es además el criterio de avance de las fases.
5. **`aud` por destino.** Un `aud` distinto por servicio destino evita que un token emitido para
   `server2` sirva contra otro backend del mismo gateway de ingreso.
6. **Si se insiste con HMAC:** agregar un firmador propio (Deployment que lee el Secret y expone
   `/token`), invocarlo desde `metadata.http` del `AuthPolicy` de egreso con `cache.ttl`, e
   inyectar el resultado con `plain.expression`. Validación en destino con `RequestAuthentication`
   + JWKS `oct`. Más piezas, el secreto replicado en ambos clusters, y sin la asimetría que hace
   seguro el esquema actual — por eso no es el default.
7. **Multi-tenancy de la clave de firma — ver §8bis. Es una limitación abierta, no un pendiente
   menor: si no se resuelve, el patrón no es multi-tenant.**

## 8bis. Limitación abierta: dónde vive la clave de firma y quién puede usarla

<!-- OPEN_QUESTION: OQ-11 — ver docs/state/OPEN_QUESTIONS.md -->

**Esto es una limitación de diseño no explorada del todo. Está sin resolver y condiciona la
adopción del patrón más allá de un PoC de un solo consumidor.**

### Lo que se observó (evidencia, `paas-arqlab` 2026-08)

Kuadrant traduce cada `AuthPolicy` a un `AuthConfig` en **`kuadrant-system`**, sin importar el
namespace del `AuthPolicy`. Authorino resuelve `signingKeyRefs` contra el namespace del
`AuthConfig`. Con el Secret en el ns de la app:

```
Reconciler error ... "AuthConfig":{"name":"ab6349c1...","namespace":"kuadrant-system"},
                     "error":"Secret \"egress-echoserver-1\" not found"
```

### Lo que dice la API de Authorino

- `wristband.signingKeyRefs` acepta **sólo `name`**: no hay campo `namespace`. El Secret debe
  estar en el namespace del `AuthConfig`.
- Authorino **sí tiene** el mecanismo de referencia cross-namespace, pero **sólo para `apiKey`**:
  `allNamespaces: true` (requiere instancia cluster-wide) más el label
  `authorino.kuadrant.io/managed-by=authorino` del `--secret-label-selector`. No hay equivalente
  para `signingKeyRefs`.

O sea: la hipótesis de que los secretos deberían poder vivir en otros namespaces **es coherente
con el producto** — el mecanismo existe y está implementado para otro evaluador — pero **hoy no
está expuesto para el wristband**.

### Las dos consecuencias, que son problemas distintos

**(a) Operativa.** La clave de firma de un consumidor no puede vivir en su namespace. Todas las
claves de todos los consumidores se concentran en `kuadrant-system`, que es de plataforma. El
`ExternalSecret` de ESO/Vault tiene que apuntar ahí, y el equipo de la app pierde ownership de su
propia credencial.

**(b) Autorización — la grave.** Como `signingKeyRefs` referencia **por nombre** dentro de
`kuadrant-system`, cualquier `AuthPolicy` de cualquier namespace podría pedirle a Authorino que
firme con cualquier clave de ahí. Un equipo con permiso de crear `AuthPolicy` en su propio
namespace podría emitir tokens con `src_namespace: echoserver` y el destino los aceptaría: son
criptográficamente idénticos a los legítimos. **Los claims de origen son una declaración del
manifiesto, no una identidad verificada.**

Ojo con no confundirlas: resolver (a) **no** resuelve (b) automáticamente. Si mañana
`signingKeyRefs` aceptara `allNamespaces` + label selector, un `AuthPolicy` de cualquier namespace
podría seleccionar por label un Secret de otro — sería peor, no mejor, salvo que venga con scoping
adicional. Lo que sí resolvería (b) es que **Kuadrant cree el `AuthConfig` en el namespace del
`AuthPolicy`**: ahí el RBAC sobre Secrets de ese namespace pasa a ser el control de acceso a la
clave, que es el modelo que uno espera.

### Lo que NO se probó

| # | Pregunta | Cómo probarlo |
|---|---|---|
| 1 | ¿Se puede hacer que Kuadrant cree el `AuthConfig` en el ns del `AuthPolicy`? | Revisar opciones del CR `Kuadrant` / del operador RHCL 1.3. Si no existe, es un feature request upstream. |
| 2 | ¿RHCL restringe qué Secret de `kuadrant-system` puede referenciar un `AuthPolicy` según su namespace de origen? | Crear un `AuthPolicy` en un ns ajeno referenciando `egress-echoserver-1` y ver si emite token. **Este es el experimento decisivo.** |
| 3 | ¿Hay algún `allNamespaces` no documentado para `signingKeyRefs`? | `oc explain authconfigs.spec.response.success.headers.wristband.signingKeyRefs` contra el CRD instalado. |
| 4 | ¿Cambia algo con una instancia de Authorino namespaced en vez de cluster-wide? | Fuera del modelo de RHCL, pero acota el blast radius si fuera viable. |

### Mitigación provisoria (no sustituye la resolución)

- **RBAC sobre `AuthPolicy`**: tratar las policies de egreso como objeto de **plataforma**, no de
  los equipos de aplicación. Encaja con `gitops/docs/ADR-rbac-multitier-gitops.md`.
- **`sub` de identidad real de workload** (§8.1) en vez de claims estáticos, para que el token
  diga *quién* llamó y no *quién dice el manifiesto que llamó*. Es el único arreglo de fondo de (b)
  que no depende de un cambio en Kuadrant.
- **Una clave por consumidor** igual conviene: no aísla por sí sola, pero acota la rotación y
  permite que el destino mapee `kid` → consumidor esperado.

Mientras esto siga abierto, el patrón es válido para **un consumidor de plataforma**, no para
self-service multi-equipo.

## 9. Archivos

```
00-smoke-wristband/                            GATE PREVIO: AuthPolicy + wristband en 1 cluster
  01-gateway-smoke.yaml                        gateway efímero HTTP:8080
  02-httproute-smoke.yaml                      ruta al server2 local (refleja headers)
  03-authpolicy-denyall.yaml                   paso 2: ¿Kuadrant enforcea?
  04-authpolicy-wristband.yaml                 paso 3: firma e inyección del JWT
  check-token.py                               paso 4: claims, kid y firma (stdlib + openssl)
keys/gen-signing-key.sh                        claves ES256 + Secret + JWKS
origen/00-httproute-ingress-app1.yaml          entrada: app1 -> gw-hostnet -> server
origen/01-gateway-egress.yaml                  Gateway de egreso HTTP:8080 (ns echoserver)
origen/02-serviceentry-destino.yaml            registro del host remoto
origen/03-httproute-egress.yaml                ruta base: 100% al destino (etapa A y fase 4)
origen/04-destinationrule-tls.yaml             TLS origination + SNI
origen/05-authpolicy-wristband.yaml            firma e inyección del JWT
origen/06-service-server2-local.yaml           Service aditivo -> pods reales (backend del canary)
origen/07-networkpolicy.yaml                   quién puede pedir token + camino local
origen/08-rollout/fase0-espejo.yaml            espejo, cero impacto
origen/08-rollout/fase1-canary-header.yaml     canary por header x-canary
origen/08-rollout/fase2-pesos.yaml             reparto 1/5/25/50/100
origen/08-rollout/fase3-por-metodo.yaml        GET al destino, escrituras en local
origen/09-cutover-service-selector.yaml        CUTOVER: patch del selector (aplicar último)
destino/10-gateway-ingress.yaml                EKS: Gateway class istio + NLB internal passthrough
destino/12-httproute-server2.yaml              ruta a server2 (hostname interno)
destino/11-jwks-static.yaml                    servidor de JWKS pineado (Opción B)
destino/13b-authpolicy-jwt-kuadrant.yaml       OPCIÓN B (recomendada): Kuadrant upstream en EKS
destino/13a-istio-jwt-validation.yaml          OPCIÓN A: Istio, JWKS inline — menor huella
destino/14-ratelimitpolicy.yaml                cuota por origen (Opción B, opcional)
alternativas/interceptacion-externalname.yaml  fallback si los pods del gw no están en el ns
```

Fuera de este directorio, pero requisito de la validación (§7.0):

```
../echoserver-cascada/00-configmap-bff.yaml    BFF de cascada (stdlib de Python, sin build)
../echoserver-cascada/01-server-bff.yaml       server = BFF: refleja Y llama a server2
../echoserver-cascada/02-server2-echo.yaml     server2 = ealen/echo-server (PORT=8080,
                                               ENABLE__ENVIRONMENT=true — ver §7.3)
../echoserver-cascada/test-cascada.sh          smoke de la cascada desde el bastión
```

## 10. Referencias

- [Kuadrant — Egress gateway for AI workloads](https://kuadrant.io/blog/egress-gateway-ai-workloads/)
- [Authorino — Features (Festival Wristband, JWT verification, credentials)](https://docs.kuadrant.io/latest/authorino/docs/features/)
- [Kuadrant — AuthPolicy reference](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/authpolicy/)
- [Istio — Egress gateway con TLS origination](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/)
- [Istio — Egress gateways (backendRef `kind: Hostname`)](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/)
- [istio#39136 — filtros a nivel de backendRef no soportados](https://github.com/istio/istio/issues/39136)
- [istio#49999 — `mirror.percent` no soportado en Gateway API](https://github.com/istio/istio/issues/49999)
- Interno: [01_apim/13_guia_instalacion_rhcl_ocp420.md](../../01_apim/13_guia_instalacion_rhcl_ocp420.md) — instalación de RHCL y smoke test
- Interno: [poc-ingress-kuadrant/runbook-gw-istio-hostnetwork.md](../poc-ingress-kuadrant/runbook-gw-istio-hostnetwork.md) — gateway Istio hostNetwork como ingress en el mismo cluster
