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
| Latencia del mint | **~160 ms (reuso de conexion)**, las 5 muestras, contra un ext_authz de **200 ms fijos** |
| `evaluatorCacheSize` | **sin setear** → cache silenciosamente roto → BLOQUEANTE 1 |
| AuthPolicy de origen | **no existe** → nada inyecta el token → BLOQUEANTE 2 |
| Camino de red en el origen | Gateway, HTTPRoute, ServiceEntry y DestinationRule montados |
| GatewayClass | `openshift-default` presente en 4.18 (OSSM3 3.3.7) |
| CRD AuthPolicy | **sin** `credentials.customHeader.prefix` (dialecto upstream) — no usarlo igual |

## 2. Diseño del ingreso en arqlab — Gateway propio `openshift-default`

**No se reusa `gw-hostnet`.** Dos bloqueos medidos, ninguno resoluble desde esta PoC:

1. **Su listener 443 no tiene certificado.** El `config_dump` del proxy muestra
   `shard1-paas-demo` en `warming`, nunca en `activos` — el bloqueo de SDS del runbook §7.2 sigue
   abierto. Por eso cualquier handshake TLS contra ese gateway resetea (medido desde paas-lab).
   `ResolvedRefs=True` no lo contradice: esa condition en verde con el secret en `warming` **es**
   el hallazgo.
2. **Ninguna `AuthPolicy` sobre él está `Enforced`** (§6). Para una PoC de autorización, esto solo
   ya lo descalifica: aunque el TLS anduviera, no se estaría midiendo nada.

Sobre `openshift-default` las dos cosas funcionan en este mismo cluster (`egress-gw` lo demuestra:
`AuthPolicy` en `Enforced: True`), y `destino-ocp/` ya usó este patrón contra `paas-dev1-lowmz`.

Esta decisión dio tres vueltas en un día. Están las tres, con lo que invalidó cada una, en
`destino-arqlab/00-DECISION-ingreso.md`.

## 3. Nombres y certificado

`app3.paas-demo.bancogalicia.com.ar` es el nombre del camino y la audiencia del token.
DNS y SNI tienen que coincidir con el router default, no con `shard1`:

```
*.apps.paas-arqlab          →  10.254.28.1     IngressController default (HostNetwork)
app3.paas-demo              →  10.254.28.1     A (o CNAME al mismo target que *.apps)
shard1.paas-demo            →  10.254.124.36   F5 de gw-hostnet. TLS RST. NO usar.
```

Medido 2026-09-09: el CNAME `app3 → shard1` mandaba el TLS al F5 de `gw-hostnet` y el
handshake reseteaba (`errno=104`). La Route passthrough está en el router default; contra
`10.254.28.1` + SNI=`app3` el Gateway presenta `CN=shard1.paas-demo` (multi-SAN) y el
handshake completa. El DestinationRule lleva `sni: app3…` porque HAProxy passthrough elige
backend por SNI = host de la Route.

Ese mismo certificado es el sospechoso principal del ingreso al `bff` de arqlab —
ver `destino-arqlab/15-ingress-bff-arqlab.md`.

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
oc --context=paas-lab apply -f origen-paas-lab/00-httproute-bff-lab.yaml
oc --context=paas-lab apply -f origen-paas-lab/18-secret-consumer-bff.yaml
oc --context=paas-lab apply -f origen-paas-lab/19-authpolicy-bff-apikey.yaml

# ── DESTINO arqlab ────────────────────────────────────────────────────────────
# el cert: copiar shard1-paas-demo (su SAN cubre app3) al ns de la PoC — ver 10-gateway-ingress
oc --context=paas-arqlab -n connlink-ingress get secret shard1-paas-demo -o yaml \
  | sed 's/namespace: connlink-ingress/namespace: poc-ingress-kuadrant/' \
  | grep -v '^\s*\(resourceVersion\|uid\|creationTimestamp\|selfLink\)' \
  | oc --context=paas-arqlab apply -f -
oc --context=paas-arqlab apply -f destino-arqlab/10-gateway-ingress.yaml
oc --context=paas-arqlab apply -f destino-arqlab/11-route-passthrough.yaml
oc --context=paas-arqlab apply -f destino-arqlab/12-httproute-backend.yaml
oc --context=paas-arqlab apply -f destino-arqlab/13-authpolicy-vault-spiffe.yaml
# GATE: el cert TIENE que llegar al proxy nuevo. Si queda en `warming` como en gw-hostnet,
# parar acá — es plataforma, no la PoC. Comando en 10-gateway-ingress.yaml.

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

## 6. `gw-hostnet` está roto en dos frentes — elevar, no absorber

Las tres `AuthPolicy` de `poc-ingress-kuadrant` en arqlab están en **`Enforced: False`**
(`waiting for … [Gateway (connlink-ingress/gw-hostnet)]`), y ese mismo proxy **no recibe secrets
por SDS** (dos atascados en `warming`). Esta PoC lo esquiva con su propio Gateway, pero el
problema queda:

**hoy nada publicado por `gw-hostnet` tiene TLS propio ni política de autorización de Kuadrant**,
y su status lo viene diciendo desde que se creó.

Causa raíz del no-enforcement en `destino-arqlab/14-diagnostico-claims.md`; la hipótesis que une
los dos síntomas, y los comandos para confirmarla antes de abrir el caso con Red Hat, en
`destino-arqlab/00-DECISION-ingreso.md`.
