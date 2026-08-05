#!/usr/bin/env bash
# Repara y deja el camino origen -> destino simulado funcionando, atacando las dos fallas
# observadas en la corrida del 2026-08-04:
#
#   A. Token válido rechazado con 401 en el destino.
#      Que sea 401 y no 403 dice que falló la AUTENTICACIÓN, no la autorización por claims:
#      Authorino no pudo verificar la firma. Con el `kid` coincidiendo, quedan tres causas:
#      el JWKS sin `alg`/`use` (el verificador descarta la key), el server de JWKS no
#      sirviendo, o Authorino con un fetch fallido cacheado.
#
#   B. Timeout de 5 s desde el gateway de egreso hacia el destino.
#      El `ServiceEntry` con `resolution: DNS` no pisó la resolución: Envoy resolvió el FQDN
#      real a 172.19.105.122 (el NLB de EKS, inalcanzable) en vez de usar los `endpoints`.
#      Se corrige con `resolution: STATIC` y la ClusterIP del Gateway simulado.
#
# Es idempotente: se puede correr las veces que haga falta.
set -uo pipefail

NS="${NS:-echoserver}"
NS_SIM="${NS_SIM:-echoserver-eks-sim}"
FQDN="${FQDN:-app2.paas-demo.bancogalicia.com.ar}"
HOST_INTERNO="${HOST_INTERNO:-server2.echoserver.svc.cluster.local:8080}"
URL="${URL:-http://10.254.28.68}"
HOST="${HOST:-app1.paas-demo.bancogalicia.com.ar}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -t 1 ]]; then V=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; Z=$'\e[0m'; else V=; R=; B=; D=; Z=; fi
paso(){ printf '\n%s>> %s%s\n' "$B" "$1" "$Z"; }
ok(){   printf '   %s✔%s %s\n' "$V" "$Z" "$1"; }
err(){  printf '   %s✘%s %s\n' "$R" "$Z" "$1"; }
inf(){  printf '   %s%s%s\n' "$D" "$1" "$Z"; }

directo() {  # $1=ip  $2=token(opcional) -> imprime el status HTTP
  oc -n "$NS" exec -i deploy/server -- python3 - "$1" "$FQDN" "$HOST_INTERNO" "${2-}" <<'PY' 2>/dev/null || echo ERROR
import http.client, socket, ssl, sys
ip, fqdn, hosthdr, tok = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ctx = ssl._create_unverified_context()
try:
    tls = ctx.wrap_socket(socket.create_connection((ip, 443), timeout=8), server_hostname=fqdn)
    c = http.client.HTTPSConnection(fqdn, 443, context=ctx, timeout=8); c.sock = tls
    h = {"Host": hosthdr}
    if tok: h["x-egress-token"] = tok
    c.request("GET", "/", headers=h)
    print(c.getresponse().status)
except Exception as e:
    print("ERROR:%s" % type(e).__name__)
PY
}

# `.upstream.body` es un STRING cuando el hop 2 no devolvió JSON — típicamente una página de
# error de Envoy ("upstream connect error…", "RBAC: access denied"). Indexarlo como objeto
# revienta el jq y esconde la causa, así que se distingue el tipo antes.
token_fresco() {
  curl -s --max-time 15 -H "Host: $HOST" "$URL/" \
    | jq -r '.upstream.body | if type=="object" then (.request.headers["x-egress-token"] // empty) else empty end'
}

