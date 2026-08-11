#!/usr/bin/env bash
# Batería de escenarios de la PoC de egreso, con veredicto por línea.
#
#   ./run-escenarios.sh                  # solo lectura: reporta lo que HOY es cierto
#   ./run-escenarios.sh --aplicar        # además aplica las fases del rollout y restaura al salir
#   ./run-escenarios.sh --pesos          # suma el escenario de reparto por peso (100 requests)
#   ./run-escenarios.sh --expirado       # suma la prueba (c): espera >300s a que caduque un token
#   ./run-escenarios.sh --aplicar --pesos --expirado
#
# Variables: URL, HOST, NS, NS_SIM, FQDN, y las del destino —CTX_DST, GW_DST, SVC_DST,
# DST_IP, SITE— que permiten correr la misma batería contra el destino OCP real de
# `../destino-ocp/` en vez del simulado (ver abajo).
#
# Cada escenario dice QUÉ PRUEBA antes de correr, y cada chequeo termina en PASS / FALLA /
# SKIP con el valor obtenido al lado. Al final, un resumen y exit code 0/1.
#
# Los escenarios que necesitan algo que todavía no existe se SALTEAN con el motivo, no
# fallan: correrlo con el destino simulado a medio montar es normal y tiene que dar una
# lectura útil igual.
set -uo pipefail   # sin -e: los fallos se reportan, no cortan la corrida

URL="${URL:-http://10.254.28.68}"
HOST="${HOST:-app1.paas-demo.bancogalicia.com.ar}"
NS="${NS:-echoserver}"
NS_SIM="${NS_SIM:-echoserver-eks-sim}"
FQDN="${FQDN:-app2.paas-demo.bancogalicia.com.ar}"
HOST_INTERNO="${HOST_INTERNO:-server2.echoserver.svc.cluster.local:8080}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# El destino no tiene por qué estar en este cluster: con estas cuatro variables la misma
# batería corre contra el destino OCP real de `destino-ocp/`. Con los defaults —CTX_DST y
# DST_IP vacíos— todo se resuelve contra el contexto actual, que es el comportamiento de
# siempre y el del destino simulado.
#
#   CTX_DST=paas-dev1-lowmz NS_SIM=echoserver GW_DST=ingress-gw \
#   DST_IP=10.254.34.2 SITE=dev1-lowmz ./run-escenarios.sh
CTX_DST="${CTX_DST:-}"                              # contexto de oc del cluster destino
GW_DST="${GW_DST:-ingress-sim}"                     # nombre del Gateway de ingreso del destino
SVC_DST="${SVC_DST:-${GW_DST}-openshift-default}"   # Service que autodespliega istiod
DST_IP="${DST_IP:-}"                                # si se setea, reemplaza a la ClusterIP
SITE="${SITE:-eks-sim}"                             # valor de SIM_SITE que marca al destino

APLICAR=0; PESOS=0; EXPIRADO=0
for a in "$@"; do case "$a" in
  --aplicar)  APLICAR=1 ;;
  --pesos)    PESOS=1 ;;
  --expirado) EXPIRADO=1 ;;
  -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "opción desconocida: $a"; exit 2 ;;
esac; done

if [[ -t 1 ]]; then V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; Z=$'\e[0m'
else V=; R=; A=; B=; D=; Z=; fi

PASS=0; FALLA=0; SKIP=0; FALLIDOS=()
FASE_PREVIA=""

