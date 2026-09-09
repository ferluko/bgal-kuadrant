# Vault como emisor de identidad para el flujo OCP↔EKS (vía SPIFFE)

**Para**: SegInf
**De**: equipo PoC Kuadrant (EKS↔OCP)
**Fecha**: 2026-08-25 (revisión de la evaluación original del 2026-08-14)
**Contexto**: se evaluó si Vault podía ocupar el rol de **emisor** (quien firma el token que
`bff`/`egress-gw` presenta al cruzar de cluster) del flujo `client_credentials` M2M, como
alternativa a Keycloak (evaluación de Keycloak/Cognito descartada de este directorio — la decisión
final quedó en Vault, ver conclusión abajo).

> **Este documento reemplaza la conclusión de la evaluación original (2026-08-14, archivada más
> abajo en el Apéndice).** En ese momento se descartó a Vault como emisor. Una revisión posterior encontró
> una pieza de Vault que no se había evaluado — el **secrets engine `spiffe`** — que cierra
> exactamente el hueco que motivó el descarte. La conclusión actual es que **Vault sí es viable**
> como emisor, con este mecanismo específico.

## 0. Nota de plataforma — ServiceAccounts `default` compartidas (hallazgo aparte, no bloqueante)

Durante el diseño del `AuthConfig` real
([`01-authpolicy-origen-eks.yaml`](../poc-ingress-kuadrant/eks-origen/vault/01-authpolicy-origen-eks.yaml))
surgió que, hoy, prácticamente todos los workloads de este cluster corren bajo la ServiceAccount
`default` del namespace, en vez de una dedicada por workload. Esto no es un problema de esta
integración puntual — es una debilidad de higiene de identidad más general: cualquier mecanismo
que dependa de "qué ServiceAccount es esto" (RBAC, `NetworkPolicy`, y ahora la identidad hacia
Vault) no puede distinguir un workload de otro mientras compartan `default`.

**No bloquea nada de lo de acá** — la integración con Vault sigue adelante usando la identidad de
Authorino mismo (que sí tiene una SA dedicada, `authorino-authorino` — ver
`poc-ingress-kuadrant/eks-origen/vault/01-authpolicy-origen-eks.yaml` y `02-vault-login-cronjob-eks.yaml`). Queda anotado como
antecedente para una iniciativa de plataforma aparte (SA dedicada por Deployment), no como parte
del alcance de este documento.

## 1. El hallazgo: el secrets engine `spiffe`

A diferencia de todo lo evaluado en la revisión original (`auth/jwt`, `identity/oidc`, `AppRole` —
todos *auth methods*, es decir Vault como **consumidor** de identidad), `spiffe` es un **secrets
engine**: Vault emite el token, no lo valida.

