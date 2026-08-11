#!/usr/bin/env bash
# Prueba de la cascada desde el bastión. Requiere curl y jq.
#
#   ./test-cascada.sh                                        # via HTTPRoute publicado
#   URL=http://10.254.28.68 HOST=app1.paas-demo.bancogalicia.com.ar ./test-cascada.sh
#   URL=http://localhost:8080 ./test-cascada.sh              # con `oc port-forward svc/server 8080:8080`
#
# Por el APIM (3scale/APIcast) — la URL incluye el path del producto y las credenciales van
# en HDRS, separadas por `;`:
#   URL=https://echoserver-b2c.apps.paas-arqlab.bancogalicia.com.ar/v1 INSECURE=1 \
#   HDRS='app_id: 65ce03a7;app_key: b7e44705ce8474b15c90a1b71c9d61d3' ./test-cascada.sh
set -euo pipefail

URL="${URL:-http://app1.paas-demo.bancogalicia.com.ar}"
HOST="${HOST:-}"
CURL=(curl -sS --max-time 15)
[[ -n "$HOST" ]] && CURL+=(-H "Host: $HOST")
[[ -n "${INSECURE:-}" ]] && CURL+=(-k)
# Headers extra separados por `;` (credenciales del APIM, tokens, lo que haga falta).
if [[ -n "${HDRS:-}" ]]; then
  IFS=';' read -ra _hdrs <<< "$HDRS"
  for _h in "${_hdrs[@]}"; do
    [[ -n "${_h// /}" ]] && CURL+=(-H "${_h# }")
  done
fi

hr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

hr "1. Cascada básica — quién contestó en cada hop"
# OJO con el hop 2: en echo-server `.host.hostname` es el header Host y `.host.ip` es la IP
# del cliente. El pod que atendió sale de `.environment.HOSTNAME` (ENABLE__ENVIRONMENT=true).
"${CURL[@]}" "$URL/api/pedidos?id=42" | jq '{
  hop1:          .hop,
  hop1_pod:      .host.hostname,
  hop2_status:   .upstream.status,
  hop2_latencia: .upstream.latencyMs,
  hop2_pod:      .upstream.body.environment.HOSTNAME,
  hop2_vio_ip:   .upstream.body.host.ip,
  hop2_vio_url:  .upstream.body.http.originalUrl
}'

hr "2. Propagación de headers — qué le llegó REALMENTE al hop 2"
# El hop 2 es echo-server: su .request.headers es la verdad sobre lo que salió del hop 1.
"${CURL[@]}" -H 'X-Trace-Demo: hola' -H 'Authorization: Bearer fake.jwt.token' "$URL/" \
  | jq '.upstream.body.request.headers | {
      x_trace_demo:   ."x-trace-demo",
      authorization:  .authorization,
      x_cascade_via:  ."x-cascade-via",
      x_echo_depth:   ."x-echo-depth",
      x_egress_token: ."x-egress-token",
      x_forwarded_for:."x-forwarded-for"
    }'

hr "3. Path y query se reenvían tal cual"
"${CURL[@]}" "$URL/a/b/c?foo=1&foo2=bar" \
  | jq '{hop1_path: .http.originalUrl, hop2_path: .upstream.body.http.originalUrl,
         hop2_query: .upstream.body.request.query}'

hr "4. POST — el body atraviesa la cascada"
"${CURL[@]}" -X POST -H 'Content-Type: application/json' -d '{"monto":100}' "$URL/pagos" \
  | jq '{hop1_body: .request.body, hop2_metodo: .upstream.body.http.method,
         hop2_body: .upstream.body.request.body}'

hr "5. Fallo del hop 2 — X-ECHO-CODE viaja y echo-server devuelve 503"
"${CURL[@]}" -H 'X-ECHO-CODE: 503' "$URL/" | jq '{hop1: .hop, hop2_status: .upstream.status}'

hr "6. Latencia inyectada en el hop 2 (2s) — se mide en el hop 1"
"${CURL[@]}" -H 'X-ECHO-TIME: 2000' "$URL/" | jq '{hop2_latencia_ms: .upstream.latencyMs}'

hr "7. Timeout del hop 2 (6s > UPSTREAM_TIMEOUT_MS=5000) — el hop 1 devuelve 502"
"${CURL[@]}" -o /tmp/casc-timeout.json -w 'HTTP %{http_code}\n' -H 'X-ECHO-TIME: 6000' "$URL/" || true
jq '{hop1: .hop, error: .upstream.error, latencia: .upstream.latencyMs}' /tmp/casc-timeout.json

hr "8. Sin cascada — sólo el hop 1 (aísla si el problema es el salto o la entrada)"
"${CURL[@]}" -H 'X-Cascade-Skip: 1' "$URL/" | jq '{hop1: .hop, upstream: .upstream}'

hr "9. Respuesta completa cruda"
"${CURL[@]}" "$URL/" | jq .
