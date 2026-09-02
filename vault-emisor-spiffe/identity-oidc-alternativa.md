# Alternativa sin `spiffe`: `identity/oidc` (Identity Tokens) — DESCARTADA

**Contexto**: compañero de [`vault-emisor-spiffe.md`](vault-emisor-spiffe.md). Se evaluó como
posible alternativa a `spiffe` (con licencia Enterprise ya no siendo un factor) y **se probó en
vivo el 2026-08-28** — el resultado real está en §4: el `sub` del token siempre sale como un UUID
interno de Vault, sin forma de personalizarlo, lo cual es incompatible con el objetivo del
diseño. Queda documentado como antecedente de por qué se descartó, no como opción de respaldo.

## 1. Qué es, y qué NO es, dentro de `identity/oidc`

`identity/oidc` tiene dos funciones separadas que la evaluación original (14/08) trató como una
sola:

| Función | Flujo | M2M |
|---|---|---|
| **OIDC Provider** (`identity/oidc/provider/...`) | Authorization Code Flow, con navegador | No — descartado correctamente en la evaluación original |
| **Identity Tokens** (`identity/oidc/token/:name`) | `GET` directo, con el token de Vault que ya tenés | **Sí** — confirmado en la doc oficial, sin paso interactivo |

Es la segunda la que sirve acá. La evaluación original nunca la miró por separado.

## 2. Los tres pasos de configuración (nuevos respecto de `spiffe`)

`spiffe` necesitaba `trust_domain` + un `role`. `identity/oidc` necesita un paso más — una **key**
con nombre, reutilizable por varios roles:

```
POST /v1/identity/oidc/key/egress-signing-key
{"rotation_period": "24h", "verification_ttl": 86400, "algorithm": "RS256"}

POST /v1/identity/oidc/role/egress-gw
{
  "key": "egress-signing-key",
  "ttl": "300s",
  "client_id": "bff-eks.paas-demo.bancogalicia.com.ar",
  "template": "{\"sub\": \"spiffe://poc-egress.bancogalicia.com.ar/poc/egress-gw\"}"
}

GET /v1/identity/oidc/token/egress-gw
Header: X-Vault-Token: <el mismo token de auth/jwt de siempre>
```

El `template` acepta cualquier forma de `sub`/claims — se puede mantener el formato `spiffe://`
como en el diseño actual, o volver al formato de claims del wristband original
(`src_cluster`/`src_service`/`dst_service`) si en algún momento se prefiere no adoptar la
convención SPIFFE. No hay diferencia de capacidad entre los dos motores en este punto.

## 3. La diferencia real de comportamiento: audiencia fija por `role`, no por request

Con `spiffe/mintjwt`, la `audience` viaja en el body **de cada llamada** — un mismo `role` puede
servir a varios destinos distintos, dinámicamente.

Con `identity/oidc/token/:name`, **no hay body ni query params** — el `GET` no acepta nada. La
audiencia sale del `client_id` configurado en el `role` (se confirmó en la doc: el `client_id` del
role se convierte literalmente en el claim `aud` del token). Esto significa: **si en algún momento
hay más de un destino con distinta audiencia esperada, hace falta un `role` por destino**, no uno
solo reusado dinámicamente.

Para el alcance actual (un solo destino, `bff-eks.paas-demo.bancogalicia.com.ar`) esto no es un
problema — pero es una limitación real a tener en cuenta si la integración crece a más de un
destino.

## 4. Probado en vivo (2026-08-28) — DESCARTADO, el `sub` no se puede personalizar

Se probó de punta a punta contra el mismo Vault, mismo AppRole, mismo namespace `admin/spiffe`:

1. `POST /identity/oidc/key/egress-signing-key` → `204`.
2. `POST /identity/oidc/role/egress-gw` con `template: {"sub": "spiffe://..."}` → **`400`**:
   ```
   top level key "sub" not allowed. Restricted keys: iat, aud, exp, iss, sub, namespace, nonce,
   auth_time, at_hash, c_hash
   ```
   `sub` es una claim **reservada** — Vault la fuerza siempre, el `template` no la puede pisar.
   Esto es una diferencia real respecto de `spiffe`, donde `{"sub": "..."}` en el `template` sí
   funcionó (confirmado en la Ronda de prueba original).
3. Reintentado sin tocar `sub`, y agregando `allowed_client_ids: ["*"]` a la key (hacía falta,
   sin eso el mint también falla) → `GET /identity/oidc/token/egress-gw` → **`200`**, token real:
   ```json
   {
     "aud": "bff-eks.paas-demo.bancogalicia.com.ar",
     "iss": "https://node-60-0...z1.hashicorp.cloud:8202/v1/admin/spiffe/identity/oidc",
     "namespace": "KZQzR",
     "sub": "45dd8733-a8ec-ce27-8c35-2a3d61ed46c7"
   }
   ```
   El `sub` es el **UUID interno de la entity de Vault** (el mismo ID que ya aparecía como dato
   extra, `vault.entity.id`, en el JWT de `spiffe`) — opaco, no portable, sin significado fuera de
   Vault. El `namespace` también sale como un ID interno (`KZQzR`), no el string `admin/spiffe`.

**Conclusión del punto 4: no es solo que `identity/oidc` no aporte nada nuevo — es directamente
incompatible con el objetivo del diseño.** Todo el sentido de esta integración depende de poder
controlar el `sub` (una identidad legible y portable, formato SPIFFE) — que es exactamente lo
único que `identity/oidc` no permite tocar. No es una limitación menor a tener en cuenta, es un
descarte.

(Cleanup pendiente: el `DELETE` del `role`/`key` de prueba dio `412 - required index state not
present`, un error interno de Vault — quedaron los objetos de prueba en `admin/spiffe`, sin
impacto real dado que es un Vault de noprod y son fácilmente identificables por nombre.)

## 5. Conclusión

**Descartado tras la prueba en vivo** — no por falta de licencia (ya tienen Enterprise) ni por
falta de M2M (sí lo tiene) sino por algo más de fondo: el `sub` siempre sale como el UUID interno
de la entity de Vault, sin forma de personalizarlo. `spiffe` sigue siendo la única opción viable
de las evaluadas para esta integración.