> "Vault is the issuer of the SVID, not the consumer [...] a standalone JWT signer"
> — [SPIFFE secrets engine, HashiCorp Developer](https://developer.hashicorp.com/vault/docs/secrets/spiffe)

Mintea **JWT-SVIDs** (no certificados X.509 — para eso está el PKI secrets engine, ya evaluado como
viable en `vault-no-viable.md` original §4 como infraestructura de apoyo). El motor interpola en el
token metadata del método de autenticación usado para llegar hasta ahí — namespace/ServiceAccount
si fue `auth/kubernetes`, rol si fue `AppRole` — y genera `iss`, `aud`, `exp`, `iat` estándar.

**Y expone su propio discovery OIDC**, sin depender de nada externo:

> "The SPIFFE secrets engine includes two endpoints that allow OIDC providers to validate the JWTs
> it mints" — `/.well-known/openid-configuration` + JWKS.
> — HashiCorp Developer (búsqueda agregada, misma página de docs)

Esto es lo que cierra el caso: el `AuthPolicy` de destino valida el JWT-SVID exactamente como
validaría un token de Keycloak — `issuerUrl` apuntando al discovery de Vault, sin SPIRE en la
cadena.

## 2. El flujo completo

1. `egress-gw` se autentica a Vault con un método M2M ya confirmado como viable (`auth/kubernetes`
   o `AppRole`, sin humano de por medio) → recibe un token de Vault de vida corta.
2. Con ese token, llama a `spiffe/sign` → Vault mintea un JWT-SVID (`iss=vault`,
   `aud=backend`, `exp` corto).
3. `egress-gw` presenta ese JWT-SVID como `Authorization: Bearer` al gateway de egreso.
4. Authorino (`AuthPolicy` en el cluster destino) lo valida vía OIDC discovery contra Vault —
   JWKS cacheado, no se re-consulta en cada request.
5. Válido → Envoy reenvía al backend.

Diagrama de secuencia completo (con las tres fases marcadas — login M2M ya validado, el paso nuevo
del secrets engine, y la validación OIDC estándar):
**https://claude.ai/code/artifact/2e8cac05-28aa-48d4-84da-af7c60c11b0e**

## 2bis. Primera prueba en vivo (2026-08-28) — minteo confirmado, discovery bloqueado

Seginf habilitó un AppRole con admin sobre el namespace `admin/spiffe` de un HCP Vault (noprod),
con el engine `spiffe` ya montado. Se probó el flujo real desde un pod en `cilium-1-35` (mismo
camino de red que tendría el workload real — la instancia vive en un HVN peereado a esa VPC,
rango `172.19.253.x`, no alcanzable desde fuera de esa red).

**Pasos 1-3 del flujo (login + config + mint) — funcionan de punta a punta:**

1. Login AppRole (`POST /v1/auth/approle/login`) → `200`, token con policy
   `spiffe-administrator-policy`.
2. `POST /v1/spiffe/config` con `trust_domain` → `200`.
3. `POST /v1/spiffe/role/<nombre>` con una plantilla fija de `sub` (para esta primera prueba, no
   dinámica por workload) → `200`. Ojo con el formato: el campo `template` tiene que ser un
   **objeto JSON completo** (`{"sub": "..."}`), no solo el fragmento `"sub": "..."` — el primer
   intento falló por eso.
4. `POST /v1/spiffe/role/<nombre>/mintjwt` con `audience` → `200`, JWT-SVID real:
   ```json
   {
     "aud": ["backend-eks"],
     "exp": 1788191190,
     "iat": 1788190890,
     "iss": "https://node-60-0...z1.hashicorp.cloud:8202/v1/admin/spiffe/spiffe",
     "sub": "spiffe://poc-egress.bancogalicia.com.ar/poc/egress-gw",
     "vault": { "entity": { "id": "45dd8733-..." } }
   }
   ```
   Header: `{"alg":"RS256","kid":"3ae63415-..."}`. TTL real = 300s (`exp - iat`), como se configuró.

**Paso 4 (Authorino → discovery/JWKS) — bloqueado por red al principio, resuelto sin abrir un
puerto nuevo:**

El `iss` del primer token apuntaba al puerto **8202** (`.../v1/admin/spiffe/spiffe/.well-known/…`
y `/keys`) — un puerto **distinto** del 8200 usado para login/mint. Probado desde el mismo pod:
`8200` responde, `8202` daba timeout limpio (confirmado que no era DNS — los dos hostnames
resuelven bien a IPs del mismo rango privado; también se probó el 8201, mismo timeout). Reproducido
además desde OpenShift on-prem, camino de red totalmente distinto (no VPC de AWS) — mismo síntoma
ahí, lo que apuntaba a un bloqueo del lado de HCP/Vault (su propia doc de firewall dice que por
default solo dejan pasar 8200 + 5696), no de una regla nuestra puntual.

**La solución real, más simple que abrir un puerto**: reconfigurar `jwt_issuer_url` en
`spiffe/config` para que apunte al **8200** (que ya estaba abierto) en vez de dejar que Vault use
el default con el 8202. Costó dos vueltas de ajuste:

1. Primer intento: `jwt_issuer_url` = host+puerto pelado, sin el path del mount → el discovery
   respondía, pero el `jwks_uri` que devolvía **no tenía puerto** (`.../hashicorp.cloud` a secas)
   — seguirlo literal daba timeout (se iba al 443 por default).
2. Con el puerto agregado pero **sin el path del mount** → `jwks_uri` quedaba
   `.../hashicorp.cloud:8200/.well-known/keys`, que daba `404` (Vault no rutea ahí sin el path del
   mount).
3. **Forma final que funciona, sin token, sin headers custom** (exactamente como llamaría
   Authorino — un `GET` plano):
   ```
   GET https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200/v1/admin/spiffe/spiffe/.well-known/keys
   → 200, con el mismo kid (3ae63415-...) del JWT minteado en el paso 4 de más arriba
   ```
   `jwt_issuer_url` tiene que quedar seteado con los **tres** componentes juntos: host, puerto
   (`:8200`) y el path completo del mount (`/v1/admin/spiffe/spiffe`).

**Estado: cadena completa confirmada — login → mint → discovery → JWKS, las cuatro piezas,
las cuatro contra el puerto 8200 que ya estaba abierto.** No hizo falta el 8202. El `kid` del JWKS
público coincide exactamente con el del JWT minteado — la firma es verificable de punta a punta.
No se probó todavía la validación real desde un `AuthPolicy`/Authorino apuntando a este
`issuerUrl` (queda para la integración real, ver §5).

## 2ter. Integración real desplegada y confirmada end-to-end (2026-09-02)

A partir de §2bis (mint/discovery/JWKS confirmados de forma aislada) se armó y desplegó la
integración real, reemplazando el wristband self-signed (`05-authpolicy-wristband.yaml`) por este
mecanismo en el cluster origen (EKS, `cilium-1-35`). Detalle completo, incluyendo el diseño y las
correcciones de arquitectura sobre la marcha, en
[`01-authpolicy-origen-eks.yaml`](../poc-ingress-kuadrant/eks-origen/vault/01-authpolicy-origen-eks.yaml) y
[`02-vault-login-cronjob-eks.yaml`](../poc-ingress-kuadrant/eks-origen/vault/02-vault-login-cronjob-eks.yaml). Resumen de lo que quedó funcionando:

**Decisión de login — `auth/jwt`, no `AppRole`, por sugerencia de Seginf** (escala mejor, no
depende de `TokenReview` por diseño, y no hay ningún secreto que gestionar — el propio SA token de
Kubernetes es la credencial). Se cerró además un límite real de Authorino descubierto en el
diseño: no tiene forma nativa de leer su propio SA token montado y colocarlo en el *body* de un
POST (`metadata.http`/`ValueOrSelector` solo puede leer literales o la "authorization JSON" de la
request entrante, nunca el filesystem del pod; `sharedSecretRef` sí lee un K8s `Secret`, pero solo
puede colocarlo en header/query/cookie, nunca en el body — y Vault exige el JWT en el body de
`auth/jwt/login`). Solución: separar login de mint — un `CronJob` aparte hace el login cada 50 min
y deja el `client_token` en un `Secret`; Authorino solo hace el mint, leyendo ese `Secret` vía
`sharedSecretRef` en un header (`X-Vault-Token`), que sí encaja 100% con lo que Authorino soporta.

**La identidad que se valida es la de Authorino mismo, no la de `egress-gw`** — corrección de un
supuesto inicial: Authorino corre en su propio Deployment (`kuadrant-system`), con su propia
ServiceAccount (`authorino-authorino`), sin acceso al token del pod de `egress-gw`.

**Configuración live en `admin/spiffe`, hecha por el equipo de la PoC con el AppRole admin que ya
tenían** (no hizo falta que Seginf interviniera más allá de la config inicial):

1. `auth/jwt` habilitado (`POST /sys/auth/jwt`) y configurado contra el issuer público de EKS
   (`oidc_discovery_url`) — validación local, sin `TokenReview` en vivo.
2. `Role authorino-egress` en `auth/jwt`, con `bound_subject:
   system:serviceaccount:kuadrant-system:authorino-authorino` y `claim_mappings` poblando
   namespace/SA reales.
3. `Role egress-gw` en `spiffe` (limpio — reemplaza al `egress-gw-test` de las pruebas manuales
   de §2bis).
4. Policy acotada `spiffe-mint-only-policy` — **solo** `capabilities = ["update"]` sobre
   `spiffe/role/egress-gw/mintjwt`, asignada al `Role` de `auth/jwt` en vez de la policy admin
   usada para las pruebas.

Durante este trabajo se repitió dos veces un error `412 - required index state not present` en
operaciones `LIST`/creación de objetos (incluso en `spiffe/role`, que ya funcionaba) — confirmado
como un blip transitorio del backend de Vault/HCP no relacionado a la config (se probó
`auth/kubernetes` en paralelo como control, sin problema, descartando un índice roto a nivel de
todo el namespace). Se resolvió solo, sin acción de Seginf. Detalle en
[`incidente-412-index-state.md`](incidente-412-index-state.md).

**Cadena Vault confirmada en vivo con la identidad real** (no el AppRole de admin): un pod
efímero con `serviceAccountName: authorino-authorino` hizo login real (`auth/jwt/login` con su
propio SA token) → `200`, token con la policy acotada → mint contra `egress-gw` con ese token →
`200`, JWT-SVID válido.

**El `CronJob vault-egress-login` se aplicó y se corrió manualmente** (`kubectl create job
--from=cronjob/...`) — dejó el `Secret vault-egress-token` poblado, y un mint de prueba usando
exactamente ese `Secret` (el mecanismo que usa la `AuthPolicy` real vía `sharedSecretRef`)
confirmó `200`.

**El `AuthPolicy egress-backend-vault-spiffe` se aplicó sobre la ruta real** `egress-backend` en
`poc-ingress-kuadrant` — quedó `Accepted` y `Enforced` (el wristband original,
`egress-backend-jwt`, pasó a estar automáticamente "overridden" por Kuadrant, al competir por el
mismo `targetRef`).

**Prueba de tráfico real, de punta a punta, confirmada cruzando a OCP**: un `curl` desde el pod
`bff` (EKS) a `backend.poc-ingress-kuadrant.svc.cluster.local:8080` llegó al pod `backend`
corriendo del lado **OCP** (confirmado por su hostname y metadata de red distintas a EKS, y por
`x-envoy-peer-metadata` mostrando el gateway de entrada de OCP), con el header:

```
x-egress-token: Bearer eyJhbGciOiJSUzI1NiIs...
```

Decodificado: `sub: spiffe://poc-egress.bancogalicia.com.ar/poc/egress-gw`,
`aud: bff-eks.paas-demo.bancogalicia.com.ar`, `iss:` el Vault de HCP — el JWT-SVID real, no el
wristband self-signed. **Es el primer tráfico real de la PoC cruzando de cluster con un token
emitido por Vault.**

**Actualización — el `AuthPolicy` del lado OCP sí existe** (`backend-ingress-jwt`, en
[`poc-ingress-kuadrant/ocp-destino/13-authpolicy-jwt-rhcl.yaml`](../poc-ingress-kuadrant/ocp-destino/13-authpolicy-jwt-rhcl.yaml)
de este mismo repo), pero sigue apuntado al wristband viejo. El reemplazo ya está armado como
borrador en
[`03-authpolicy-destino-ocp.yaml`](../poc-ingress-kuadrant/ocp-destino/vault/01-authpolicy-destino-ocp.yaml),
mismo directorio, con cada cambio documentado:

1. `jwksUrl` → JWKS real de Vault (confirmado en vivo: `200`, con el `kid` del token real
   presente en el set).
2. `credentials.customHeader.prefix` → de `""` a `"Bearer "` (el `AuthPolicy` nuevo del lado EKS
   sí antepone `Bearer ` al token, a diferencia del wristband viejo — confirmado en el test real
   de tráfico).
3. Los `claims-esperados` reescritos contra `sub` (el SPIFFE ID) — los claims custom del
   wristband (`src_cluster`/`src_namespace`/`dst_service`) no existen en el JWT-SVID de Vault.
4. Los headers de respuesta que leían esos mismos claims quedan como decisión pendiente (no
   resuelta acá) — si `backend` los necesita, hay que decidir de dónde sacarlos ahora.

**CONFIRMADO EN VIVO — 2026-09-02.** El equipo con acceso a OCP aplicó el `AuthPolicy` (con estos
cambios u otros equivalentes). Se repitió el mismo `curl` desde `bff` (EKS) varias veces — la ruta
tiene un split 50/50, así que hizo falta repetir hasta que cayera del lado OCP — y en los
intentos que cruzaron a OCP (confirmado por el hostname del pod `backend` y su CIDR, `172.30.x.x`,
distinto al de EKS) la respuesta fue **`200 OK` con el body real del backend**, no un `401`/`403`.
Esto confirma que Authorino en OCP validó correctamente el JWT-SVID minteado por Vault —
`jwksUrl`, `prefix: "Bearer "` y los claims contra `sub` funcionan como se documentó arriba.

## 2quater. Prueba negativa (2026-09-02) — HALLAZGO CRÍTICO: OCP no está rechazando nada

La prueba anterior (§2ter) solo confirmó que el tráfico *pasaba* con un token válido — no que algo
lo estuviera *validando*. Para probar el rechazo de verdad, hacía falta llegar a OCP sin pasar por
el mint automático de Authorino en EKS (que sobreescribe cualquier `x-egress-token` que el cliente
mande, confirmado enviando un valor basura por el camino normal — llegó igual el token real,
minteado por Vault, no el basura). La forma de lograrlo: pegarle directo al hostname externo de la
ruta (`bff-eks.paas-demo.bancogalicia.com.ar`, el mismo `Hostname`/`ServiceEntry` que resuelve al
Gateway de OCP), con el header `Host: backend.poc-ingress-kuadrant.svc.cluster.local` seteado a
mano (el Gateway de OCP no reescribe el Host — así lo requiere, ver
`runbook-gw-istio-hostnetwork.md`) — eso sí evita el mint de EKS.

**Resultado: `200 OK` en los tres casos, repetido varias veces para descartar casualidad:**

| Caso | Resultado |
|---|---|
| Sin ningún header de auth | `200 OK` — llega a `backend` igual |
| `x-egress-token: Bearer esto-no-es-un-jwt` | `200 OK` — llega igual |
| `x-egress-token: cualquier-cosa-123` | `200 OK` — llega igual |
| Token real (vía el mint normal) | `200 OK` — llega igual |

**Actualización — la prueba en sí quedó invalidada, no la conclusión.** Investigando esto con el
equipo (revisando `status.conditions` del `AuthPolicy` vía consola OCP, el estado del `Gateway`, y
los logs del `kuadrant-operator`) se estableció una cadena de hallazgos distinta a la sospechada
originalmente:

1. El `Enforced: False` inicial (`reason: Unknown`, "waiting for... Gateway to sync") resultó ser
   un estado transitorio justo después de crear el recurso — los logs del operador mostraron
   reconciliaciones limpias, sin errores, tanto en el momento de creación como más tarde.
2. El bypass que se usó para la prueba negativa (pegarle directo al hostname externo con
   `Host` manual, puerto 80 sin TLS) probablemente golpeó un listener distinto (`http:80`) del que
   usa el tráfico real cruzado por la malla (`https:443`, mTLS) — **esa prueba no es concluyente**,
   pudo estar bypaseando el `AuthPolicy` real en vez de probarlo.
3. Al reintentar por el camino real (`backend.poc-ingress-kuadrant.svc.cluster.local:8080`, el que
   sí cruza a OCP), apareció algo completamente distinto: el token **válido** empezó a fallar con
   `403`, del lado **EKS** — `"no such key: data"` en los logs de Authorino, señal de que la propia
   llamada de mint a Vault no estaba devolviendo el `X-Vault-Token` correcto.
4. Se descartó Vault como causa: 30 llamadas directas y espaciadas contra el mismo endpoint de
   mint, con el mismo token del `Secret`, dieron `200` limpio las 30 veces. El token del `Secret`
   en sí también se probó directo y funcionaba.
5. **Causa real: estado interno stale en el propio pod de Authorino** (probablemente su caché del
   valor leído vía `sharedSecretRef`) — sin ningún error logueado, simplemente enviaba el header
   `X-Vault-Token` vacío (confirmado: Vault responde `{"errors":["permission denied"]}` sin la key
   `data` ante un token vacío, exactamente el síntoma visto). **Se resolvió con un
   `kubectl rollout restart deployment authorino`** — después del reinicio, 15/15 requests (mezcla
   de espaciados y en ráfaga) volvieron a `200`.

**Actualización — prueba negativa repetida correctamente, y esta vez el hallazgo es real,
confirmado.** No se pudo alcanzar el listener real (`https:443`) desde afuera con un cliente TLS
plano (`curl` a mano contra ese puerto dio `connection reset` — la malla usa mTLS interno de
Istio, no un TLS estándar simulable desde acá), así que un token "basura" client-side nunca sirve
para probar el camino real (Authorino en EKS siempre sobreescribe cualquier `x-egress-token` que
mande el cliente). La forma que sí funcionó: cambiar temporalmente (con aprobación explícita del
usuario) el `template` del `spiffe/role/egress-gw` en Vault a un `sub` no autorizado
(`.../poc/impostor` en vez de `.../poc/egress-gw`), dejando todo lo demás igual — así el token que
sale por el camino real (mint real, header real, cruce real a OCP) es genuinamente inválido según
las reglas del `AuthPolicy`, sin tocar nada de la config de Kubernetes.

**Resultado: `200 OK`, con el `sub` "impostor" confirmado en el token que llegó al pod real de
OCP** (decodificado del header `x-egress-token` recibido, no asumido). El `AuthPolicy` de OCP
**no está rechazando claims que no matchean** — la validación de `claims-esperados` no está
teniendo efecto real, más allá de si la firma/JWKS sí se valida (posible pero no aislado en esta
prueba). Revertido el cambio en Vault inmediatamente después de la prueba, confirmado con tráfico
real que el `sub` volvió a `.../poc/egress-gw`.

**Esto es un hallazgo de seguridad real y confirmado, no un falso positivo de la prueba anterior.**

### Actualización 2026-09-09 — dos hipótesis refutadas, y el dato que falta

Se investigaron y **descartaron con evidencia** las dos explicaciones más plausibles. Quedan
anotadas para que nadie las vuelva a recorrer:

1. **Poda silenciosa del campo `predicate` por deriva de schema del CRD.** Refutada: los tres
   predicados están completos en el objeto guardado
   (`oc get authpolicy … -o json | jq '..|.predicate? // empty'`).
2. **istiod no le empuja el `ext_authz` al gateway desplegado a mano.** Refutada: el
   `config_dump` del Envoy de `gw-hostnet` tiene 63 `authorino`, 7 `ext_authz` y 149 `kuadrant`.
   Esta hipótesis pretendía además unificar este hallazgo con el bloqueo de SDS del runbook
   §7.2 — no van juntos, y ese bloqueo se resolvió por su cuenta (runbook §7.2, actualizado).

Con eso, el problema se parte en dos ramas mutuamente excluyentes, y hay **un solo dato** que
decide cuál — el mismo que faltaba el 2026-09-02: **¿Authorino llegó a ver el request?**

- **No lo vio** → el wasm-shim no matcheó el request contra ninguna action set y lo dejó pasar
  sin evaluar. Hipótesis principal de esa rama: el `:authority` llega con puerto
  (`…svc.cluster.local:8080`, porque el egreso no reescribe el Host) y el `HTTPRoute` declara el
  hostname sin puerto. Explicaría los cuatro síntomas juntos, incluido que no haya error en
  ningún log.
- **Lo vio y devolvió `authorized:true`** → la evaluación es el problema (candidato principal:
  `aud` tratado como string, donde `in` en CEL hace substring match).

Árbol de decisión completo, con los comandos de cada rama y la forma correcta de repetir la
prueba negativa (incluido el `rollout restart` que faltó, sin el cual se prueba con el token
viejo cacheado), en
[`poc-onprem-kuadrant/destino-arqlab/14-diagnostico-claims.md`](../poc-onprem-kuadrant/destino-arqlab/14-diagnostico-claims.md).

Pendiente para el equipo con acceso a OCP: revisar por qué el bloque `authorization.claims-esperados`
del `AuthPolicy` no está bloqueando nada — candidatos: error de sintaxis en las expresiones CEL que
las hace evaluar siempre `true` (o error silencioso tratado como éxito), o que Kuadrant no esté
aplicando ese bloque en absoluto pese a mostrar `Enforced: True`. No se pudo diagnosticar más sin
logs de Authorino/kuadrant-operator del lado OCP en el momento exacto de una de estas pruebas.

**Hallazgo aparte, ya corregido**: el `CronJob` (`poc-ingress-kuadrant/eks-origen/vault/02-vault-login-cronjob-eks.yaml`) tiene un bug de
schedule — `*/50 * * * *` en el campo de minutos corre en los minutos **0 y 50** de cada hora
(intervalo irregular: 10 min entre `:50`→`:00`, luego 50 min entre `:00`→`:50`), no "cada 50
minutos" parejo como decía el comentario original. No es grave (el TTL del token es 1h, así que
igual refresca a tiempo) pero el comentario del archivo está mal — corregir a algo como
`"25,55 * * * *"` si se quiere un intervalo realmente parejo de 30 min, o documentar el
comportamiento real si `*/50` se deja como está.

