# PoC on-prem — `paas-lab` → `paas-arqlab`, con Vault como emisor

Tercer cluster de la PoC. `paas-lab` (OCP 4.18.45, on-prem) entra como **origen**: su
`bff-cascada` consume `backend` sin cambiar la URL, y ese salto termina en `paas-arqlab`
(OCP 4.21.30), autenticado con un JWT-SVID minteado por Vault.

Primer cruce **on-prem → on-prem** de la PoC. Los otros dos son `poc-egress-kuadrant`
(arqlab → EKS) y `poc-ingress-kuadrant` (EKS → arqlab).

## 1. Estado medido (no supuesto)

Del preflight de federación (`scripts/preflight-paas-lab.sh`, 2026-09-09):

| | |
|---|---|
| Federación con Vault | **funciona** — login con la SA real, policy acotada, mint OK, `kid` en el JWKS |
| `sub` de paas-lab | `spiffe://poc-egress.bancogalicia.com.ar/paas-lab/egress-gw` |
| Mount que autentica | `auth/jwt-paas-lab`. El `jwt-paas-lab1` del paso 2a quedó **huérfano** — borrarlo |
| Latencia del mint | **483-486 ms**, las 5 muestras, contra un ext_authz de **200 ms fijos** |
| `evaluatorCacheSize` | **sin setear** → cache silenciosamente roto → BLOQUEANTE 1 |
| AuthPolicy de origen | **no existe** → nada inyecta el token → BLOQUEANTE 2 |
| Camino de red en el origen | Gateway, HTTPRoute, ServiceEntry y DestinationRule montados |
| GatewayClass | `openshift-default` presente en 4.18 (OSSM3 3.3.7) |
| CRD AuthPolicy | **sin** `credentials.customHeader.prefix` (dialecto upstream) — no usarlo igual |

## 2. Diseño del ingreso en arqlab — se reusa `gw-hostnet`

**Cambió el 2026-09-09.** La versión anterior de este documento montaba un `Gateway`
`openshift-default` propio con una `Route` de passthrough, para esquivar el bloqueo de SDS del
`runbook-gw-istio-hostnetwork.md` §7.2 (el 443 de `gw-hostnet` no recibía el certificado).

**Ese bloqueo está resuelto**: el listener `https:443` de `gw-hostnet` está
`Accepted=True Programmed=True ResolvedRefs=True` con el Secret `shard1-paas-demo`, y ya tiene
3 routes attacheadas. Con el 443 andando, el Gateway propio pasa a ser peor en todo — cuatro
piezas nuevas contra una, un certificado más que mantener, y sobre todo un camino de red que
**no es el de producción**, lo que vuelve menos concluyente cualquier cosa que se mida ahí.

Detalle completo de la reversión en `destino-arqlab/11-DESCARTADO-gateway-propio.md`, incluido
el único caso en que convendría reabrirla.

Del lado destino queda **una sola pieza de red**: la HTTPRoute `backend-lab`. Convive con la
`backend` que ya atiende a EKS sobre el mismo gateway porque los hostnames son distintos:

```
paas-lab (ns poc-egress-kuadrant)   →  Host: backend.poc-egress-kuadrant.svc.cluster.local
EKS      (ns poc-ingress-kuadrant)  →  Host: backend.poc-ingress-kuadrant.svc.cluster.local
```

El gateway de egreso no reescribe el Host: lo que llega es el FQDN interno del origen.

## 3. Nombres y certificado

`app3.paas-demo.bancogalicia.com.ar` ya apunta on-prem (verificado 2026-09-09):

```
app3.paas-demo  →CNAME→  shard1.paas-demo  →A→  10.254.124.36
PTR de 10.254.124.36: *.apps.paas-arqlab.bancogalicia.com.ar  y  shard1.paas-demo...
```

`app3` se usa como **nombre lógico** del camino y como audiencia del token. El **SNI** puede ser
otro: lo decide qué nombres cubre el certificado del listener. `origen-paas-lab/04` arranca con
el recuadro que hay que resolver primero:

```bash
oc --context=paas-arqlab -n connlink-ingress get secret shard1-paas-demo \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -ext subjectAltName -dates
```

Si el SAN trae el wildcard `*.paas-demo…`, poné `sni: app3.paas-demo…` y queda todo uniforme.
Si trae solo `shard1.paas-demo…`, dejá el `sni: shard1…` que viene por defecto. Que `host` y
`sni` difieran es válido y deliberado: uno es el nombre lógico, el otro la identidad TLS.

Ese mismo certificado es el sospechoso principal del ingreso al `bff` de arqlab —
ver `destino-arqlab/12-ingress-bff-arqlab.md`.

**No reusar `app2.paas-demo…`**: apunta al NLB de EKS. Usarlo sería ir a EKS con otro nombre,
un falso positivo silencioso. El preflight de camino lo detecta (C1).

## 4. Orden de aplicación

```bash
# ── ORIGEN paas-lab ───────────────────────────────────────────────────────────
oc --context=paas-lab apply -f origen-paas-lab/01-authorino-cache-size.yaml
oc --context=paas-lab -n kuadrant-system rollout status deployment authorino
oc --context=paas-lab apply -f origen-paas-lab/03-serviceentry-destino.yaml
oc --context=paas-lab apply -f origen-paas-lab/04-destinationrule-tls.yaml   # ver el recuadro
oc --context=paas-lab apply -f origen-paas-lab/02-authpolicy-origen.yaml

# ── DESTINO arqlab ────────────────────────────────────────────────────────────
oc --context=paas-arqlab apply -f destino-arqlab/10-httproute-backend.yaml
oc --context=paas-arqlab apply -f destino-arqlab/13-authpolicy-vault-spiffe.yaml

# ── verificar ANTES del corte ─────────────────────────────────────────────────
CTX_ORI=paas-lab CTX_DST=paas-arqlab ./preflight-camino.sh

# ── EL CORTE, último ──────────────────────────────────────────────────────────
oc --context=paas-lab -n poc-egress-kuadrant patch svc backend --type=merge \
  -p '{"spec":{"selector":{"gateway.networking.k8s.io/gateway-name":"egress-gw"}}}'
```

Revertir el corte es volver el selector a `{"app":"backend"}`. Instantáneo, sin recrear nada.

## 5. Conmutar de destino — tres cosas juntas, no una

La trampa principal. Cambiar el `backendRef` del HTTPRoute **no alcanza**:

| Qué | Dónde | Si no lo movés |
|---|---|---|
| `backendRef` | `HTTPRoute egress-backend` del origen | el tráfico sigue yendo al destino viejo |
| `audience` del mint | `AuthPolicy` de origen, `body.expression` | el destino nuevo rechaza por `aud` |
| `cache.key` | `AuthPolicy` de origen, `metadata.cache` | Authorino sirve hasta **250 s** el token de la audiencia vieja |

El tercero es el que engaña: el 403 aparece con retraso y parece un problema de red.

## 6. Antes de creerle a un 200

`destino-arqlab/14-diagnostico-claims.md`. Está confirmado en vivo que el bloque
`claims-esperados` del destino OCP no rechazaba (pasó un `sub` impostor). Al 2026-09-09 hay dos
hipótesis **refutadas con evidencia** (poda de schema del CRD; istiod que no empuja el
`ext_authz`) y un árbol de decisión que arranca en un único dato todavía sin obtener:
**¿Authorino llegó a ver el request?**

Mientras eso no esté cerrado, un 200 no prueba que la autorización funcione — solo que el
tráfico llega.
