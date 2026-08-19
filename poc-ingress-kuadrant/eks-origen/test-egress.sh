#!/usr/bin/env bash
# Pega DIRECTO contra egress-gw (salteando a bff a propósito), desde un pod
# efímero dentro del cluster (el Gateway es ClusterIP, no expuesto afuera).
#
# Es el test de la capa Gateway/AuthPolicy en sí — status code crudo (401 sin
# token, etc.), sin el wrapper de bff que además esconde el status real salvo
# que MIRROR_UPSTREAM_STATUS=true (ver 00-bff.yaml). Para medir la
# experiencia real del consumidor (a través de bff, con latencia y pod que
# atendió), usar medir-latencia.sh en su lugar.
#
# Uso:
#   ./test-egress.sh                # un solo request
#   ./test-egress.sh -n 20          # 20 requests, cuenta status codes
#   ./test-egress.sh -v             # un request, con el body completo (curl -v)
#
# Requiere: kubectl con contexto devops-cilium-1-35 (o pasar KCTX=... antes).
#
# NO usa `kubectl run -i --rm` (attach interactivo): en este entorno corta el
# stream antes de que el loop termine, perdiendo requests silenciosamente
# (verificado: con -i --rm un loop de 5 sólo entregaba 2). En su lugar crea el
# pod, espera a que termine, lee los logs y lo borra aparte.
set -euo pipefail

KCTX="${KCTX:-devops-cilium-1-35}"
NS="poc-ingress-kuadrant"
HOST_HDR="backend.${NS}.svc.cluster.local"
GW_SVC="egress-gw-istio.${NS}.svc.cluster.local:8080"

N=1
VERBOSE=0
while getopts "n:v" opt; do
  case "$opt" in
    n) N="$OPTARG" ;;
    v) VERBOSE=1 ;;
    *) echo "uso: $0 [-n N] [-v]"; exit 2 ;;
  esac
done

POD="egresstest-$RANDOM"
cleanup() { kubectl --context="$KCTX" -n "$NS" delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ "$VERBOSE" = "1" ]; then
  CMD="curl -sS -v -H 'Host: $HOST_HDR' --max-time 10 'http://$GW_SVC/'"
else
  CMD="for i in \$(seq 1 $N); do curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: $HOST_HDR' --max-time 10 'http://$GW_SVC/'; done"
fi

kubectl --context="$KCTX" -n "$NS" run "$POD" --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal --command -- sh -c "$CMD" >/dev/null

kubectl --context="$KCTX" -n "$NS" wait --for=condition=Ready=false pod/"$POD" --timeout=30s >/dev/null 2>&1 || true
# esperar a que el pod termine (Completed/Error), no sólo a que deje de estar Ready
for _ in $(seq 1 30); do
  phase=$(kubectl --context="$KCTX" -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 1
done

if [ "$VERBOSE" = "1" ]; then
  kubectl --context="$KCTX" -n "$NS" logs "$POD"
else
  kubectl --context="$KCTX" -n "$NS" logs "$POD" | grep -E '^[0-9]{3}$' | sort | uniq -c | sort -rn
fi