## 2quinquies. Estabilidad y latencia — batería completa (2026-09-02, post-fix de Authorino)

Después del `rollout restart` de Authorino (§2quater) y el fix del `CronJob` (schedule real de 30
min), se corrió una batería más completa para confirmar que el camino positivo es estable, no solo
que "funcionó una vez":

| Prueba | Resultado |
|---|---|
| 40 requests espaciados (~0.3s entre cada uno) | **40/40 `200`**, cero errores |
| 30 requests en ráfaga, sin pausa (repite el escenario exacto que rompió antes del fix) | **30/30 `200`**, cero errores |
| 20 requests en paralelo real (concurrentes, no solo secuenciales rápidos) | **20/20 `200`**, cero errores |

**El fix del `rollout restart` aguanta bajo ráfaga y concurrencia real** — no era una solución
parcial. Sin nuevas apariciones del `"no such key: data"` en ninguna de estas pruebas.

**Latencia**, separando por hostname del pod que respondió (la ruta hace split 50/50 entre backend
local en EKS y el real en OCP), sobre la muestra de 40 espaciados:

| Destino | n | promedio | mediana | p95 | min | max |
|---|---|---|---|---|---|---|
| `backend-local` (EKS, mismo cluster) | 16 | 33.8ms | 21.6ms | 100.7ms | 19.1ms | 100.7ms |
| `backend` real (OCP, cruzando cluster) | 24 | 245.1ms | 212.1ms | 349.9ms | 178.7ms | 350.4ms |

