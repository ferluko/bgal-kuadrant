#!/usr/bin/env bash
# Gates previos al montaje del destino OCP. **Sólo lectura**: no aplica ni modifica nada.
#
#   CTX_ORI=paas-arqlab CTX_DST=paas-dev1-lowmz ./preflight.sh
#
# Variables: CTX_ORI, CTX_DST (contextos de oc), DST_IP (ingress VIP del destino), FQDN,
# NS, NS_DST, URL, HOST. Ver los defaults abajo.
#
# Está pensado para correrse ANTES de aplicar 20-25, y de nuevo después de cada paso que
# falle. Cada chequeo termina en PASS / FALLA / SKIP con el valor obtenido al lado; los
# SKIP no son fallos, indican qué falta montar para que ese chequeo tenga sentido.
#
# El orden no es casual: primero lo que hace inviable el resto (conectividad L3 entre
# sitios), después las piezas de plataforma del destino, y al final lo que se puede
# arreglar en minutos.
set -uo pipefail

CTX_ORI="${CTX_ORI:-}"
CTX_DST="${CTX_DST:-}"
DST_IP="${DST_IP:-10.254.34.2}"                            # ingress VIP de paas-dev1-lowmz
FQDN="${FQDN:-app2.paas-demo.bancogalicia.com.ar}"
NS="${NS:-echoserver}"                                     # ns en el origen
NS_DST="${NS_DST:-echoserver}"                             # ns en el destino
HOST_INTERNO="${HOST_INTERNO:-server2.echoserver.svc.cluster.local:8080}"
CERT_SECRET="${CERT_SECRET:-paas-demo-wildcard-tls}"
GW="${GW:-ingress-gw}"
LISTENER="${LISTENER:-https}"
ROUTE="${ROUTE:-server2}"
POLICY="${POLICY:-server2-ingress-jwt}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -t 1 ]]; then V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; Z=$'\e[0m'
else V=; R=; A=; B=; D=; Z=; fi

