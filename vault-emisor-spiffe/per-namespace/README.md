# Vault-signer por namespace

Extiende el patrón ya confirmado en vivo (`vault-emisor-spiffe.md`, `13-vault-login-cronjob.yaml`,
`14-vault-login-cronjob.yaml`, `authpolicy-vault-spiffe-ejemplo.yaml`, `15-authpolicy-vault-spiffe.yaml`)
para que la identidad que Vault verifica en el login deje de ser una única identidad compartida
(`system:serviceaccount:kuadrant-system:authorino-authorino`, la misma para EKS y para OCP, para
cualquier namespace) y pase a ser una identidad por namespace, verificada criptográficamente por
Kubernetes (no declarada), con el namespace real embebido en el `sub` del JWT-SVID emitido.

## Problema que resuelve

Hoy, tanto en `13-vault-login-cronjob.yaml` (EKS) como en `14-vault-login-cronjob.yaml` (OCP), el
login a Vault lo hace siempre el CronJob corriendo con la ServiceAccount `authorino-authorino` en
`kuadrant-system` — porque Kuadrant fuerza un único Authorino cluster-wide, con un único AuthConfig
por AuthPolicy siempre resuelto en `kuadrant-system`, sin importar en qué namespace viva la
AuthPolicy (`poc-egress-kuadrant`, `poc-ingress-kuadrant`, o cualquier otro). Confirmado leyendo
ambos AuthPolicy reales: el AuthPolicy de `poc-egress-kuadrant` y el borrador de
`poc-ingress-kuadrant` apuntan, los dos, al mismo Secret compartido por dirección
(`vault-egress-token` / `vault-egress-token-ocp`), es decir, a la misma identidad de Vault.

Consecuencia concreta: la frontera de seguridad real hoy es "kuadrant-system", no el namespace de
origen del tráfico. Dos namespaces distintos comparten hoy el mismo `sub` en el JWT-SVID emitido.
Es el mismo hallazgo ya anotado como OQ-11 (Authorino es un componente único, compartido, cuya
identidad no representa la del caller), visto desde el ángulo namespace en lugar del ángulo
workload.

## Objetivo (y lo que NO se toca)

Cerrar esa brecha específica — namespace como frontera — sin:
- sidecars (restricción explícita).
- asumir que Kuadrant soporta Authorino namespaced (no confirmado; se sigue con un único Authorino
  cluster-wide).
- multiplicar la administración de Vault por namespace (evitar un role + policy + spiffe-role
  completo por cada namespace onboardeado).

## Diseño

**1. Identidad namespace-scoped, sin sidecar.** Por cada namespace onboardeado se agrega solamente
un CronJob + ServiceAccount dedicados (`vault-egress-signer`), desplegados DENTRO de ese namespace
(no en `kuadrant-system`). El CronJob hace login a Vault con su propio SA token — Kubernetes lo
emite con el namespace real como claim, verificado por Vault vía TokenReview/OIDC (`auth/jwt` /
`auth/jwt-ocp`, ambos ya validados en vivo), no declarado por quien llama. Mismo patrón
login-separado-del-mint ya confirmado (Authorino no puede leer su propio SA token dentro de un
body HTTP — ver el comentario largo en `authpolicy-vault-spiffe-ejemplo.yaml`).

**2. Un solo role Vault por dirección, compartido por todos los namespaces onboardeados** (no uno
por namespace). Se logra ampliando `bound_claims` del role `auth/jwt` (`authorino-egress`) y
`auth/jwt-ocp` (`authorino-egress-ocp`) existentes, de un `bound_subject` fijo a una allowlist:

```
bound_claims:
  kubernetes.io/namespace:            ["poc-egress-kuadrant", "poc-ingress-kuadrant"]
  kubernetes.io/serviceaccount/name:  ["vault-egress-signer"]
```

Semántica de Vault: OR dentro de cada lista, AND entre claims distintos — es decir, se acepta
cualquier SA llamada exactamente `vault-egress-signer`, en cualquiera de los namespaces listados
(NO CONFIRMADO EN VIVO TODAVÍA en este repo con más de un valor por claim — documentado por
HashiCorp, pero hay que probarlo antes de escalarlo más allá de PoC; ver sección "Qué falta
confirmar" abajo).

`claim_mappings` no cambia (ya vuelca namespace/SA real en entity-alias metadata, confirmado en
vivo). Lo que sí cambia es el `template` del spiffe role (`egress-gw` / `egress-gw-ocp`): en lugar
de un `sub` fijo, interpola esa metadata verificada:

```
spiffe://bancogalicia.com.ar/ns/{{identity.entity.aliases.<accessor>.metadata.service_account_namespace}}/sa/vault-egress-signer
```

Esto responde directamente el pendiente de codificar el namespace en el `sub` de forma verificada
(viene de Kubernetes vía TokenReview/OIDC + `bound_claims`, no de un valor que el caller declara).
La policy de mint-only (acotada a `spiffe/role/<role>/mintjwt`, capability `update`) no cambia por
namespace: el mint no recibe namespace como parámetro de request, el namespace ya quedó grabado en
el `sub` por el template al momento del login.

**3. Secret de intercambio.** Se sigue dejando en `kuadrant-system` (mismo patrón que
`vault-egress-token` / `vault-egress-token-ocp`), pero uno por namespace
(`vault-egress-token-<namespace>`), escrito por la SA dedicada del namespace vía una RoleBinding
cross-namespace — soportado nativamente por RBAC (el subject de un RoleBinding puede ser una
ServiceAccount de otro namespace; no requiere ningún permiso especial de Kubernetes).

**4. AuthPolicy.** Sin cambios estructurales respecto de `authpolicy-vault-spiffe-ejemplo.yaml` /
`15-authpolicy-vault-spiffe.yaml`. Cambian solo dos valores por namespace: `sharedSecretRef.name`
(al secret propio) y `cache.key.value` (para no compartir cache entre namespaces — si dos
namespaces comparten cache key, el segundo namespace serviría el token cacheado del primero).

## Qué NO resuelve (transparencia)

- Sigue sin resolver la identidad del WORKLOAD dentro del namespace (`bff`, `egress-gw`, etc.): lo
  que se verifica es "esta ServiceAccount dedicada, en este namespace", no "esta app específica
  llamó". Cerrar eso requeriría que la app reenvíe su propio SA token (tocar la app, no decidido
  todavía) o un sidecar (descartado). Esto es una reducción real de superficie — de "todo el
  clúster" a "un namespace" — no la solución completa a OQ-11.