**Overhead de cruzar a OCP: ~211ms en el promedio** (245.1ms - 33.8ms) sobre el camino puramente
local — consistente con la medición anterior (~214ms). Incluye el mint de Vault en cada request (la
`AuthPolicy` no cachea el JWT-SVID — cada request dispara un mint fresco). Son medidas de un
ambiente noprod con la instancia de HCP Vault en una VPC peereada, no representativas
necesariamente de un despliegue productivo distinto.

**Resumen del estado real a esta altura**: el camino EKS→OCP con Vault como emisor es
**funcionalmente estable** bajo carga normal, ráfaga y concurrencia (confirmado con ~150 requests
acumulados en esta sesión sin un solo fallo del lado del mint/mint-pipeline después del fix). Lo
que **no** está resuelto es la validación de claims del lado OCP (§2quater) — un tema de
correctness/seguridad, no de estabilidad. Son dos preguntas distintas: "¿el mecanismo aguanta
tráfico?" (sí) vs. "¿rechaza lo que tiene que rechazar?" (no, confirmado que no).

## 2sexies. Dirección inversa — OCP→EKS (2026-09-02)

Mismo mecanismo, roles invertidos: origen `poc-egress-kuadrant` (OCP, `paas-arqlab`), destino
`poc-egress-kuadrant/destino` (EKS). Detalle completo en
[`poc-egress-kuadrant/origen/vault/03-authpolicy-origen-ocp.yaml`](../poc-egress-kuadrant/origen/vault/03-authpolicy-origen-ocp.yaml)
y [`01-vault-login-cronjob-ocp.yaml`](../poc-egress-kuadrant/origen/vault/01-vault-login-cronjob-ocp.yaml).
Resumen:

