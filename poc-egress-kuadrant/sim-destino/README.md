# Destino simulado — migrar `server2` a "EKS" sin EKS

Stand-in local del cluster destino: permite ejercitar la migración completa sin depender del
cluster EKS ni de quien lo administra.

## 1. Por qué existe

Todo el tramo de egreso —`backendRef kind: Hostname`, pesos sobre él, TLS origination, el
espejo, el canary y la validación del wristband del lado destino— sólo se puede probar contra
un destino que exista, esté alcanzable y tenga la clave pública correcta. Depender de eso para
cada iteración vuelve el ciclo de prueba lento y ajeno.

Este kit resuelve las tres cosas dentro del propio cluster, y **sigue siendo útil aunque EKS
esté disponible**: es el banco de pruebas para cambios en los manifiestos del origen sin tocar
el destino real ni pedirle nada a nadie.

**Estado del destino real (2026-08-05):** alcanzable desde un pod del origen en 182 ms, con el
certificado válido y la `AuthPolicy` desplegada y enforceando — pero la clave pública pineada
allá quedó de una versión anterior y rechaza los tokens. Ver [H12](../HALLAZGOS.md#h12) y
[`../pedido-jwks-eks.md`](../pedido-jwks-eks.md).

## 2. Qué ejercita, y qué no

**Sí** — todo lo que figura como no validado en §7.6 del README de la PoC, salvo lo que exige
el destino real:

- `backendRef kind: Hostname` y `weight` sobre él (nunca probado en este cluster).
- `ServiceEntry` `MESH_EXTERNAL` + `resolution: DNS` + 443 declarado `protocol: HTTP`.
- TLS origination del `DestinationRule`: `mode: SIMPLE`, `sni`, y validación contra la CA
  del `credentialName`.
- Que el `Host` interno viaje **sin reescribir** y el destino lo acepte igual (la decisión
  de diseño de §4, que descansa en que el SNI lo fije el `DestinationRule`).
- La validación del wristband del lado destino: firma contra el JWKS pineado y autorización
  por claims.
- `RequestMirror`, canary por header y la escalera de pesos completa.
- **Las pruebas negativas (b), (c) y (d)** del §7.4, que sin destino no se pueden correr.

**No:**

- El RTT inter-cluster ni el handshake TLS sobre WAN. La latencia que midas es sólo Envoy +
  Authorino y va a subir cuando el destino sea real.
- El **skew de reloj entre clusters**. Acá el token nace y muere bajo el mismo reloj, así que
  el modo de falla del `exp: 300` queda intacto. Es de los que más se pagan en producción.
- El passthrough L4 del NLB: acá el TLS lo termina el mismo Envoy, pero sin el balanceador
  de AWS delante.
- El pooling de conexiones de un cliente real: el BFF abre una conexión TCP por request.

## 3. La idea que lo hace sostenible

El `ServiceEntry` de la simulación **conserva el FQDN real** `app2.paas-demo.bancogalicia.com.ar`
y sólo le agrega un bloque `endpoints` que fija dónde vive ese nombre.

Consecuencia: `origen/03`, `origen/04` y las cuatro fases de `origen/08-rollout/` se aplican
**verbatim**. No hay una copia "de simulación" de cada manifiesto para mantener en paralelo.

**Pasar de simulación a real = borrar el bloque `endpoints` de [`06-serviceentry-sim.yaml`](06-serviceentry-sim.yaml)**
y volver a `resolution: DNS`, con lo que el archivo queda idéntico a `origen/02`. Con el destino
real ya alcanzable, ese es el único cambio del lado origen.

## 3bis. La batería de escenarios

[`run-escenarios.sh`](run-escenarios.sh) corre todo lo verificable y da un veredicto por
línea. **Por defecto es de sólo lectura**: reporta lo que hoy es cierto sin tocar nada.

```bash
./run-escenarios.sh
```

| Flag | Qué agrega |
|---|---|
| `--aplicar` | aplica las fases del rollout que cada escenario necesita, y **restaura el estado previo al salir** (trap en EXIT) |
| `--pesos` | reparto 75/25 sobre 100 requests, para probar `weight` sobre `kind: Hostname` |
| `--expirado` | la prueba (c): guarda un token, espera 305 s y lo reusa |

Escenarios: **E0** entorno (incluido el assert anti-loop), **E1** camino local con el
wristband y sus claims, **E2** destino simulado y las negativas (a) y (b), **E3** canary por
header —donde se comprueba que **el destino validó el JWT**—, **E4** pesos, **E5** expiración.

Los **SKIP no son fallos**: indican qué falta montar para que ese escenario tenga sentido.
Correrlo con el destino a medio montar da una lectura útil igual. Sale con código 1 si hubo
alguna FALLA, así que sirve en CI.

## 4. Montaje

Prerrequisito: §6.1 del README de la PoC en verde (cutover local hecho, wristband emitiéndose).

```bash
cd 02_multi-cluster/poc-egress-kuadrant/sim-destino
./00-gen-certs.sh
```

Verificar el SAN antes de seguir — sin él, el handshake falla y el síntoma es un 503
genérico en el gateway de egreso, que no señala a TLS:

```bash
openssl x509 -in out/server.crt -noout -text | grep -A1 'Subject Alternative Name'
```

```bash
oc apply -f 01-namespace-server2.yaml -f 02-gateway-sim.yaml -f 03-httproute-server2.yaml
```

El JWKS se crea del archivo, no pegando `x` e `y` a mano — así no hay forma de que se
desincronice del `kid` real:

```bash
oc -n echoserver-eks-sim create configmap jwks-egress-origen --from-file=jwks.json=../keys/out/jwks.json --dry-run=client -o yaml | oc apply -f -
```

```bash
oc apply -f 04-jwks-static.yaml -f 05-authpolicy-jwt.yaml
```

**No mandar tráfico hasta que la AuthPolicy esté `Enforced`**: attacheada y sin sincronizar
deniega todo.

```bash
oc -n echoserver-eks-sim get authpolicy server2-ingress-jwt -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{" "}{.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
```

Gate del destino simulado — tiene que dar **401**, y eso ya es la prueba negativa (a):

```bash
oc -n echoserver-eks-sim run c$RANDOM --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- curl -sS -o /dev/null -w '%{http_code}\n' -k --resolve app2.paas-demo.bancogalicia.com.ar:443:$(oc -n echoserver-eks-sim get svc ingress-sim-openshift-default -o jsonpath='{.spec.clusterIP}') https://app2.paas-demo.bancogalicia.com.ar/
```

Un **200** acá sería peor que un 404: significaría que el destino contesta sin exigir token.

Recién entonces, del lado origen:

```bash
oc apply -n echoserver -f 06-serviceentry-sim.yaml -f ../origen/04-destinationrule-tls.yaml
```

## 5. La migración, ya con el ladder del README §6bis

Desde acá todo es el procedimiento real, sin variantes. Cada fase con su gate:

| Fase | Manifiesto | Qué prueba |
|---|---|---|
| 0 — espejo | `../origen/08-rollout/fase0-espejo.yaml` | primer uso de `kind: Hostname`; el espejo llega y da 200, no 401 |
| 1 — canary | `../origen/08-rollout/fase1-canary-header.yaml` | `x-canary: true` → destino; sin header → local |
| 2 — pesos | `../origen/08-rollout/fase2-pesos.yaml` | `weight` sobre `kind: Hostname`; escalera 99/1 → 0/100 |
| 3 — por método | `../origen/08-rollout/fase3-por-metodo.yaml` | GET al destino, escrituras en local |
| 4 — 100% | `../origen/03-httproute-egress.yaml` | estado final |

El conteo del reparto no depende de comparar hashes de pod: el `server2` simulado lleva
`SIM_SITE=eks-sim`, así que se lee directo.

```bash
for i in $(seq 1 100); do curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ | jq -r '.upstream.body.environment.SIM_SITE // "local"'; done | sort | uniq -c
```

Y el detalle completo de un request, incluidos los headers que agrega la AuthPolicy del
destino al validar:

```bash
curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ | jq '{st:.upstream.status, ms:.upstream.latencyMs, site:(.upstream.body.environment.SIM_SITE // "local"), src_cluster:.upstream.body.request.headers["x-forwarded-src-cluster"], host_visto:.upstream.body.request.headers.host}'
```

`host_visto` tiene que seguir siendo `server2.echoserver.svc.cluster.local:8080` aunque el
SNI haya sido `app2...`: es la confirmación de que el Host no se reescribe.

**El espejo (fase 0) duplica escrituras y es del 100% del tráfico** — Istio no soporta
`mirror.percent` en Gateway API. Con `echo-server` no importa; con una app real, sí.

## 6. Pruebas negativas, ahora sí ejecutables

```bash
TOKEN=$(curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ | jq -r '.upstream.body.request.headers["x-egress-token"]'); IP=$(oc -n echoserver-eks-sim get svc ingress-sim-openshift-default -o jsonpath='{.spec.clusterIP}'); U="https://app2.paas-demo.bancogalicia.com.ar/"; R="app2.paas-demo.bancogalicia.com.ar:443:$IP"; echo -n "(a) sin token      -> "; oc -n echoserver-eks-sim run n$RANDOM --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- curl -sS -o /dev/null -w '%{http_code}\n' -k --resolve $R $U; echo -n "(b) firma alterada -> "; oc -n echoserver-eks-sim run n$RANDOM --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- curl -sS -o /dev/null -w '%{http_code}\n' -k --resolve $R -H "x-egress-token: ${TOKEN%?}X" $U; echo -n "(valido)           -> "; oc -n echoserver-eks-sim run n$RANDOM --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- curl -sS -o /dev/null -w '%{http_code}\n' -k --resolve $R -H "x-egress-token: $TOKEN" $U
```

Esperado: (a) **401**, (b) **401**, válido **200**.

- **(c) token expirado**: guardar un token, esperar >300 s y reusarlo → 401. Si da 200, el
  verificador no está mirando `exp` y eso invalida el modelo de replay.
- **(d) claims de otro consumidor**: cambiar un `predicate` de [`05-authpolicy-jwt.yaml`](05-authpolicy-jwt.yaml)
  (p. ej. `src_namespace == "otro"`), reaplicar y repetir el request válido → **403**, no
  401. Que sea 403 y no 401 es el punto: distingue "no te reconozco" de "te reconozco y no
  te habilito". Revertir después.

## 7. Desmontar

```bash
oc delete ns echoserver-eks-sim; oc -n echoserver delete serviceentry server2-destino; oc -n echoserver delete destinationrule server2-destino-tls; oc -n echoserver delete secret destino-ca; oc apply -n echoserver -f ../origen/08-rollout/fase0a-solo-local.yaml
```

La última línea es la que importa: devuelve el HTTPRoute al estado base sin destino. Sin
eso quedaría un `backendRef` apuntando a un host que ya no existe.
