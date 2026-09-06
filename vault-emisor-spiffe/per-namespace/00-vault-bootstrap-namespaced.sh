#!/usr/bin/env bash
# Bootstrap / actualizacion IDEMPOTENTE del lado Vault para "vault-signer por namespace".
#
# Que hace:
#   1. Lee el role auth/jwt (EKS) o auth/jwt-ocp (OCP) existente (authorino-egress /
#      authorino-egress-ocp, ya confirmados en vivo).
#   2. Agrega el namespace nuevo (y el nombre de SA, por defecto "vault-egress-signer") a
#      bound_claims, SIN pisar el resto de la config del role (bound_audiences, claim_mappings,
#      ttl, etc.) ni namespaces ya presentes.
#   3. Actualiza el template del spiffe role correspondiente (egress-gw / egress-gw-ocp) para que
#      el "sub" del JWT-SVID incluya el namespace verificado.
#
# Requiere: vault CLI + jq, autenticado ya contra admin/spiffe con permisos de administracion
# sobre auth/jwt* y spiffe/role/* (mismo AppRole admin usado en vault-emisor-spiffe.md).
#
# Uso:
#   VAULT_ADDR=https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200 \
#   VAULT_NAMESPACE=admin/spiffe \
#   VAULT_TOKEN=<token admin> \
#     ./00-vault-bootstrap-namespaced.sh <namespace> <eks|ocp> [sa_name]
#
# Ejemplo:
#   ./00-vault-bootstrap-namespaced.sh poc-egress-kuadrant ocp
#   ./00-vault-bootstrap-namespaced.sh poc-ingress-kuadrant eks

set -euo pipefail

NAMESPACE="${1:?uso: $0 <namespace> <eks|ocp> [sa_name]}"
DIRECTION="${2:?uso: $0 <namespace> <eks|ocp> [sa_name]}"
SA_NAME="${3:-vault-egress-signer}"

: "${VAULT_ADDR:?falta VAULT_ADDR}"
: "${VAULT_NAMESPACE:?falta VAULT_NAMESPACE (esperado: admin/spiffe)}"
: "${VAULT_TOKEN:?falta VAULT_TOKEN}"

case "$DIRECTION" in
  eks)
    JWT_MOUNT="auth/jwt"
    JWT_ROLE="authorino-egress"
    SPIFFE_ROLE="egress-gw"
    ;;
  ocp)
    JWT_MOUNT="auth/jwt-ocp"
    JWT_ROLE="authorino-egress-ocp"
    SPIFFE_ROLE="egress-gw-ocp"
    ;;
  *)
    echo "direccion invalida: $DIRECTION (esperado: eks|ocp)" >&2
    exit 1
    ;;
esac

echo "== [$DIRECTION] leyendo role actual: ${JWT_MOUNT}/role/${JWT_ROLE} =="
CURRENT_ROLE_JSON="$(vault read -format=json "${JWT_MOUNT}/role/${JWT_ROLE}")"

# Namespaces y SA names ya presentes en bound_claims, mas el nuevo, sin duplicar.
MERGED_NAMESPACES="$(echo "$CURRENT_ROLE_JSON" | jq -c \
  --arg ns "$NAMESPACE" \
  '(.data.bound_claims["kubernetes.io/namespace"] // []) as $cur
   | ($cur + [$ns]) | unique')"

MERGED_SA_NAMES="$(echo "$CURRENT_ROLE_JSON" | jq -c \
  --arg sa "$SA_NAME" \
  '(.data.bound_claims["kubernetes.io/serviceaccount/name"] // []) as $cur
   | ($cur + [$sa]) | unique')"

echo "   namespaces resultantes: ${MERGED_NAMESPACES}"
echo "   service accounts resultantes: ${MERGED_SA_NAMES}"

# Se reescribe el role completo (Vault no soporta PATCH parcial de bound_claims): se toman los
# demas campos tal cual estaban (bound_audiences, claim_mappings, ttl, etc.) y solo se reemplaza
# bound_claims con la version fusionada.
echo "$CURRENT_ROLE_JSON" | jq \
  --argjson namespaces "$MERGED_NAMESPACES" \
  --argjson sanames "$MERGED_SA_NAMES" \
  '.data
   | .bound_claims["kubernetes.io/namespace"] = $namespaces
   | .bound_claims["kubernetes.io/serviceaccount/name"] = $sanames' \
  > /tmp/role-payload.json

echo "== [$DIRECTION] escribiendo ${JWT_MOUNT}/role/${JWT_ROLE} (bound_claims ampliado) =="
vault write "${JWT_MOUNT}/role/${JWT_ROLE}" @/tmp/role-payload.json
rm -f /tmp/role-payload.json

echo "== [$DIRECTION] verificando accessor del mount ${JWT_MOUNT} =="
ACCESSOR="$(vault auth list -format=json | jq -r --arg m "${JWT_MOUNT}/" '.[$m].accessor')"
if [ -z "$ACCESSOR" ] || [ "$ACCESSOR" = "null" ]; then
  echo "no se pudo resolver el accessor de ${JWT_MOUNT} — abortando template de spiffe role" >&2
  exit 1
fi
echo "   accessor: ${ACCESSOR}"

SUB_TEMPLATE="spiffe://bancogalicia.com.ar/ns/{{identity.entity.aliases.${ACCESSOR}.metadata.service_account_namespace}}/sa/{{identity.entity.aliases.${ACCESSOR}.metadata.service_account_name}}"

echo "== [$DIRECTION] leyendo spiffe/role/${SPIFFE_ROLE} actual =="
CURRENT_SPIFFE_JSON="$(vault read -format=json "spiffe/role/${SPIFFE_ROLE}")"

echo "$CURRENT_SPIFFE_JSON" | jq \
  --arg sub "$SUB_TEMPLATE" \
  '.data.template.sub = $sub' \
  > /tmp/spiffe-payload.json

echo "== [$DIRECTION] escribiendo spiffe/role/${SPIFFE_ROLE} (sub template = namespace verificado) =="
vault write "spiffe/role/${SPIFFE_ROLE}" @/tmp/spiffe-payload.json
rm -f /tmp/spiffe-payload.json

echo "== listo. Confirmar con: =="
echo "   vault read ${JWT_MOUNT}/role/${JWT_ROLE}"
echo "   vault read spiffe/role/${SPIFFE_ROLE}"