- `auth/jwt-ocp` (mount separado de `auth/jwt`) porque el issuer de OCP,
  `https://kubernetes.default.svc`, es interno — no alcanzable desde Vault. Configurado con
  `jwt_validation_pubkeys` estáticas (sacadas una vez de `/openid/v1/jwks` del cluster), no
  `oidc_discovery_url`.
- Login + mint confirmados en vivo con la identidad real de Authorino en `paas-arqlab`.
- **Dos bugs reales encontrados y corregidos en el camino, distintos entre sí**:
  1. **Timeout de mint** — la latencia real `paas-arqlab`→Vault es ~0.5s, contra un timeout fijo
     de 200ms en el `ext_authz` de Kuadrant. Falla intermitente, ~25% en una tanda de 15. Fix
     diseñado (mint pre-hecho por el `CronJob`, servido por un `httpd` local) pero **no aplicado**
     — decisión explícita de priorizar que funcione antes de optimizar. Ver
     `poc-egress-kuadrant/origen/vault/PROPUESTA-fix-latencia-mint-ocp.md`.
  2. **Prefijo `"Bearer "` no soportado** — la suposición de que Authorino lo saca automáticamente
     al parsear el header (asumida en la dirección EKS→OCP, nunca verificada ahí porque OCP no
     estaba validando nada de todas formas, ver §2quater) resultó ser **incorrecta**. Confirmado
     en vivo: con el prefijo, el 100% de los requests que cruzaban a EKS fallaban con
     `UNAUTHENTICATED`. Corregido en ambas direcciones — las `AuthPolicy` de origen ahora mandan
     el JWT crudo, sin prefijo (mismo criterio que el wristband original).