esc()  { printf '\n%s══ %s ══%s\n%s   %s%s\n' "$B" "$1" "$Z" "$D" "$2" "$Z"; }
ok()   { printf '  %s✔ PASS%s   %-46s %s\n' "$V" "$Z" "$1" "${2-}"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘ FALLA%s  %-46s obtenido=%s  esperado=%s\n' "$R" "$Z" "$1" "${2-}" "${3-}"; FALLA=$((FALLA+1)); FALLIDOS+=("$1"); }
skip() { printf '  %s− SKIP%s    %-46s %s\n' "$A" "$Z" "$1" "${2-}"; SKIP=$((SKIP+1)); }
nota() { printf '  %s%s%s\n' "$D" "$1" "$Z"; }

eq()   { [[ "$2" == "$3" ]] && ok "$1" "$2" || bad "$1" "$2" "$3"; }
ne()   { [[ "$2" != "$3" ]] && ok "$1" "$2" || bad "$1" "$2" "distinto de $3"; }
tiene(){ [[ "$2" == *"$3"* ]] && ok "$1" "$2" || bad "$1" "$2" "que contenga $3"; }

req()  { curl -s --max-time 15 -H "Host: $HOST" "$@" "$URL/"; }
f()    { printf '%s' "${1:-}" | jq -r "${2} // \"null\"" 2>/dev/null || echo "null"; }
# Todo lo del lado destino pasa por acá, para que el mismo escenario sirva con el destino
# simulado (mismo cluster) y con el destino OCP real (otro cluster).
ocd()       { oc ${CTX_DST:+--context="$CTX_DST"} "$@"; }
existe_dst(){ ocd get "$1" "$2" ${3:+-n "$3"} >/dev/null 2>&1; }

# Petición TLS directa al destino simulado, con SNI del FQDN real y un token arbitrario.
# Va por `oc exec` al pod `server` (tiene python3) en vez de crear un pod por prueba:
# es ~10x más rápido y no depende de que la imagen de debug traiga curl.
directo_al_destino() {
  local ip="$1" tok="${2-}"
  oc -n "$NS" exec -i deploy/server -- python3 - "$ip" "$FQDN" "$HOST_INTERNO" "$tok" <<'PY' 2>/dev/null || echo "ERROR"
import http.client, socket, ssl, sys
ip, fqdn, hosthdr, tok = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ctx = ssl._create_unverified_context()
try:
    tls = ctx.wrap_socket(socket.create_connection((ip, 443), timeout=8), server_hostname=fqdn)
    c = http.client.HTTPSConnection(fqdn, 443, context=ctx, timeout=8); c.sock = tls
    h = {"Host": hosthdr}
    if tok:
        h["x-egress-token"] = tok
    c.request("GET", "/", headers=h)
    print(c.getresponse().status)
except Exception as e:
    print("ERROR:%s" % type(e).__name__)
PY
}

# Invalida la firma de un JWT de forma FIABLE.
#
# No sirve cambiar el último carácter (`${tok%?}X`): la firma RS256 son 256 bytes, y en
# base64url sin padding el último carácter aporta sólo 2 bits significativos — los otros 4
# son relleno que el decodificador descarta. El token "alterado" decodifica a los MISMOS
# bytes y el destino lo acepta con toda razón. Pasó el 2026-08-05: la prueba negativa (b)
# daba 200 y parecía un agujero de seguridad, cuando el agujero estaba en el test.
# Mutando en el medio de la firma siempre cambia un byte real.
alterar_firma() {
  local t="$1" h p s c
  h=${t%%.*}; s=${t##*.}; p=${t#*.}; p=${p%.*}
  c=${s:10:1}; if [[ "$c" == "A" ]]; then c=B; else c=A; fi
  printf '%s.%s.%s' "$h" "$p" "${s:0:10}$c${s:11}"
}

# Detecta la fase canary por el HEADER MATCH, no por `rules[].name`.
#
# Medido en paas-arqlab (2026-08-04): `spec.rules[].name` es un campo reciente de Gateway
# API y el CRD de este cluster NO lo tiene, así que el API server lo DESCARTA en silencio
# al aplicar — `oc apply` sale bien y el campo no queda. Detectar la fase por el nombre de
# la rule da siempre falso. El header match sí sobrevive.
hay_canary() {
  oc -n "$NS" get httproute egress-server2 \
    -o jsonpath='{.spec.rules[*].matches[*].headers[*].name}' 2>/dev/null | grep -qi 'x-canary'
}

# Espera a que el status del HTTPRoute refleje la generación actual del spec. Sin esto se
# leen condiciones de la fase ANTERIOR y un ResolvedRefs=True puede ser de otro backendRef.
esperar_status() {
  local g o
  for _ in $(seq 1 15); do
    g=$(oc -n "$NS" get httproute egress-server2 -o jsonpath='{.metadata.generation}' 2>/dev/null)
    o=$(oc -n "$NS" get httproute egress-server2 \
          -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].observedGeneration}' 2>/dev/null)
    [[ -n "$g" && "$g" == "$o" ]] && return 0
    sleep 2
  done
  return 1
}

restaurar() {
  [[ -n "$FASE_PREVIA" ]] || return 0
  printf '\n%s>> restaurando el HTTPRoute al estado previo%s\n' "$D" "$Z"
  oc apply -n "$NS" -f "$FASE_PREVIA" >/dev/null 2>&1 && echo "   ok: $(basename "$FASE_PREVIA")" || echo "   NO SE PUDO — revisar a mano"
}
trap restaurar EXIT

aplicar_fase() {
  local f="$1"
  if (( ! APLICAR )); then skip "aplicar $(basename "$f")" "correr con --aplicar"; return 1; fi
  if [[ -z "$FASE_PREVIA" ]]; then FASE_PREVIA="$DIR/../origen/08-rollout/fase0a-solo-local.yaml"; fi
  oc apply -n "$NS" -f "$f" >/dev/null 2>&1 || { bad "aplicar $(basename "$f")" "error" "aplicado"; return 1; }
  sleep 4
  ok "aplicado $(basename "$f")"
  return 0
}

printf '%sPoC egreso Kuadrant — batería de escenarios%s\n' "$B" "$Z"
nota "entrada: $URL  Host: $HOST     ns: $NS / $NS_SIM"
nota "destino: ${CTX_DST:-mismo cluster}  gateway: $GW_DST  marcador: SIM_SITE=$SITE${DST_IP:+  ip: $DST_IP}"
for b in oc jq curl; do command -v $b >/dev/null || { echo "falta '$b' en el PATH"; exit 2; }; done

# ─────────────────────────────────────────────────────────────────────────────────────
esc "E0 — Entorno" "que el punto de partida sea el que la PoC asume, antes de medir nada"

CONT=$(oc -n "$NS" get pod -l app=server -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null)
eq "server corre un solo contenedor" "$CONT" "bff"

SEL=$(oc -n "$NS" get svc server2 -o jsonpath='{.spec.selector.gateway\.networking\.k8s\.io/gateway-name}' 2>/dev/null)
eq "cutover activo (svc server2 -> gateway)" "${SEL:-app=server2}" "egress-gw"

CIP=$(oc -n "$NS" get svc server2 -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
nota "ClusterIP de server2: $CIP  (tiene que ser la misma de siempre: nunca se recreó el Service)"

BREF=$(oc -n "$NS" get httproute egress-server2 -o jsonpath='{.spec.rules[*].backendRefs[*].name}' 2>/dev/null)
tiene "ASSERT ANTI-LOOP: backendRef local" "$BREF" "server2-local"
[[ "$BREF" == *"server2 "* || "$BREF" == "server2" ]] && bad "backendRef NO apunta a 'server2'" "$BREF" "sin 'server2' pelado"

ENVAMB=$(oc -n "$NS" get deploy server2 -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ENABLE__ENVIRONMENT")]}{.value}{end}' 2>/dev/null)
eq "server2 expone HOSTNAME (conteo no ciego)" "$ENVAMB" "true"

GWIP=$(oc -n "$NS" get pod -l gateway.networking.k8s.io/gateway-name=egress-gw -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
POD2=$(oc -n "$NS" get pod -l app=server2 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
nota "pod del gateway de egreso: $GWIP   |   server2 local: $POD2"

# ─────────────────────────────────────────────────────────────────────────────────────
esc "E1 — Camino local por el gateway de egreso" \
    "que el tráfico atraviesa el Envoy de egreso y vuelve al server2 local, con wristband emitido"

J=$(req)
eq  "status del backend"                     "$(f "$J" '.upstream.status')" "200"
eq  "atendió el server2 local"               "$(f "$J" '.upstream.body.environment.HOSTNAME')" "$POD2"
tiene "el origen que ve el backend es el gw" "$(f "$J" '.upstream.body.host.ip')" "$GWIP"
eq  "el Host NO se reescribe"                "$(f "$J" '.upstream.body.request.headers.host')" "$HOST_INTERNO"
ne  "pasó por un Envoy de egreso"            "$(f "$J" '.upstream.body.request.headers["x-envoy-peer-metadata-id"]')" "null"

TOKEN=$(f "$J" '.upstream.body.request.headers["x-egress-token"]')
ne  "wristband inyectado"                    "$TOKEN" "null"

if [[ "$TOKEN" != "null" ]]; then
  d(){ printf '%s' "$1" | jq -R 'gsub("-";"+")|gsub("_";"/")| . + ("===="[0:(4-(length%4))%4]) | @base64d | fromjson'; }
  HDR=$(d "$(cut -d. -f1 <<<"$TOKEN")"); CLM=$(d "$(cut -d. -f2 <<<"$TOKEN")")
  eq "  alg del token"        "$(f "$HDR" '.alg')" "RS256"
  eq "  claim iss"            "$(f "$CLM" '.iss')" "https://egress.paas-arqlab.bancogalicia.com.ar"
  eq "  claim aud"            "$(f "$CLM" '.aud')" "$FQDN"
  eq "  claim src_cluster"    "$(f "$CLM" '.src_cluster')" "paas-arqlab"
  eq "  claim src_namespace"  "$(f "$CLM" '.src_namespace')" "$NS"
  eq "  claim dst_service"    "$(f "$CLM" '.dst_service')" "server2"
  eq "  vida del token (exp-iat)" "$(( $(f "$CLM" '.exp') - $(f "$CLM" '.iat') ))" "300"
  KID=$(f "$HDR" '.kid'); nota "kid del token: $KID"
  nota "OJO: 'sub' lo agrega Authorino desde la identidad anonymous — NO identifica al workload (README §8.1)"
fi
nota "latencia hop1->hop2: $(f "$J" '.upstream.latencyMs') ms"

# ─────────────────────────────────────────────────────────────────────────────────────
esc "E2 — Destino simulado" \
    "que existe un destino que VALIDA el token, y que rechaza lo que tiene que rechazar"

if ! existe_dst ns "$NS_SIM"; then
  skip "todo el escenario E2" "falta el ns $NS_SIM — ver sim-destino/README.md §4"
  SIM=0
else
  SIM=1
  PROG=$(ocd -n "$NS_SIM" get gateway "$GW_DST" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  eq "Gateway del destino Programmed" "${PROG:-null}" "True"

  AP=$(ocd -n "$NS_SIM" get authpolicy server2-ingress-jwt -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}/{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
  eq "AuthPolicy del destino Accepted/Enforced" "${AP:-null}" "True/True"

  # Con el destino en otro cluster la ClusterIP no sirve de nada desde acá: se entra por la
  # ingress VIP y el router elige la Route de passthrough por SNI (destino-ocp/22).
  SIMIP="${DST_IP:-$(ocd -n "$NS_SIM" get svc "$SVC_DST" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)}"
  KIDJ=$(ocd -n "$NS_SIM" get cm jwks-egress-origen -o jsonpath='{.data.jwks\.json}' 2>/dev/null | jq -r '.keys[0].kid' 2>/dev/null)
  eq "kid del JWKS == kid del token" "${KIDJ:-null}" "${KID:-sin-token}"

  if [[ -n "${SIMIP:-}" ]]; then
    eq "(a) sin token -> 401"            "$(directo_al_destino "$SIMIP")"                 "401"
    eq "     token válido -> 200"        "$(directo_al_destino "$SIMIP" "$TOKEN")"        "200"
    eq "(b) firma alterada -> 401"       "$(directo_al_destino "$SIMIP" "$(alterar_firma "$TOKEN")")" "401"
    eq "(b) token basura -> 401"         "$(directo_al_destino "$SIMIP" "no-es-un-jwt")"  "401"
  else
    skip "pruebas directas al destino" "no se pudo leer la ClusterIP del gateway simulado"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────
esc "E3 — Canary por header" \
    "que el tráfico marcado va al destino Y QUE EL DESTINO LO AUTORIZA, sin tocar al resto"

if (( ! SIM )); then
  skip "escenario E3" "requiere el destino simulado (E2)"
else
  hay_canary || aplicar_fase "$DIR/../origen/08-rollout/fase1-canary-header.yaml"

  esperar_status || nota "el status del HTTPRoute no convergió en 30s; lo que sigue puede ser lectura vieja"
  RR=$(oc -n "$NS" get httproute egress-server2 -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)
  eq "backendRef kind:Hostname resuelve" "${RR:-null}" "True"
  nota "(primera vez que se ejercita kind:Hostname en este cluster; False => fallback de origen/03)"

  if hay_canary; then
    C=$(req -H 'x-canary: true')
    eq "con x-canary -> destino"          "$(f "$C" '.upstream.body.environment.SIM_SITE')" "$SITE"
    eq "con x-canary -> status"           "$(f "$C" '.upstream.status')" "200"
    eq "EL DESTINO VALIDÓ EL JWT"         "$(f "$C" '.upstream.body.request.headers["x-forwarded-src-cluster"]')" "paas-arqlab"
    eq "  y propagó el namespace"         "$(f "$C" '.upstream.body.request.headers["x-forwarded-src-namespace"]')" "$NS"
    eq "  Host sigue sin reescribir"      "$(f "$C" '.upstream.body.request.headers.host')" "$HOST_INTERNO"
    if [[ -n "$CTX_DST" ]]; then
      nota "latencia al destino: $(f "$C" '.upstream.latencyMs') ms  (incluye RTT entre sitios + handshake TLS)"
    else
      nota "latencia al destino: $(f "$C" '.upstream.latencyMs') ms  (sin RTT real: el stand-in es local)"
    fi

    N=$(req)
    eq "sin el header -> sigue local"     "$(f "$N" '.upstream.body.environment.SIM_SITE')" "null"
    eq "sin el header -> status"          "$(f "$N" '.upstream.status')" "200"
  else
    skip "canary por header" "fase1 no aplicada"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────
if (( PESOS )); then
esc "E4 — Reparto por peso" "que 'weight' funciona sobre un backendRef kind:Hostname (75/25)"
  if (( ! SIM )); then skip "escenario E4" "requiere el destino simulado"
  else
    if aplicar_fase "$DIR/../origen/08-rollout/fase2-pesos.yaml"; then
      oc -n "$NS" patch httproute egress-server2 --type json -p \
        '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":75},
          {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":25}]' >/dev/null 2>&1
      sleep 4
      LOC=0; REM=0; ERR=0
      for _ in $(seq 1 100); do
        case "$(req | jq -r '.upstream.body.environment.SIM_SITE // (if .upstream.status==200 then "local" else "err" end)' 2>/dev/null)" in
          "$SITE") REM=$((REM+1)) ;; local) LOC=$((LOC+1)) ;; *) ERR=$((ERR+1)) ;;
        esac
      done
      nota "local=$LOC  destino=$REM  errores=$ERR   (esperado ~75/25)"
      eq  "sin errores en el reparto" "$ERR" "0"
      (( REM >= 10 && REM <= 45 )) && ok "proporción al destino dentro de rango" "$REM%" \
                                    || bad "proporción al destino dentro de rango" "$REM%" "entre 10 y 45"
      (( LOC > 0 )) && ok "el backend local sigue recibiendo" "$LOC%" || bad "el backend local sigue recibiendo" "0" ">0"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────
if (( EXPIRADO )); then
esc "E5 — (c) Token expirado" "que el destino mira 'exp' — sin esto el modelo de replay no vale"
  if (( ! SIM )) || [[ -z "${SIMIP:-}" ]]; then skip "escenario E5" "requiere el destino simulado"
  else
    VIEJO=$(req | jq -r '.upstream.body.request.headers["x-egress-token"]')
    eq "el token viejo hoy es válido" "$(directo_al_destino "$SIMIP" "$VIEJO")" "200"
    nota "esperando 305 s a que caduque (tokenDuration=300)..."
    sleep 305
    eq "(c) el mismo token, ya expirado -> 401" "$(directo_al_destino "$SIMIP" "$VIEJO")" "401"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────
printf '\n%s══ Resumen ══%s\n' "$B" "$Z"
printf '  %s%d PASS%s   %s%d FALLA%s   %s%d SKIP%s\n' "$V" "$PASS" "$Z" "$R" "$FALLA" "$Z" "$A" "$SKIP" "$Z"
if (( FALLA )); then printf '\n  %sFallaron:%s\n' "$R" "$Z"; for x in "${FALLIDOS[@]}"; do printf '   - %s\n' "$x"; done; fi
(( SKIP )) && nota "los SKIP no son fallos: indican qué falta montar para que ese escenario tenga sentido"
exit $(( FALLA > 0 ))
