# Propuesta: fix de confiabilidad del mint OCP→Vault — SUPERSEDIDA, NO HIZO FALTA

**Estado**: diseñada, pero **no aplicada** — se encontró una solución mucho más simple para el
mismo problema (el campo `cache` nativo de `metadata.http` en Authorino, confirmado leyendo el
schema real del CRD), aplicada y confirmada en vivo (29/29 requests exitosos, cero fallos) en
`15-authpolicy-vault-spiffe.yaml`. Este documento queda como referencia/alternativa más robusta
(cachea del lado de Vault, no depende del cache in-memory de cada réplica de Authorino) por si en
algún momento el cache nativo no alcanza — pero no fue necesario aplicarla.

## El problema que resuelve

Documentado en `15-authpolicy-vault-spiffe.yaml`: el mint en vivo (Authorino llamando a
`spiffe/role/egress-gw-ocp/mintjwt` en cada request) falla ~25% de las veces. Causa raíz
confirmada en logs: la latencia real `paas-arqlab` (on-prem) → Vault es ~0.5s (medida en vivo,
`connect:0.17s total:0.5s` contra el endpoint de discovery), mientras que el `ext_authz` de
Kuadrant tiene un timeout fijo de **200ms** (confirmado en los logs del `kuadrant-operator`:
`"auth-service":{"timeout":"200ms","failureMode":"deny"}`). Cuando el mint no entra en esa
ventana, Authorino cancela el contexto (`"context canceled"` en sus logs) y el request falla.

Esto **no pasa del lado EKS→OCP** — ahí la latencia a Vault es ~40-50ms (todo AWS↔HCP), con
margen de sobra para los 200ms.

## La solución

Sacar a Vault del camino del request por completo:

1. El `CronJob` (`14-vault-login-cronjob.yaml`) hace **login y mint juntos** — sin límite de
   200ms, corre a su propio ritmo (cada 4 min, con margen real contra el TTL de 300s del mint).
2. Guarda el resultado en un `ConfigMap`, con la misma forma que devuelve Vault
   (`{"data":{"token":"..."}}`) — así la expresión CEL de la `AuthPolicy`
   (`auth.metadata.vault_mint.data.token`) no cambia.
3. Un `httpd` chiquito (mismo patrón que `jwks-egress`, ya usado en este repo) sirve ese
   `ConfigMap` como un endpoint HTTP local.
4. `metadata.http` de la `AuthPolicy` apunta a ESE servicio local, no a Vault — sin
   `X-Vault-Token`, sin latencia externa, todo el tráfico queda dentro del cluster.

**Confirmado, verificado con el schema real de Authorino**: `response.success.headers` NO puede
leer un `Secret`/`ConfigMap` directo (solo `plain`, `json`, `wristband`) — por eso sigue haciendo
falta el paso `metadata.http`, aunque apunte a algo local en vez de a Vault.

## 1. CronJob modificado — login + mint juntos

Reemplaza el `command` del container `vault-login` en `14-vault-login-cronjob.yaml` (dejando el
resto — RBAC, schedule, ServiceAccount — igual):

```yaml
              command:
                - sh
                - -c
                - |
                  set -eu
                  SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

                  LOGIN_RESP=$(curl -sS -X POST \
                    "https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200/v1/auth/jwt-ocp/login" \
                    -H "X-Vault-Namespace: admin/spiffe" \
                    -d "{\"role\": \"authorino-egress-ocp\", \"jwt\": \"${SA_TOKEN}\"}")
                  CLIENT_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.auth.client_token')
                  if [ -z "$CLIENT_TOKEN" ] || [ "$CLIENT_TOKEN" = "null" ]; then
                    echo "login failed: $LOGIN_RESP" >&2
                    exit 1
                  fi

                  MINT_RESP=$(curl -sS -X POST \
                    "https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200/v1/spiffe/role/egress-gw-ocp/mintjwt" \
                    -H "X-Vault-Token: ${CLIENT_TOKEN}" -H "X-Vault-Namespace: admin/spiffe" \
                    -d '{"audience": "app2.paas-demo.bancogalicia.com.ar"}')
                  MINTED=$(echo "$MINT_RESP" | jq -r '.data.token')
                  if [ -z "$MINTED" ] || [ "$MINTED" = "null" ]; then
                    echo "mint failed: $MINT_RESP" >&2
                    exit 1
                  fi

                  echo "$MINT_RESP" | jq -c '{data: {token: .data.token}}' > /tmp/token.json
                  kubectl -n kuadrant-system create configmap vault-mint-cache-ocp \
                    --from-file=token.json=/tmp/token.json \
                    --dry-run=client -o yaml | kubectl apply -f -
```

También cambiar `spec.schedule` de `"*/30 * * * *"` a `"*/4 * * * *"` (el mint vence a los 5 min,
30 min es demasiado para esto — el login solo podía permitirse 30 min porque su TTL es 1h).

RBAC: cambiar de `Secret`/`vault-egress-token-ocp` a `ConfigMap`/`vault-mint-cache-ocp` en el
`Role`/`RoleBinding` (mismo alcance mínimo, mismo `authorino-authorino` como subject).

## 2. httpd local nuevo

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-mint-cache-ocp
  namespace: kuadrant-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: vault-mint-cache-ocp
  template:
    metadata:
      labels:
        app: vault-mint-cache-ocp
    spec:
      containers:
        - name: httpd
          image: registry.access.redhat.com/ubi9/httpd-24:latest
          ports:
            - containerPort: 8080
              name: http
          volumeMounts:
            - name: token
              mountPath: /var/www/html
              readOnly: true
          readinessProbe:
            httpGet:
              path: /token.json
              port: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: token
          configMap:
            name: vault-mint-cache-ocp
---
apiVersion: v1
kind: Service
metadata:
  name: vault-mint-cache-ocp
  namespace: kuadrant-system
spec:
  selector:
    app: vault-mint-cache-ocp
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

OJO con el orden de apply: el `ConfigMap` lo crea el `CronJob` — aplicar el `CronJob` (y correr un
Job manual) ANTES que este `Deployment`, si no los pods quedan en `ContainerCreating` (el volumen
no puede montar algo que no existe todavía).

## 3. Cambio en la AuthPolicy (`15-authpolicy-vault-spiffe.yaml`)

Reemplazar el bloque `metadata.vault_mint.http` completo por:

```yaml
    metadata:
      "vault_mint":
        http:
          url: "http://vault-mint-cache-ocp.kuadrant-system.svc.cluster.local:8080/token.json"
          method: GET
        priority: 0
```

(sin `headers`, `sharedSecretRef`, `credentials` ni `body` — ya no hace falta nada de eso, es un
`GET` local sin autenticación, protegido igual que `jwks-egress` por estar dentro del cluster).
El resto de la `AuthPolicy` (`authorization.vault_mint_check`, `response.success.headers`) no
cambia — la forma del JSON que devuelve el `ConfigMap` es la misma que devolvía Vault.

## Verificación al aplicar

```
oc -n kuadrant-system exec deploy/vault-mint-cache-ocp -- curl -s localhost:8080/token.json
```

Y repetir el mismo loop de 15 requests seguidos usado para medir el ~25% de fallo, esperando
15/15 en `200` esta vez.