**CONFIRMADO EN VIVO — tráfico real cruzando OCP→EKS, con validación exitosa**: después del fix
del prefijo, 15/15 requests exitosos (antes había fallado el 100% de los que cruzaban), con 11 de
esos 15 aterrizando en el pod real de `backend` en EKS (confirmado por hostname del pod,
`backend-8868795f8-rbj75`, verificado que existe en el cluster EKS) y `authorized:true` en los
logs de Authorino de EKS para esos requests. **Esta es la primera confirmación real de tráfico
cruzando en esta dirección** — una afirmación anterior de que "funciona de punta a punta" resultó
falsa al verificarla (el usuario detectó la inconsistencia), así que vale la pena remarcar: esto
sí está verificado con evidencia directa (logs + hostname del pod), no inferido del estado
`Enforced` de la `AuthPolicy`.

**Actualización — el problema de latencia también se resolvió, con un fix más simple del
originalmente diseñado**: en vez del CronJob+httpd de `poc-egress-kuadrant/origen/vault/PROPUESTA-fix-latencia-mint-ocp.md`,
`metadata.http` en Authorino tiene un campo `cache` nativo (`cache.key` + `cache.ttl`, confirmado
leyendo el schema real del CRD). Con un `key` constante y `ttl: 250` (por debajo de los 300s del
mint), Authorino deja de golpear a Vault en cada request — una sola llamada real por ventana de
TTL. **Confirmado en vivo: 29/29 requests cruzando a EKS con `authorized:true`, cero fallos**,
después de aplicar el cache. El diseño más robusto (mint pre-hecho, servido localmente) queda
archivado como alternativa, no hizo falta.

**Corrección importante — el cache no estaba funcionando de verdad al principio, en NINGUNA
dirección.** Después de agregar el campo `cache` también del lado EKS→OCP (para comparar
apples-to-apples) se confirmó con `iat` repetido en llamadas seguidas que **no cacheaba nada**, ni
ahí ni (probablemente) del lado OCP tampoco — el "100% de éxito" visto antes fue timing/latencia
de red favorable, no cache real. Se habilitó `LogLevel: debug` en Authorino (EKS) temporalmente
para diagnosticar, y apareció la causa exacta:

```
"msg":"unable to store data in the cache","err":"size of key: egress-gw, value: 1042,
err: The entry size is larger than 1/1024 of cache size"
```

El cache namespace de Authorino tiene un límite default de 1MB, con un tope por entrada de 1/1024
de eso (~1KB) — y el JWT-SVID pesa 1042 bytes, apenas por encima. **Cada escritura al cache fallaba
silenciosamente** (solo logueado en debug), así que siempre minteaba fresco, sin importar la
config de `cache.key`/`cache.ttl` (esa parte sí estaba bien). Fix real: subir
`spec.evaluatorCacheSize` en el CR `Authorino` (a nivel cluster, no por `AuthPolicy`) — se probó
con `10` (10MB), resuelve el problema con margen de sobra. Aplicado en ambos clusters (EKS y OCP).
`LogLevel` revertido a su valor original después de diagnosticar.

**Latencia real con el cache YA funcionando de verdad** (antes de este fix, todos los números de
latencia documentados arriba en realidad medían con mint en vivo en cada request en ambas
direcciones — dato para tener en cuenta si se comparan con mediciones futuras):

| Destino | Antes (mint en vivo) | Ahora (cache real) |
|---|---|---|
| EKS→OCP, local (EKS) | ~19.7ms p50 | ~12.5ms p50 |
| EKS→OCP, cruzando a OCP | ~181ms p50 | ~170ms p50 (dominado por red, no por Vault) |
| OCP→EKS, local (OCP) | ~176-192ms | **~10.8ms** estable |
| OCP→EKS, cruzando a EKS | ~380-425ms | **~173ms** estable |