- No resuelve por sí solo el hallazgo de `vault-emisor-spiffe.md` §2quater (claims con `sub`
  impostor devolviendo 200 OK) — ese es un bug de validación del lado destino (en el AuthPolicy que
  consume el JWT), no de cómo se emite. Pero un `sub` con namespace embebido y verificado da una
  condición mucho más específica y más fácil de exigir correctamente ahí
  (`sub.startsWith("spiffe://bancogalicia.com.ar/ns/poc-egress-kuadrant/")`) que la validación
  actual.

## Qué falta confirmar antes de ir más allá de PoC

1. Que `bound_claims` con listas de más de un valor realmente aplica OR/AND como documenta
   HashiCorp — no ejercitado todavía en este Vault con más de un namespace en la lista.
2. Si `sharedSecretRef` puede leer un Secret fuera del namespace del AuthConfig (`kuadrant-system`).
   El schema visto hasta ahora solo trae `{name, key}`, sin campo `namespace` — por eso este diseño
   NO asume que sí y mantiene el Secret en `kuadrant-system` (patrón ya confirmado). Si se
   confirmara que sí, se podría simplificar más: el Secret viviría directamente en el namespace del
   caller, sin necesidad de la RoleBinding cross-namespace del punto 3 del diseño.

## Runbook de onboarding de un namespace nuevo

1. Agregar el namespace (y, si aplica, un nuevo nombre de SA) a la allowlist de Vault — correr
   `00-vault-bootstrap-namespaced.sh` (idempotente: lee el role existente, agrega el namespace a la
   lista si no está, vuelve a escribir el role completo).
2. Generar los manifiestos K8s del namespace:
   `./generate-namespace-signer.sh <namespace> <eks|ocp> > <namespace>-vault-signer.yaml`
3. Aplicar en el cluster que corresponda: `kubectl apply -f <namespace>-vault-signer.yaml`.
4. Disparar el primer login a mano y confirmar el Secret poblado (mismo comando que ya se usa hoy:
   `oc create job --from=cronjob/vault-egress-login-<namespace> ...`).
5. Actualizar (o crear) el AuthPolicy de ese namespace: `sharedSecretRef.name` y `cache.key.value`
   al valor namespaced — ver `poc-egress-kuadrant/origen/15b-authpolicy-vault-spiffe-namespaced.yaml`
   y `generated/authpolicy-poc-ingress-kuadrant-namespaced.yaml` como referencia concreta.

## Archivos

- `00-vault-bootstrap-namespaced.sh` — script Vault, idempotente (requiere el AppRole admin ya
  usado en `vault-emisor-spiffe.md`).
- `01-namespace-signer-template.yaml` — template genérico (placeholders `__NAMESPACE__`,
  `__DIRECTION__`, `__MOUNT__`, `__VAULT_ROLE__`, `__SPIFFE_ROLE__`, `__SECRET_NAME__`,
  `__CLUSTER_NS__`).
- `generate-namespace-signer.sh` — genera el YAML concreto a partir del template (sed).
- `generated/poc-egress-kuadrant-ocp.yaml` — instancia concreta, dirección OCP (mismo cluster,
  mismo namespace `kuadrant-system` destino de escritura, donde hoy corren `14`/`15`, CONFIRMADOS
  en vivo). Este archivo nuevo, en cambio, NO fue aplicado ni probado en vivo todavía.
- `generated/poc-ingress-kuadrant-eks.yaml` — instancia concreta, dirección EKS — mismo estado
  (no probado), análogo en estado a `authpolicy-vault-spiffe-ejemplo.yaml` (BORRADOR).
- `generated/authpolicy-poc-ingress-kuadrant-namespaced.yaml` — variante namespaced de
  `authpolicy-vault-spiffe-ejemplo.yaml` (BORRADOR, mismo estado que el original).
- `../../poc-egress-kuadrant/origen/15b-authpolicy-vault-spiffe-namespaced.yaml` — variante
  namespaced de `15-authpolicy-vault-spiffe.yaml`, que queda intacto como rollback (mismo criterio
  que se usó con `05-authpolicy-wristband.yaml`).