PASS=0; FALLA=0; SKIP=0; FALLIDOS=()
esc()  { printf '\n%s══ %s ══%s\n%s   %s%s\n' "$B" "$1" "$Z" "$D" "$2" "$Z"; }
ok()   { printf '  %s✔ PASS%s   %-46s %s\n' "$V" "$Z" "$1" "${2-}"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘ FALLA%s  %-46s obtenido=%s  esperado=%s\n' "$R" "$Z" "$1" "${2-}" "${3-}"; FALLA=$((FALLA+1)); FALLIDOS+=("$1"); }
skip() { printf '  %s− SKIP%s    %-46s %s\n' "$A" "$Z" "$1" "${2-}"; SKIP=$((SKIP+1)); }
nota() { printf '  %s%s%s\n' "$D" "$1" "$Z"; }
eq()   { [[ "$2" == "$3" ]] && ok "$1" "$2" || bad "$1" "$2" "$3"; }

oco() { oc ${CTX_ORI:+--context="$CTX_ORI"} "$@"; }
ocd() { oc ${CTX_DST:+--context="$CTX_DST"} "$@"; }

# Sonda de red desde un pod del ORIGEN hacia la VIP del destino. Va por `oc exec` al pod
# `server` (tiene python3) en vez de crear un pod por prueba: es más rápido y no depende
# de que la imagen de debug traiga curl ni de que el admission del cluster acepte `oc debug`.
#
# Devuelve un JSON con todo lo que importa de una sola pasada: tiempo de TCP, tiempo del
# handshake, nombres que trae el certificado que presenta el otro lado, status HTTP y —lo
# más valioso— el skew de reloj contra el destino, leído del header `Date` de la respuesta.
sonda() {
  local tok="${1-}"
  oco -n "$NS" exec -i deploy/server -- python3 - "$DST_IP" "$FQDN" "$HOST_INTERNO" "$tok" <<'PY' 2>/dev/null || echo '{"error":"no se pudo ejecutar en deploy/server"}'
import http.client, json, re, socket, ssl, sys, time
from email.utils import parsedate_to_datetime

ip, fqdn, hosthdr, tok = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
out = {}
try:
    t0 = time.time()
    s = socket.create_connection((ip, 443), timeout=8)
    out["tcp_ms"] = round((time.time() - t0) * 1000)
except Exception as e:
    print(json.dumps({"error": "tcp:%s" % type(e).__name__})); raise SystemExit

ctx = ssl._create_unverified_context()
try:
    t0 = time.time()
    tls = ctx.wrap_socket(s, server_hostname=fqdn)
    out["tls_ms"] = round((time.time() - t0) * 1000)
    der = tls.getpeercert(True) or b""
    # Sin validación de cadena `getpeercert()` devuelve vacío, así que los nombres se
    # extraen del DER crudo. Alcanza para distinguir el wildcard del cert default del router.
    out["cert"] = sorted({n.decode() for n in re.findall(rb'[A-Za-z0-9*.\-]{6,}\.[a-z]{2,}', der)})[:6]
except Exception as e:
    out["error"] = "tls:%s" % type(e).__name__
    print(json.dumps(out)); raise SystemExit

try:
    c = http.client.HTTPSConnection(fqdn, 443, context=ctx, timeout=8); c.sock = tls
    h = {"Host": hosthdr}
    if tok:
        h["x-egress-token"] = tok
    t0 = time.time()
    c.request("GET", "/", headers=h)
    r = c.getresponse()
    out["http"] = r.status
    out["http_ms"] = round((time.time() - t0) * 1000)
    d = r.getheader("Date")
    if d:
        out["skew_s"] = round(parsedate_to_datetime(d).timestamp() - time.time())
except Exception as e:
    out["error"] = "http:%s" % type(e).__name__
print(json.dumps(out))
PY
}

j() { printf '%s' "${1:-}" | jq -r "${2} // \"null\"" 2>/dev/null || echo null; }

printf '%sPoC egreso — preflight del destino OCP%s\n' "$B" "$Z"
nota "origen: ${CTX_ORI:-<contexto actual>}   destino: ${CTX_DST:-<contexto actual>}   VIP: $DST_IP"
for b in oc jq; do command -v $b >/dev/null || { echo "falta '$b' en el PATH"; exit 2; }; done
[[ -n "$CTX_DST" && "$CTX_ORI" == "$CTX_DST" ]] && { echo "CTX_ORI y CTX_DST son el mismo contexto"; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────────────
esc "P1 — Conectividad entre sitios" \
    "el gate que hace inviable todo lo demás: PGA -> Casa Matriz, TCP 443 contra el router"

S=$(sonda)
ERR=$(j "$S" '.error')
if [[ "$ERR" != "null" ]]; then
  bad "TCP 443 hacia $DST_IP" "$ERR" "conexión establecida"
  nota "no está documentado en el repo que exista camino L3 entre 10.254.28.0/24 (PGA) y"
  nota "10.254.34.0/24 (CMZ): si esto falla, es un pedido a redes y bloquea la PoC entera."
  nota "El resto de los chequeos del destino sigue corriendo: son independientes."
else
  ok "TCP 443 hacia $DST_IP" "$(j "$S" '.tcp_ms') ms"
  ok "handshake TLS" "$(j "$S" '.tls_ms') ms"
  nota "RTT + handshake es el costo que la simulación local NO mide y que se le suma a cada request"

  CERT=$(j "$S" '.cert|join(", ")')
  if [[ "$CERT" == *"paas-demo"* ]]; then
    ok "el SNI eligió el gateway del destino" "$CERT"
  elif [[ "$CERT" == "null" ]]; then
    skip "certificado que presenta el destino" "no se pudo leer"
  else
    bad "el SNI eligió el gateway del destino" "$CERT" "un cert con paas-demo"
    nota "presenta el certificado DEFAULT del router: el SNI no matcheó ninguna Route de"
    nota "passthrough. Es lo normal ANTES de aplicar 22; después de aplicarla, es un fallo."
  fi

  ST=$(j "$S" '.http')
  case "$ST" in
    401) ok "GET sin token -> 401" "$ST"; nota "el destino está montado y enforcea: es la prueba negativa (a)" ;;
    200) bad "GET sin token -> 401" "$ST" "401"
         nota "el destino CONTESTA SIN EXIGIR TOKEN. Peor que un 404: revisar que la AuthPolicy (25)"
         nota "esté Enforced y que el Gateway lleve la label kuadrant.io/gateway." ;;
    503) skip "GET sin token" "503 del router — Route sin endpoints o gateway aún no montado" ;;
    *)   skip "GET sin token" "status=$ST (esperado 401 con el destino montado)" ;;
  esac

  SK=$(j "$S" '.skew_s')
  if [[ "$SK" == "null" ]]; then
    skip "skew de reloj entre clusters" "el destino no devolvió header Date"
  elif (( ${SK#-} <= 30 )); then
    ok "skew de reloj entre clusters" "${SK}s"
  else
    bad "skew de reloj entre clusters" "${SK}s" "|skew| <= 30s"
    nota "con tokenDuration=300 un skew grande hace que el destino rechace TODOS los tokens"
    nota "con un 401 indistinguible del de una firma inválida. Revisar chrony en ambos lados."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────
esc "P2 — Plataforma en el cluster destino" \
    "que exista lo que los manifiestos 21-25 dan por sentado"

GC=$(ocd get gatewayclass openshift-default -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
eq "GatewayClass openshift-default Accepted" "${GC:-ausente}" "True"
[[ "${GC:-}" != "True" ]] && nota "crearla siguiendo 01_apim/13_guia_instalacion_rhcl_ocp420.md §GatewayClass"

KU=$(ocd -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
eq "Kuadrant/RHCL Ready" "${KU:-ausente}" "True"
[[ "${KU:-}" != "True" ]] && nota "no hay evidencia en el repo de RHCL instalado en este cluster: instalarlo con la misma guía"

for crd in serviceentries.networking.istio.io destinationrules.networking.istio.io; do
  ocd get crd "$crd" >/dev/null 2>&1 && ok "CRD $crd" "presente" || skip "CRD $crd" "ausente (sólo lo necesita el ORIGEN)"
done

if ocd -n "$NS_DST" get secret "$CERT_SECRET" >/dev/null 2>&1; then
  T=$(ocd -n "$NS_DST" get secret "$CERT_SECRET" -o jsonpath='{.type}')
  eq "Secret del wildcard es kubernetes.io/tls" "$T" "kubernetes.io/tls"
  N=$(ocd -n "$NS_DST" get secret "$CERT_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null | grep -c 'BEGIN CERTIFICATE')
  if (( N > 1 )); then ok "tls.crt trae la cadena" "$N certificados"
  else bad "tls.crt trae la cadena" "$N certificado" ">1 (hoja + intermedias)"
       nota "con sólo la hoja, el origen no puede armar la cadena y el handshake falla con un 503 genérico"
  fi
else
  skip "Secret $CERT_SECRET en $NS_DST" "todavía no creado — ver 21-gateway-ingress.yaml"
fi

CH=$(ocd auth can-i create routes/custom-host -n "$NS_DST" 2>/dev/null)
eq "permiso para Route con host propio" "${CH:-no}" "yes"
[[ "${CH:-no}" != "yes" ]] && nota "sin routes/custom-host no se puede publicar app2.paas-demo... en este cluster"

# ─────────────────────────────────────────────────────────────────────────────────────
esc "P3 — El origen puede emitir tokens" \
    "que haya wristband para probar: sin esto el destino no se puede validar de punta a punta"

AP=$(oco -n "$NS" get authpolicy egress-server2-jwt \
      -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}/{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
eq "AuthPolicy de egreso Accepted/Enforced" "${AP:-ausente}" "True/True"

JWKS="$DIR/../keys/out/jwks.json"
if [[ -f "$JWKS" ]]; then
  KTY=$(jq -r '.keys[0].kty' "$JWKS"); KID=$(jq -r '.keys[0].kid' "$JWKS")
  eq "el JWKS del origen es RSA" "$KTY" "RSA"
  nota "kid a pinear en el destino: $KID"
  if CMK=$(ocd -n "$NS_DST" get cm jwks-egress-origen -o jsonpath='{.data.jwks\.json}' 2>/dev/null | jq -r '.keys[0].kid' 2>/dev/null) && [[ -n "$CMK" ]]; then
    eq "kid pineado en el destino == kid del origen" "$CMK" "$KID"
  else
    skip "kid pineado en el destino" "ConfigMap jwks-egress-origen todavía no creado"
  fi
else
  skip "JWKS del origen" "falta $JWKS — correr keys/gen-signing-key.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────────────
esc "P4 — Estado del DNS" \
    "informativo: a dónde apunta hoy app2, para saber qué cambia el corte del CNAME"

RES=$(oco -n "$NS" exec -i deploy/server -- python3 -c \
  "import socket,sys;print(socket.gethostbyname('$FQDN'))" 2>/dev/null || echo "no resuelve")
nota "$FQDN resuelve HOY desde un pod del origen a: $RES"
if [[ "$RES" == "$DST_IP" ]]; then
  ok "el CNAME ya apunta al destino OCP" "$RES"
  nota "se puede aplicar origen/02 verbatim y borrar 26-serviceentry-origen.yaml"
else
  skip "el CNAME todavía no se movió" "apunta a $RES — usar 26 (resolution: STATIC) hasta el corte"
fi

# ─────────────────────────────────────────────────────────────────────────────────────
esc "P5 — Encadenamiento del montaje" \
    "que las piezas no sólo existan, sino que estén ENGANCHADAS entre sí"

# Validar cada objeto por separado no alcanza: el 2026-08-05 el GatewayClass, Kuadrant y el
# JWKS estaban los tres bien y aun así la AuthPolicy no enforceaba, porque el listener no
# tenía certificado y por eso el HTTPRoute nunca fue adoptado ([H14](../HALLAZGOS.md#h14)).
# Este bloque recorre la escalera Secret -> listener -> Gateway -> HTTPRoute -> AuthPolicy.
if ! ocd -n "$NS_DST" get gateway "$GW" >/dev/null 2>&1; then
  skip "todo el escenario P5" "el Gateway $GW todavía no existe — normal antes del montaje"
else
  PROG=$(ocd -n "$NS_DST" get gateway "$GW" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  eq "Gateway Programmed" "${PROG:-null}" "True"
  if [[ "${PROG:-}" != "True" ]]; then
    nota "condiciones del listener $LISTENER:"
    nota "  $(ocd -n "$NS_DST" get gateway "$GW" -o jsonpath="{range .status.listeners[?(@.name=='$LISTENER')]}{range .conditions[*]}{.type}={.status}({.reason}) {end}{end}" 2>/dev/null)"
    nota "un InvalidCertificateRef acá es la causa raíz de todo lo que falle más arriba"
  fi

  ATT=$(ocd -n "$NS_DST" get gateway "$GW" -o jsonpath="{.status.listeners[?(@.name=='$LISTENER')].attachedRoutes}" 2>/dev/null)
  if [[ "${ATT:-0}" =~ ^[0-9]+$ ]] && (( ATT > 0 )); then
    ok "routes attacheadas al listener $LISTENER" "$ATT"
  else
    bad "routes attacheadas al listener $LISTENER" "${ATT:-0}" ">0"
  fi

  if ocd -n "$NS_DST" get httproute "$ROUTE" >/dev/null 2>&1; then
    # Si el status trae SÓLO condiciones kuadrant.io/*, el controller de Gateway API nunca
    # procesó la route. Es el chequeo que decide en un comando de qué lado está el problema.
    ACC=$(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*]}{range .conditions[?(@.type=="Accepted")]}{.status}{end}{end}' 2>/dev/null)
    RR=$(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*]}{range .conditions[?(@.type=="ResolvedRefs")]}{.status}{end}{end}' 2>/dev/null)
    [[ "$ACC" == *True* ]] && ok "HTTPRoute adoptado por el Gateway" "Accepted=True" \
                           || { bad "HTTPRoute adoptado por el Gateway" "${ACC:-sin condición Accepted}" "True"
                                nota "status completo: $(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}={.status} {end}{end}' 2>/dev/null)"
                                nota "sólo condiciones kuadrant.io/* => el problema está en el Gateway, no en la policy"; }
    [[ "$RR" == *True* ]] && ok "backendRef server2:8080 resuelve" "ResolvedRefs=True" \
                          || bad "backendRef server2:8080 resuelve" "${RR:-null}" "True"
  else
    skip "HTTPRoute $ROUTE" "todavía no aplicado"
  fi

  if ocd -n "$NS_DST" get authpolicy "$POLICY" >/dev/null 2>&1; then
    AP=$(ocd -n "$NS_DST" get authpolicy "$POLICY" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}/{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
    eq "AuthPolicy Accepted/Enforced" "${AP:-null}" "True/True"
    [[ "${AP:-}" != "True/True" ]] && nota "motivo: $(ocd -n "$NS_DST" get authpolicy "$POLICY" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  else
    skip "AuthPolicy $POLICY" "todavía no aplicada"
  fi

  if ocd -n "$NS_DST" get route app2-egress-passthrough >/dev/null 2>&1; then
    AD=$(ocd -n "$NS_DST" get route app2-egress-passthrough -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)
    eq "Route de passthrough admitida por el router" "${AD:-null}" "True"
    TERM=$(ocd -n "$NS_DST" get route app2-egress-passthrough -o jsonpath='{.spec.tls.termination}' 2>/dev/null)
    eq "terminación de la Route" "${TERM:-null}" "passthrough"
    [[ "${TERM:-}" != "passthrough" ]] && nota "con edge/reencrypt el router rutea por Host y da 503 en el 100% del tráfico"
  else
    skip "Route de passthrough" "todavía no aplicada"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────
printf '\n%s══ Resumen ══%s\n' "$B" "$Z"
printf '  %s%d PASS%s   %s%d FALLA%s   %s%d SKIP%s\n' "$V" "$PASS" "$Z" "$R" "$FALLA" "$Z" "$A" "$SKIP" "$Z"
if (( FALLA )); then printf '\n  %sFallaron:%s\n' "$R" "$Z"; for x in "${FALLIDOS[@]}"; do printf '   - %s\n' "$x"; done; fi
(( SKIP )) && nota "los SKIP no son fallos: indican qué falta montar para que ese chequeo tenga sentido"
exit $(( FALLA > 0 ))