El impacto es mucho mayor del lado OCP→EKS (caía directo el costo de los ~500ms a Vault desde
on-prem) que del lado EKS→OCP (Vault desde EKS ya era rápido, ~40-50ms, así que ahorrarlo pesa
menos sobre el total). 2-3 requests con latencia alta al inicio de cada tanda de prueba son
cache-miss esperables (primera llamada tras el fix, antes de que el cache tenga la entrada).

**Estado final de esta dirección: funcional y confiable, ambos problemas encontrados (prefijo
`"Bearer "` y latencia del mint) corregidos y confirmados en vivo con evidencia directa de logs.**

**Latencia OCP→EKS** (con el fix de cache ya aplicado, 30 requests desde `bff` en `paas-arqlab`,
separados por hostname del pod que respondió):

| Destino | n | promedio | mediana | min | max |
|---|---|---|---|---|---|
| Local (OCP, mismo cluster) | 15 | 191.9ms | 176.0ms | 173.2ms | 257.2ms |
| EKS (cruzando cluster) | 12 | 379.3ms | 417.6ms | 336.8ms | 424.7ms |

**Overhead de cruzar: ~187.5ms** — mismo orden de magnitud que la dirección EKS→OCP (~211ms,
§2quinquies). 2 de los 30 intentos de esta muestra vinieron con hostname vacío en el body (posible
hiccup puntual, sin investigar más — en paralelo se confirmó 29/29 `authorized:true` en un loop
similar, así que no parece ser el mint/auth la causa).

**Investigado, no resuelto — piso de latencia alto incluso para el destino local**: pegarle al
mismo backend local pero **sin** pasar por el Gateway/`AuthPolicy` (`backend-local` directo) tomó
**28.7ms**. Pasando por el Gateway con Authorino de por medio (mismo destino local), **176-192ms**
— es decir, **~150-160ms de overhead puro del pipeline Envoy↔Authorino**, ya con el cache del mint
puesto (no es Vault). Se investigaron y descartaron las dos causas más probables:
- **CPU/recursos de Authorino**: uso real insignificante (`1m` CPU, `104Mi` memoria) — sin
  requests/limits configurados en el Deployment, pero sin señal de starvation.
- **Latencia de red cruda entre nodos** (Authorino corre en `worker-0-lt78n`, el Gateway en
  `worker-0-lgp2q` — nodos distintos): medida directa con `curl` (TCP connect puro) entre esos dos
  nodos específicos, **0.5-2.7ms** — nada.

El overhead real está en algún punto de la capa de mTLS/gRPC entre Envoy y Authorino, o en el
procesamiento interno de Authorino (evaluación CEL, etc.) — no aislado más en detalle por falta de
tiempo en esta sesión (haría falta LogLevel debug en Authorino, que afecta todo el cluster, o
mirar timing interno de Envoy). Decisión: dejarlo así por ahora — ~380ms cruzando a EKS es
razonable para esta integración, no bloquea el uso; profiling más fino queda pendiente si en algún
momento hace falta optimizar más.

## 3. Por qué esto contradice la evaluación original

La evaluación de `AppRole` (2026-08-14) decía:

> "El resultado de una autenticación exitosa es un token nativo de Vault, no un JWT/OIDC externo
> [...] Es un mecanismo de autenticación *hacia* Vault, no para emitir credenciales externas."

Eso seguía siendo cierto de `AppRole` **solo**. El secrets engine `spiffe` es la pieza que faltaba:
toma ese login M2M genuino y lo convierte en el JWT portable y validable externamente que
`AppRole` por sí solo no daba. No hace falta SPIRE — la alternativa que sí lo requeriría (un SPIRE
Server + Agent por nodo en cada cluster, más la federación de trust domain entre OCP y EKS) queda
descartada por innecesaria frente a esta opción, más simple operativamente.

## 4. El costo: sigue siendo Enterprise

`spiffe` (igual que `auth/spiffe`, el auth method evaluado para la dirección opuesta) es
**exclusivo de Vault Enterprise** — no está en la edición community/OSS. Es el único punto en
contra real frente a la recomendación de Keycloak, que no tiene esa dependencia de licencia.

## 5. Conectividad, modelo de claves y modos de falla

Detalle de una revisión posterior sobre quién habla con Vault, qué material criptográfico
maneja cada uno, y qué pasa si se corta la conexión. Diagrama de conectividad completo:
**https://claude.ai/code/artifact/8c85c8de-c78b-48e7-9418-0e28f6a1f22f**

### 5.1 Quién habla con Vault (tres componentes, no dos)

| Componente | Dirección | Para qué | Frecuencia |
|---|---|---|---|
| `egress-gw` (workload, origen) | → Vault | login (`auth/kubernetes`/`AppRole`) + `spiffe/sign` | una vez por ciclo de vida del token (~`tokenDuration`) |
| Vault | → API de Kubernetes del origen | `TokenReview` para validar el SA token — **solo si `auth/kubernetes` usa validación en vivo** en vez de contra el JWKS público del cluster (sin confirmar cuál de los dos modos aplicaría acá) | por cada login, si aplica este modo |
| Authorino (destino) | → Vault | `GET` discovery + JWKS | una vez, cacheado — no por request |

**El gateway (Envoy) nunca le habla a Vault** — delega la validación en Authorino vía `ext_authz`
interno al cluster, el mismo mecanismo ya usado (y probado en vivo) para el bypass del wasm-shim
de Kuadrant con Envoy Gateway.

### 5.2 Modelo de claves — una privada, muchos sujetos

- La clave de **firma** es una sola (o un set chico durante una rotación), y **nunca sale de
  Vault**. Ni el workload ni Authorino la tienen en ningún momento.