# Muestra qué está pasando realmente en el camino local. Se llama cuando no hay token.
diagnostico_camino_local() {
  local j; j=$(curl -s --max-time 15 -H "Host: $HOST" "$URL/")
  inf "estado del camino local:"
  jq -r '"     upstream.status = \(.upstream.status)
     upstream.error  = \(.upstream.error // "-")
     tipo de body    = \(.upstream.body | type)
     body            = \(.upstream.body | if type=="object" then "(JSON ok)" else (tostring | .[0:300]) end)"' <<<"$j" 2>/dev/null \
    || { inf "     la respuesta ni siquiera es JSON:"; printf '%s\n' "${j:0:300}" | sed 's/^/     /'; }
  inf "estado de la AuthPolicy de EGRESO (la que firma):"
  oc -n "$NS" get authpolicy egress-server2-jwt \
    -o jsonpath='     Accepted={.status.conditions[?(@.type=="Accepted")].status} Enforced={.status.conditions[?(@.type=="Enforced")].status}{"\n"}' 2>/dev/null
  inf "últimas líneas de Authorino sobre la firma:"
  local A; A=$(oc -n kuadrant-system get deploy -o name 2>/dev/null | grep -i authorino | head -1)
  oc -n kuadrant-system logs "$A" --since=5m 2>/dev/null \
    | grep -iE 'wristband|signing|sign|denied|error' | tail -8 | sed 's/^/     /'
}

# ─────────────────────────────────────────────────────────────────────── A. el JWKS
paso "A1. Normalizar el JWKS y recrear el ConfigMap"

JWKS="$DIR/../keys/out/jwks.json"
[[ -f "$JWKS" ]] || { err "no existe $JWKS — correr keys/gen-signing-key.sh primero"; exit 1; }
inf "clave publicada: $(jq -c '.keys[0] | {kid, kty, alg, use}' "$JWKS")"

# `alg` y `use` son opcionales en el RFC pero conviene que estén explícitos. Se agregan sin
# pisar lo que ya haya, y sin recortar campos: el JWK de RSA lleva n/e y el de EC crv/x/y.
jq '.keys |= map(. + {alg:(.alg // "RS256"), use:(.use // "sig")})' "$JWKS" > /tmp/jwks-norm.json
inf "normalizado:     $(jq -c '.keys[0] | {kid, kty, alg, use}' /tmp/jwks-norm.json)"

# El verificador `jwt` de Authorino (go-oidc) SÓLO acepta RS256 — medido el 2026-08-05.
# Con una clave EC el destino rechaza el 100% de los tokens con un 401 indistinguible de
# "falta el token", y el AuthConfig igual queda Ready=True.
if [[ "$(jq -r '.keys[0].kty' "$JWKS")" != "RSA" ]]; then
  err "el JWKS es $(jq -r '.keys[0].kty' "$JWKS"), no RSA — Authorino va a rechazar TODOS los tokens"
  inf "  regenerar con la versión actual del script y re-aplicar el Secret:"
  inf "    ../keys/gen-signing-key.sh && oc apply -f ../keys/out/secret.yaml"
  inf "  y confirmar que origen/05 y 00-smoke-wristband/04 digan 'algorithm: RS256'"
fi

oc -n "$NS_SIM" create configmap jwks-egress-origen --from-file=jwks.json=/tmp/jwks-norm.json \
  --dry-run=client -o yaml | oc apply -f - >/dev/null && ok "ConfigMap actualizado" || err "no se pudo actualizar el ConfigMap"

paso "A2. Reiniciar el server de JWKS (el ConfigMap montado no se recarga solo a tiempo)"
oc -n "$NS_SIM" rollout restart deploy/jwks-egress >/dev/null 2>&1
oc -n "$NS_SIM" rollout status deploy/jwks-egress --timeout=90s >/dev/null 2>&1 \
  && ok "jwks-egress Ready" || err "jwks-egress no quedó Ready — revisar 'oc -n $NS_SIM describe deploy jwks-egress'"

paso "A3. Comprobar que el JWKS se sirve de verdad"
SERVIDO=$(oc -n "$NS" exec -i deploy/server -- python3 -c \
  "import urllib.request;print(urllib.request.urlopen('http://jwks-egress.$NS_SIM.svc.cluster.local:8080/jwks.json',timeout=6).read().decode())" 2>&1)
if jq -e '.keys[0].kid' >/dev/null 2>&1 <<<"$SERVIDO"; then
  ok "servido: $(jq -c '.keys[0] | {kid, alg, use}' <<<"$SERVIDO")"
else
  err "el endpoint NO devuelve un JWKS válido. Esto solo ya explica el 401 de todos los tokens:"
  printf '%s\n' "$SERVIDO" | head -5
fi

paso "A4. Forzar a Authorino a re-leer el JWKS (cachea el fetch, incluso el fallido)"
# Recrear la AuthPolicy regenera el AuthConfig y con él el cache de la key.
oc -n "$NS_SIM" delete authpolicy server2-ingress-jwt >/dev/null 2>&1
sleep 3
oc apply -f "$DIR/05-authpolicy-jwt.yaml" >/dev/null 2>&1
for _ in $(seq 1 20); do
  E=$(oc -n "$NS_SIM" get authpolicy server2-ingress-jwt -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
  [[ "$E" == "True" ]] && break; sleep 3
done
[[ "${E:-}" == "True" ]] && ok "AuthPolicy Enforced" || err "AuthPolicy no llegó a Enforced (=${E:-vacio})"

paso "A5. Probar un token fresco contra el destino"
SIMIP=$(oc -n "$NS_SIM" get svc ingress-sim-openshift-default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[[ -n "$SIMIP" ]] && inf "ClusterIP del gateway simulado: $SIMIP" || { err "no se pudo leer la ClusterIP del gateway simulado"; exit 1; }

TOK=$(token_fresco)
if [[ -z "$TOK" ]]; then
  err "no se pudo obtener un wristband desde $URL"
  diagnostico_camino_local
  inf "el paso B (ServiceEntry) se aplica igual: es independiente de esto."
fi
ST=$(directo "$SIMIP" "$TOK")
if [[ "$ST" == "200" ]]; then
  ok "token válido -> 200   ← REPARADO"
else
  err "token válido -> $ST   (sigue fallando)"
  inf "razón según Authorino:"
  AUTH=$(oc -n kuadrant-system get deploy -o name 2>/dev/null | grep -i authorino | head -1)
  oc -n kuadrant-system logs "$AUTH" --since=3m 2>/dev/null \
    | grep -iE 'jwks|invalid|verif|unauthenticated|failed|error' | tail -15 | sed 's/^/     /'
  inf "si dice 'invalid signature': la pública del JWKS no corresponde a la privada que firma."
  inf "  comparar y, si difieren, volver a correr keys/gen-signing-key.sh y re-aplicar el Secret:"
  inf "  oc -n kuadrant-system get secret egress-echoserver-1 -o jsonpath='{.data.key\\.pem}' | base64 -d | openssl ec -pubout"
fi

# ───────────────────────────────────────────────────────── B. el camino del egreso
paso "B1. ServiceEntry STATIC apuntado a la ClusterIP del destino simulado"
sed "s|address: \"0.0.0.0\".*|address: \"$SIMIP\"|" "$DIR/06-serviceentry-sim.yaml" > /tmp/se-sim.yaml
grep -q "address: \"$SIMIP\"" /tmp/se-sim.yaml && ok "endpoint fijado en $SIMIP" || { err "no se pudo rellenar el endpoint"; exit 1; }
oc apply -n "$NS" -f /tmp/se-sim.yaml >/dev/null && ok "ServiceEntry aplicado" || err "falló el apply del ServiceEntry"
oc apply -n "$NS" -f "$DIR/../origen/04-destinationrule-tls.yaml" >/dev/null \
  && ok "DestinationRule (TLS origination) aplicado" || err "falló el apply del DestinationRule"

paso "B2. Verificar qué endpoint tiene realmente el Envoy de egreso"
inf "es LA comprobación que faltaba: si acá aparece 172.19.105.122, sigue resolviendo por DNS al NLB real"
sleep 5
GWPOD=$(oc -n "$NS" get pod -l gateway.networking.k8s.io/gateway-name=egress-gw -o name 2>/dev/null | head -1)
EPS=$(oc -n "$NS" exec "$GWPOD" -c istio-proxy -- \
        pilot-agent request GET clusters 2>/dev/null | grep -F "$FQDN" | grep -E 'cx_active|::[0-9]' | head -5)
[[ -z "$EPS" ]] && EPS=$(oc -n "$NS" exec "$GWPOD" -c istio-proxy -- curl -s localhost:15000/clusters 2>/dev/null | grep -F "$FQDN" | head -5)
if grep -q "$SIMIP" <<<"$EPS"; then ok "el cluster de Envoy apunta a $SIMIP"
elif grep -q "172.19.105.122" <<<"$EPS"; then err "sigue apuntando al NLB real (172.19.105.122) — el ServiceEntry no tomó efecto"
else inf "sin lectura concluyente:"; printf '%s\n' "${EPS:-(vacío)}" | head -5 | sed 's/^/     /'; fi

paso "Listo — volver a correr la batería"
inf "./run-escenarios.sh --aplicar"
