#!/usr/bin/env bash
# Renderiza 01-namespace-signer-template.yaml para un namespace + direccion concretos.
#
# Uso:
#   ./generate-namespace-signer.sh <namespace> <eks|ocp> [vault_addr] > <namespace>-vault-signer.yaml
#
# Ejemplos (mismos valores reales que usan 13/14-vault-login-cronjob.yaml):
#   ./generate-namespace-signer.sh poc-egress-kuadrant ocp
#   ./generate-namespace-signer.sh poc-ingress-kuadrant eks

set -euo pipefail

NAMESPACE="${1:?uso: $0 <namespace> <eks|ocp> [vault_addr]}"
DIRECTION="${2:?uso: $0 <namespace> <eks|ocp> [vault_addr]}"
VAULT_ADDR_ARG="${3:-https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200}"

case "$DIRECTION" in
  eks)
    MOUNT="auth/jwt"
    VAULT_ROLE="authorino-egress"
    SPIFFE_ROLE="egress-gw"
    ;;
  ocp)
    MOUNT="auth/jwt-ocp"
    VAULT_ROLE="authorino-egress-ocp"
    SPIFFE_ROLE="egress-gw-ocp"
    ;;
  *)
    echo "direccion invalida: $DIRECTION (esperado: eks|ocp)" >&2
    exit 1
    ;;
esac

SECRET_NAME="vault-egress-token-${NAMESPACE}"
CLUSTER_NS="kuadrant-system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/01-namespace-signer-template.yaml"

echo "# GENERADO por generate-namespace-signer.sh a partir de 01-namespace-signer-template.yaml"
echo "# namespace=${NAMESPACE} direccion=${DIRECTION} mount=${MOUNT} vault_role=${VAULT_ROLE}"
echo "# spiffe_role=${SPIFFE_ROLE} secret=${SECRET_NAME} (en ${CLUSTER_NS})"
echo "# NO editar a mano — volver a generar si cambian los parametros. Estado: NO probado en vivo"
echo "# todavia (ver vault-emisor-spiffe/per-namespace/README.md)."
echo "#"

# Se salta el bloque de comentarios del template (documentacion de placeholders) y se renderiza
# solo el manifiesto real, que empieza en la primera linea "apiVersion:".
awk '/^apiVersion:/{found=1} found' "$TEMPLATE" | sed \
  -e "s#__NAMESPACE__#${NAMESPACE}#g" \
  -e "s#__DIRECTION__#${DIRECTION}#g" \
  -e "s#__MOUNT__#${MOUNT}#g" \
  -e "s#__VAULT_ROLE__#${VAULT_ROLE}#g" \
  -e "s#__SPIFFE_ROLE__#${SPIFFE_ROLE}#g" \
  -e "s#__SECRET_NAME__#${SECRET_NAME}#g" \
  -e "s#__CLUSTER_NS__#${CLUSTER_NS}#g" \
  -e "s#__VAULT_ADDR__#${VAULT_ADDR_ARG}#g"