- Authorino no tiene "una clave" — tiene el **JWKS entero**, que es un *set*. Cada JWT lleva un
  `kid` en el header; Authorino busca la clave correspondiente dentro del set que tiene cacheado.
  Esto es lo que permite que, durante una rotación, la clave vieja y la nueva convivan un tiempo
  (tokens ya emitidos con la vieja siguen validando mientras la nueva entra en uso) — el mismo
  mecanismo que motivó forzar el refetch del `AuthPolicy` en la rotación EC→RSA de esta sesión.
- **Una misma clave sirve para todos los workloads/microservicios** — no hay una clave distinta
  por servicio. Lo que distingue "quién es quién" es el contenido del token (`sub` con el SPIFFE
  ID, `customClaims` como `src_service`/`dst_service`), no la clave usada para firmarlo. Es el
  mismo patrón que ya usaba el wristband original de esta PoC (un único `Secret` `egress-eks-1`
  firmando para toda la plataforma).

### 5.3 TTLs — dos ejes independientes, no uno

1. **TTL del JWT-SVID** (`tokenDuration`/`exp`) — corto por diseño (ej. 300s en los ejemplos
   usados). Vence solo, sin importar el estado del JWKS.
2. **TTL del cache del JWKS en Authorino** — cuánto tiempo Authorino usa su copia local antes de
   volver a pedirla a Vault. Independiente del anterior, y más largo (es una optimización de
   performance, no una medida de seguridad del token).

### 5.4 Qué pasa si se corta la conexión a Vault

| Se corta | Efecto | Cuándo se nota |
|---|---|---|
| Workload → Vault | No se pueden emitir tokens nuevos | Recién cuando vence el token actual (ventana de gracia = TTL del JWT) |
| Vault → API K8s origen (si aplica) | Falla el login mismo (`auth/kubernetes`) — ni siquiera se llega a pedir la firma | Inmediato para logins nuevos, mismo efecto de fondo que el caso anterior |
| Authorino → Vault | Sigue validando con la clave ya cacheada — **el corte se absorbe** | Solo si el cache vence Y el refetch falla; comportamiento exacto de Authorino en ese caso (stale-if-error vs. fail-closed) **sin confirmar** |

**Comparación con el diseño de Vault-como-almacén-de-credenciales** (KV, evaluado como
"credential injection" en la revisión anterior): ahí cada request necesita una llamada viva a
Vault, así que un outage corta el egress al instante. Acá, con el emisor de JWT-SVID + validación
por JWKS cacheado, el corte se absorbe durante una ventana (TTL del token de un lado, TTL del
cache del otro) antes de que haya impacto real — degradación gradual, no apagón inmediato. Es una
ventaja de resiliencia genuina del diseño emisor sobre el de inyección directa.

## 6. Conclusión

**Vault es viable como emisor**, vía el secrets engine `spiffe`, reutilizando un método de login
M2M ya validado (`auth/jwt`, con el propio SA token de Kubernetes como credencial) y sin depender
de SPIRE. Fue la decisión final frente a Keycloak (autohospedado, sin gate de licencia pero con su
propia superficie operativa — HA vía Infinispan, DB externa) y Cognito (descartado antes por la
falta de conectividad privada para `client_credentials`, ver §2quater/2quinquies más abajo para el
resto del historial de evaluación).

**Actualización 2026-09-02**: esto dejó de ser solo una evaluación — la integración se desplegó en
vivo en el cluster origen (EKS), con estabilidad confirmada bajo carga real (§2quinquies). El lado
OCP, sin embargo, **no está validando correctamente las claims del token** — confirmado en vivo
(§2quater): un JWT-SVID con `sub` no autorizado pasó igual. Es el único bloqueante real que queda
antes de considerar esto cerrado end-to-end; requiere acción del equipo con acceso a OCP.

---

## Apéndice — evaluación original (2026-08-14), archivada

*Se conserva el análisis original de `auth/jwt`, `identity/oidc` y `AppRole` porque sigue siendo
correcto para esos tres mecanismos puntuales — lo que cambió es que no eran todo el catálogo de
Vault relevante para este caso.*

### Los tres mecanismos evaluados entonces

| Mecanismo | ¿M2M sin humano? | ¿Emite JWT/OIDC validable externamente? |
|---|---|---|
| `auth/jwt` | — (es Vault el que consume, no el que emite) | No — dirección inversa |
| `identity/oidc` | No — requiere Authorization Code Flow interactivo | Sí, pero solo en flujo interactivo |
| `AppRole` | Sí | No — devuelve token Vault nativo, no portable afuera |

- **`auth/jwt`**: Vault valida y acepta tokens externos — dirección opuesta a la que necesitábamos.
- **`identity/oidc` (Vault OIDC Provider)**: sí firma y publica JWKS propio, pero solo soporta
  *Authorization Code Flow* (interactivo, con navegador) — sin grant type M2M documentado.
- **`AppRole`**: M2M genuino (`role_id` + `secret_id`, sin humano), pero el resultado es un token
  nativo de Vault, no un JWT/OIDC externo.

**Ninguno de los tres, evaluado solo, cerraba el caso** — de ahí el descarte original. El secrets
engine `spiffe` (§1 arriba) no estaba en el alcance de esa revisión.

### Lo que seguía firme entonces y sigue firme ahora

Vault como **infraestructura de apoyo**, no como emisor de identidad:

- **Transit Secrets Engine**: firma la clave del wristband sin exponer el material privado —
  reemplaza el manejo manual de `keys/gen-signing-key.sh` y el `Secret` estático en
  `kuadrant-system`.
- **PKI Secrets Engine**: como CA interna, hubiera evitado directamente el problema de la cadena de
  certificado rota (root equivocado, SKI/AKI que no cerraban) que consumió gran parte de la sesión
  original.
