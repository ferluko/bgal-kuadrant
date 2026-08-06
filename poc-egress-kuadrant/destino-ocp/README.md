# Destino OCP — `server2` en `paas-dev1-lowmz`, consumido desde `paas-arqlab`

Tercera variante del destino de la PoC, y la primera que es **un cluster real y distinto**:

| Variante | Dónde vive el destino | Qué ejercita de más | Qué no |
|---|---|---|---|
| [`sim-destino/`](../sim-destino/) | mismo cluster, ns aparte | todo el tramo de egreso, barato y repetible | RTT, skew de reloj, cualquier hop de red |
| **`destino-ocp/`** (este) | **`paas-dev1-lowmz`**, otro sitio | **RTT entre sitios, skew de reloj, router HAProxy, TLS contra un cluster ajeno** | el passthrough L4 de un NLB de AWS |
| [`destino/`](../destino/) | EKS | el diseño objetivo completo | — (bloqueado: clave pública desincronizada, ver [`pedido-jwks-eks.md`](../pedido-jwks-eks.md)) |

El objetivo es el mismo de siempre: `server` sigue consumiendo
`http://server2.echoserver.svc.cluster.local:8080` sin enterarse de nada, y ese salto
ahora termina en otro cluster de otro datacenter, autenticado con el mismo wristband y
los **mismos claims, sin cambiar un solo valor**.

## 1. La pieza que decide todo: por qué la Route va en `passthrough`

Es la única diferencia de fondo con las otras variantes, y conviene entenderla antes de
aplicar nada. El egreso **no reescribe el `Host`** (README de la PoC §4), así que el
request que sale del origen viaja con dos nombres distintos:

```
Host: server2.echoserver.svc.cluster.local:8080     <- el del cliente original
SNI:  app2.paas-demo.bancogalicia.com.ar            <- lo fija origen/04 (DestinationRule)
```

Y el router HAProxy elige el backend con criterios distintos según la terminación:

- **`passthrough`** → trabaja en modo TCP y elige por el **SNI del ClientHello**. No
  descifra, no ve el `Host`. El SNI es `app2...`, que es el host de la Route: matchea, y
  el TLS lo termina el Envoy del Gateway. Es el mismo modelo de confianza que el NLB en
  passthrough del diseño con EKS: el origen valida el certificado del gateway, no el de
  un intermediario.
- **`edge` / `reencrypt`** → termina TLS y elige por el header **`Host`**, que acá es
  `server2.echoserver.svc.cluster.local:8080`. Ninguna Route declara ese host: **503 del
  router**, con un síntoma que no señala a la causa. Y además el origen pasaría a validar
  el certificado del router.

