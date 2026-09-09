# PoC on-prem — `paas-lab` → `paas-arqlab`, con Vault como emisor

Tercer cluster de la PoC. `paas-lab` (OCP 4.18, on-prem) entra como **origen**: su `bff-cascada`
consume `backend` sin cambiar la URL, y ese salto termina en `paas-arqlab` (OCP 4.21),
autenticado con un JWT-SVID minteado por Vault.

Es el primer cruce **on-prem → on-prem** de la PoC. Los otros dos existentes son
`poc-egress-kuadrant` (arqlab → EKS) y `poc-ingress-kuadrant` (EKS → arqlab).

## 1. Estado al 2026-09-09 (medido, no supuesto)

Del preflight de federación (`scripts/preflight-paas-lab.sh`):

| | |
|---|---|
| Federación con Vault | **funciona** — login con la SA real, policy acotada, mint OK, `kid` en el JWKS |
| `sub` de paas-lab | `spiffe://poc-egress.bancogalicia.com.ar/paas-lab/egress-gw` (confirmado en vivo) |
| Mount que autentica | `auth/jwt-paas-lab` — el `jwt-paas-lab1` del paso 2a quedó **huérfano**, borrarlo |
| Latencia del mint | **483-486 ms**, las 5 muestras. Contra un ext_authz de **200 ms fijos** |
| `evaluatorCacheSize` | **sin setear** → cache silenciosamente roto |
| Camino de red | Gateway, HTTPRoute, ServiceEntry y DestinationRule montados |
| AuthPolicy de origen | **no existe** — nada inyecta el token |
| GatewayClass | `openshift-default` presente (OSSM3 3.3.7) → los manifiestos de arqlab portan |

Los dos bloqueantes son `01-authorino-cache-size.yaml` y `02-authpolicy-origen.yaml`.

## 2. Por qué un Gateway nuevo en arqlab y no `gw-hostnet`

`gw-hostnet` (ns `connlink-ingress`, class `ingress-hostnet`) hoy solo tiene listener HTTP:80.
El 443 está bloqueado por el problema de SDS del `runbook-gw-istio-hostnetwork.md` §7.2. Sin TLS
en el destino, el `DestinationRule` del origen no puede originar TLS.

`destino-arqlab/10` usa `openshift-default` + Route `passthrough` — el patrón de
`poc-egress-kuadrant/destino-ocp/`, ya probado en campo. Evita el bloqueo, no necesita MetalLB,
y **es el experimento de control que el propio runbook lista como pendiente**: si acá el cert sí
llega por SDS, queda probado que el problema es el despliegue manual del DaemonSet → caso de
soporte acotado con Red Hat. Si tampoco llega, es un hallazgo de plataforma más amplio.
En los dos casos cerramos una incógnita sin trabajo extra.

## 3. CNAMEs — lo que hay que pedir

**No reusar `app2.paas-demo.bancogalicia.com.ar`**: ese CNAME apunta al NLB de EKS y lo usa
arqlab como origen. Si paas-lab lo reusa, no está probando arqlab — está yendo a EKS con otro
nombre, y es un falso positivo silencioso (el preflight de camino lo detecta, C1).

| FQDN | Apunta a | Estado |
|---|---|---|
| `bff.paas-demo.bancogalicia.com.ar` | `gw-hostnet` de arqlab | existe |
| `app2.paas-demo.bancogalicia.com.ar` | NLB de EKS | existe |
| **`app3.paas-demo.bancogalicia.com.ar`** | **VIP del router de arqlab** | **a pedir** |

Mientras no exista, se destraba con `resolution: STATIC` en el ServiceEntry apuntando a la VIP
(el preflight de camino la descubre e imprime). El wildcard `*.paas-demo` ya cubre el cert.

## 4. Orden de aplicación

```bash
# ── ORIGEN paas-lab ───────────────────────────────────────────────────────────
oc --context=paas-lab apply -f origen-paas-lab/01-authorino-cache-size.yaml
oc --context=paas-lab -n kuadrant-system rollout status deployment authorino
oc --context=paas-lab apply -f origen-paas-lab/03-serviceentry-destino.yaml
oc --context=paas-lab apply -f origen-paas-lab/04-destinationrule-tls.yaml
oc --context=paas-lab apply -f origen-paas-lab/02-authpolicy-origen.yaml

# ── DESTINO arqlab ────────────────────────────────────────────────────────────
oc --context=paas-arqlab apply -f destino-arqlab/10-gateway-ingress.yaml
oc --context=paas-arqlab apply -f destino-arqlab/11-route-passthrough.yaml
oc --context=paas-arqlab apply -f destino-arqlab/12-httproute-backend.yaml
oc --context=paas-arqlab apply -f destino-arqlab/13-authpolicy-vault-spiffe.yaml

# ── verificar ANTES del corte ─────────────────────────────────────────────────
CTX_ORI=paas-lab CTX_DST=paas-arqlab ./preflight-camino.sh

# ── EL CORTE, último ──────────────────────────────────────────────────────────
oc --context=paas-lab -n poc-egress-kuadrant patch svc backend --type=merge \
  -p '{"spec":{"selector":{"gateway.networking.k8s.io/gateway-name":"egress-gw"}}}'
```

Revertir el corte es volver el selector a `{"app":"backend"}`. Instantáneo, sin recrear nada.

## 5. Conmutar de destino — tres cosas juntas, no una

Es la trampa principal de este montaje. Cambiar el `backendRef` del HTTPRoute **no alcanza**:

| Qué | Dónde | Si no lo movés |
|---|---|---|
| `backendRef` | `HTTPRoute egress-backend` | el tráfico sigue yendo al destino viejo |
| `audience` del mint | `AuthPolicy` de origen, `body.expression` | el destino nuevo rechaza por `aud` |
| `cache.key` | `AuthPolicy` de origen, `metadata.cache` | Authorino sirve hasta **250 s** el token de la audiencia vieja |

El tercero es el que engaña: el 403 aparece con retraso y parece un problema de red.
Conmutar y probar dentro de los 250 s siguientes da resultados inconsistentes.

## 6. Antes de creerle a un 200

`destino-arqlab/14-diagnostico-claims.md`. Está **confirmado en vivo** que el bloque
`claims-esperados` del destino OCP no estaba rechazando (pasó un `sub` impostor). La hipótesis
principal es poda silenciosa del campo `predicate` por deriva de schema del CRD — hay evidencia
indirecta: el CRD de paas-lab tampoco tiene `credentials.customHeader.prefix`, que los
manifiestos venían usando.

El preflight de camino (C5) lo chequea directamente: cuenta cuántos `predicate` sobrevivieron
al `apply`. Si el CRD los podó, ese es el hallazgo cerrado.