La salida alternativa sería devolver el `URLRewrite` del Host al origen, pero eso choca
con que Istio no soporta filtros a nivel de `backendRef`
([istio#39136](https://github.com/istio/istio/issues/39136)): con dos backends en la
misma rule el filtro aplicaría también al local, y se perdería el split por peso — que es
la herramienta central de la migración progresiva.

Consecuencia agradable: con `passthrough` **no hace falta MetalLB**, cosa oportuna porque
el pool de `paas-dev1-lowmz` sigue en `TBD` (`gitops/values/clusters/paas-dev1-lowmz.yaml`).
El Gateway va ClusterIP y lo publica el router.

## 2. Arquitectura

```
   cliente ──► F5 ──► gw-hostnet ──► server (BFF en cascada)
                                        │  ns echoserver
CLUSTER ORIGEN — paas-arqlab (PGA)      │  GET http://server2.echoserver.svc.cluster.local:8080/
                                        ▼
                             Service server2 (selector -> pods del gateway de egreso)
                                        │
                              ┌─────────┴──────────┐  peso
                              │ Gateway egress-gw  ├────────► server2-local (sin tocar)
                              │ AuthPolicy         │
                              │  wristband RS256   │  x-egress-token
                              └─────────┬──────────┘
                                        │  TLS origination (origen/04)
                                        │  Host: server2.echoserver.svc...  SNI: app2.paas-demo...
════════════════════════════════════════╪═══ WAN PGA ──► Casa Matriz ═══════════════════
                                        ▼
                          ingress VIP 10.254.34.2 : 443
                              router HAProxy  ── elige por SNI ──►  Route passthrough (22)
CLUSTER DESTINO — paas-dev1-lowmz (CMZ)              │   NO descifra, NO ve el Host
ns echoserver                                        ▼
                                    ┌──────────────────────────┐
                                    │ Gateway ingress-gw :443  │ class openshift-default
                                    │ listener sin hostname    │ Envoy termina TLS
                                    ├──────────────────────────┤   con el wildcard del banco
                                    │ AuthPolicy (Kuadrant)    │ valida firma contra
                                    │  jwksUrl -> local (24)   │ el JWKS pineado + claims
                                    └───────────┬──────────────┘
                                                ▼
                                          server2 :8080  (SIM_SITE=dev1-lowmz)
```

## 3. Qué cambia, y qué no

**Del lado origen no cambia nada de nada.** `origen/03`, `origen/04` y las cuatro fases de
`origen/08-rollout/` se aplican verbatim, igual que con el destino simulado, porque el
FQDN y los claims son los mismos. Lo único propio de esta variante es
[`26-serviceentry-origen.yaml`](26-serviceentry-origen.yaml), y **es temporal**: existe
sólo hasta que se mueva el CNAME.

Del lado destino, respecto de `sim-destino/`: `gatewayClassName` sigue siendo
`openshift-default`, el HTTPRoute y la AuthPolicy son idénticos, y se suma un objeto —la
Route de passthrough— más el certificado, que ahora es el wildcard real y no una CA de
laboratorio.

## 4. Prerrequisitos

En el destino hace falta plataforma que hoy **no hay evidencia en el repo** de que esté
instalada en `paas-dev1-lowmz` (el cluster corre OCP 4.20.16, con Day 2 en curso):

1. **GatewayClass `openshift-default`** y **RHCL/Kuadrant**, ambos por
   [`01_apim/13_guia_instalacion_rhcl_ocp420.md`](../../../01_apim/13_guia_instalacion_rhcl_ocp420.md).
   Montarlo acá tiene un beneficio lateral: valida esa guía en un segundo cluster.
2. **Certificado wildcard** `*.paas-demo.bancogalicia.com.ar` con **la cadena completa**
   en `tls.crt`, y su CA raíz cargada en el Secret `destino-ca` del origen.
3. **Camino L3 entre sitios**, PGA (`10.254.28.0/24`) → Casa Matriz (`10.254.34.0/24`),
   TCP 443 contra la ingress VIP. No está documentado en el repo: es el primer gate y, si
   falta, es un pedido a redes que bloquea todo lo demás.
4. En el origen, la PoC en el estado de §6.1 del README: cutover hecho y wristband
   emitiéndose, con `server` corriendo el BFF de [`../../echoserver-cascada/`](../../echoserver-cascada/).

Todo eso lo chequea de una pasada, sin tocar nada:

```bash
CTX_ORI=paas-arqlab CTX_DST=paas-dev1-lowmz ./preflight.sh
```

Además de los gates, imprime tres números que la simulación local no puede dar: RTT +
handshake contra el destino, **skew de reloj entre clusters** —que con `tokenDuration:300`
es un modo de falla real— y a dónde apunta hoy el DNS de `app2`.

## 5. Montaje

### 5.1. Destino (`paas-dev1-lowmz`)

```bash
oc --context=paas-dev1-lowmz apply -f 20-namespace-server2.yaml

oc --context=paas-dev1-lowmz -n echoserver create secret tls paas-demo-wildcard-tls \
  --cert=wildcard.paas-demo.bancogalicia.com.ar.crt \
  --key=wildcard.paas-demo.bancogalicia.com.ar.key

oc --context=paas-dev1-lowmz apply -f 21-gateway-ingress.yaml -f 22-route-passthrough.yaml -f 23-httproute-server2.yaml
```

El JWKS se crea del archivo que produce el origen, nunca pegando `n` y `e` a mano:

```bash
oc --context=paas-dev1-lowmz -n echoserver create configmap jwks-egress-origen \
  --from-file=jwks.json=../keys/out/jwks.json --dry-run=client -o yaml \
  | oc --context=paas-dev1-lowmz apply -f -

oc --context=paas-dev1-lowmz apply -f 24-jwks-static.yaml -f 25-authpolicy-jwt.yaml
```

**No mandar tráfico hasta que la AuthPolicy esté `Enforced`**: attacheada y sin sincronizar
deniega todo.

```bash
oc --context=paas-dev1-lowmz -n echoserver get authpolicy server2-ingress-jwt \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{" "}{.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
```

**Gate del destino** — desde el bastión, sin depender del DNS. Tiene que devolver el
wildcard y un **401**:

```bash
openssl s_client -connect 10.254.34.2:443 -servername app2.paas-demo.bancogalicia.com.ar \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -dates

curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve app2.paas-demo.bancogalicia.com.ar:443:10.254.34.2 \
  -H 'Host: server2.echoserver.svc.cluster.local:8080' \
  https://app2.paas-demo.bancogalicia.com.ar/
```

Si el `subject` es `*.apps.paas-dev1-lowmz...`, el SNI no matcheó la Route de passthrough y
HAProxy cayó en su certificado default. Un **200** en vez del 401 sería peor que un 404:
significaría que el destino contesta sin exigir token.

### 5.2. Origen (`paas-arqlab`) — fase A, sin tocar el DNS

```bash
oc --context=paas-arqlab -n echoserver create secret generic destino-ca \
  --from-file=ca.crt=ca-interna-galicia.pem --from-file=cacert=ca-interna-galicia.pem \
  --dry-run=client -o yaml | oc --context=paas-arqlab apply -f -

oc --context=paas-arqlab apply -n echoserver -f 26-serviceentry-origen.yaml -f ../origen/04-destinationrule-tls.yaml
```

**Esta fase vale mucho más de lo que parece.** Como el SNI lo fija el `DestinationRule` y
no el DNS, el router rutea igual con el endpoint fijado a mano: se valida el 100% del
camino real —L3 entre sitios, handshake contra otro cluster, router HAProxy, Kuadrant
remoto, RTT y skew— **excepto una línea de zona**. Y no hay que coordinar con nadie para
correrla.

### 5.3. La migración, con el ladder del README §6bis

Desde acá es el procedimiento real, sin variantes propias de esta carpeta:

| Fase | Manifiesto | Qué prueba |
|---|---|---|
| 0 — espejo | `../origen/08-rollout/fase0-espejo.yaml` | primer uso de `kind: Hostname`; el espejo llega y da 200, no 401 |
| 1 — canary | `../origen/08-rollout/fase1-canary-header.yaml` | `x-canary: true` → destino; sin header → local |
| 2 — pesos | `../origen/08-rollout/fase2-pesos.yaml` | `weight` sobre `kind: Hostname`; escalera 99/1 → 0/100 |
| 3 — por método | `../origen/08-rollout/fase3-por-metodo.yaml` | GET al destino, escrituras en local |
| 4 — 100% | `../origen/03-httproute-egress.yaml` | estado final |

El reparto se cuenta por el marcador, no comparando hashes de pod:

```bash
for i in $(seq 1 100); do curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ \
  | jq -r '.upstream.body.environment.SIM_SITE // "local"'; done | sort | uniq -c
```

**El espejo (fase 0) duplica escrituras y es del 100% del tráfico** — Istio no soporta
`mirror.percent` en Gateway API. Con `echo-server` da igual; con una app real, no.

## 6. Verificación

La batería de [`../sim-destino/run-escenarios.sh`](../sim-destino/run-escenarios.sh) corre
contra este destino sin forkearla, parametrizada por entorno:

```bash
cd ../sim-destino
CTX_DST=paas-dev1-lowmz NS_SIM=echoserver GW_DST=ingress-gw \
DST_IP=10.254.34.2 SITE=dev1-lowmz ./run-escenarios.sh --aplicar
```

Cubre E0 entorno, E1 camino local con wristband y claims, E2 destino y las negativas (a) y
(b), E3 canary —donde se comprueba que **el destino validó el JWT**, por los
`x-forwarded-src-*`—, E4 pesos con `--pesos` y E5 expiración con `--expirado`. Esta última
recién ahora es interesante: es la primera vez que el `exp` se evalúa contra **otro reloj**.

Y el detalle completo de un request:

```bash
curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ \
  | jq '{st:.upstream.status, ms:.upstream.latencyMs,
         site:(.upstream.body.environment.SIM_SITE // "local"),
         src_cluster:.upstream.body.request.headers["x-forwarded-src-cluster"],
         host_visto:.upstream.body.request.headers.host}'
```

`host_visto` tiene que seguir siendo `server2.echoserver.svc.cluster.local:8080` aunque el
SNI haya sido `app2...`: es la confirmación de que el Host no se reescribe y de que el
router no lo tocó.

## 7. El corte del CNAME — fase B

Es el último paso y el único que cambia estado fuera de los clusters.

```
app2.paas-demo.bancogalicia.com.ar.   CNAME  <lo que publique el router de paas-dev1-lowmz>
```

Después del corte, del lado origen:

```bash
oc --context=paas-arqlab apply -n echoserver -f ../origen/02-serviceentry-destino.yaml
```

que vuelve a `resolution: DNS` sin `endpoints` y deja
[`26-serviceentry-origen.yaml`](26-serviceentry-origen.yaml) sin uso. Verificar que Envoy
tomó el endpoint nuevo, porque es exactamente donde falló la corrida del 2026-08-04:

```bash
POD=$(oc -n echoserver get pod -l gateway.networking.k8s.io/gateway-name=egress-gw -o name | head -1)
oc -n echoserver exec $POD -c istio-proxy -- pilot-agent request GET clusters | grep -F app2.paas-demo
```

**Lo que este corte apaga.** `app2` hoy resuelve al NLB de EKS, así que mover el CNAME
**deja fuera de juego el destino EKS**, que está desplegado y enforceando y sólo espera que
le sincronicen la clave pública ([`pedido-jwks-eks.md`](../pedido-jwks-eks.md)). Es la
decisión tomada: `paas-dev1-lowmz` reemplaza a EKS como destino de la PoC. El rollback es
volver a apuntar el CNAME, o —más rápido y sin depender de DNS— reaplicar
`26-serviceentry-origen.yaml` con la IP del NLB.

Si en algún momento hicieran falta **los dos destinos vivos a la vez**, hay que darle un
FQDN propio a uno de ellos, y eso arrastra el claim `aud`, que hoy **es** el FQDN. Está
desarrollado en el README §8 punto 6, junto con la recomendación de desacoplarlo.

## 8. Qué sigue sin quedar validado

- **El passthrough L4 de un NLB de AWS.** Acá el intermediario es HAProxy, que en
  passthrough se comporta parecido pero no es lo mismo.
- **El pooling de conexiones de un cliente real.** El BFF abre una conexión TCP por
  request, así que el cutover se ve instantáneo. Un cliente con pool persistente mantiene
  conexiones contra los pods viejos hasta que se cierren.
- **La capacidad.** Ni el dimensionamiento del gateway de egreso ni Authorino firmando
  RS256 bajo carga.
- **La multi-tenancy de la clave de firma** (README §8bis, OQ-11). Con un solo consumidor
  no se toca; no confundir "la PoC salió verde" con "el patrón es adoptable".
- **La identidad de workload en el egreso.** Sigue siendo `anonymous` + NetworkPolicy, así
  que los claims de origen son una declaración del manifiesto, no una identidad verificada.

## 9. Desmontar

```bash
oc --context=paas-dev1-lowmz delete ns echoserver
oc --context=paas-arqlab -n echoserver delete serviceentry server2-destino
oc --context=paas-arqlab -n echoserver delete destinationrule server2-destino-tls
oc --context=paas-arqlab apply -n echoserver -f ../origen/08-rollout/fase0a-solo-local.yaml
```

La última línea es la que importa: devuelve el HTTPRoute al estado base sin destino. Sin
eso quedaría un `backendRef` apuntando a un host que ya no existe.

## 10. Archivos

```
20-namespace-server2.yaml     DESTINO: ns + server2 remoto (SIM_SITE=dev1-lowmz)
21-gateway-ingress.yaml       DESTINO: Gateway HTTPS:443 ClusterIP + wildcard real
22-route-passthrough.yaml     DESTINO: publicación por el router HAProxy — la pieza nueva
23-httproute-server2.yaml     DESTINO: ruta a server2, sin hostnames
24-jwks-static.yaml           DESTINO: JWKS pineado (el ConfigMap sale de ../keys/out/)
25-authpolicy-jwt.yaml        DESTINO: validación del wristband, claims sin cambios
26-serviceentry-origen.yaml   ORIGEN: endpoint fijado a la VIP — temporal, hasta el CNAME
preflight.sh                  gates previos, sólo lectura, dos contextos
```
