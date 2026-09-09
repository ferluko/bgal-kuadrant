#!/usr/bin/env bash
# preflight-camino.sh — valida el CAMINO paas-lab -> paas-arqlab: DNS/CNAMEs, ruteo del
# router, TLS, skew de reloj y el encadenamiento del montaje del destino. SOLO LECTURA.
#
# Complementa a scripts/preflight-paas-lab.sh (que valida la federación con Vault).
# Adaptado de poc-egress-kuadrant/destino-ocp/preflight.sh, ya probado en campo para el
# caso arqlab -> paas-dev1-lowmz. Cambios: destino arqlab, emisor Vault en vez de wristband,
# y una sección de DNS más completa porque acá el CNAME todavía no existe.
#
#   CTX_ORI=paas-lab CTX_DST=paas-arqlab ./preflight-camino.sh
#   DST_IP=10.254.x.y ./preflight-camino.sh     # si el CNAME aún no resuelve
#
# Requiere oc y jq en el bastión. No necesita salida a internet: las sondas de red salen
# desde un pod del ORIGEN (oc exec a deploy/bff, que tiene python3).
set -uo pipefail

CTX_ORI="${CTX_ORI:-}"
CTX_DST="${CTX_DST:-}"
FQDN="${FQDN:-app3.paas-demo.bancogalicia.com.ar}"       # el FQDN NUEVO para arqlab
FQDN_EKS="${FQDN_EKS:-app2.paas-demo.bancogalicia.com.ar}" # el que ya existe (destino EKS)
DST_IP="${DST_IP:-}"                                      # vacío => se descubre por DNS/router
NS="${NS:-poc-egress-kuadrant}"                           # ns en el origen
NS_DST="${NS_DST:-poc-ingress-kuadrant}"                  # ns en el destino
HOST_INTERNO="${HOST_INTERNO:-backend.poc-egress-kuadrant.svc.cluster.local:8080}"
# Rediseño 2026-09-09: se reusa gw-hostnet (su 443 funciona), no hay Gateway propio ni Route.
NS_GW="${NS_GW:-poc-ingress-kuadrant}"
GW="${GW:-ingress-gw-lab}"
LISTENER="${LISTENER:-https}"
CERT_SECRET="${CERT_SECRET:-shard1-paas-demo}"
SNI_CERT="${SNI_CERT:-shard1.paas-demo.bancogalicia.com.ar}"  # el nombre que el cert SÍ cubre
ROUTE="${ROUTE:-backend-lab}"
POLICY="${POLICY:-backend-lab-vault-spiffe}"
POLICY_ORI="${POLICY_ORI:-egress-backend-vault-spiffe}"
SUB_ESPERADO="${SUB_ESPERADO:-spiffe://poc-egress.bancogalicia.com.ar/paas-lab/egress-gw}"

if [[ -t 1 ]]; then V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; Z=$'\e[0m'
else V=; R=; A=; B=; D=; Z=; fi
PASS=0; FALLA=0; SKIP=0; FALLIDOS=()
esc()  { printf '\n%s══ %s ══%s\n%s   %s%s\n' "$B" "$1" "$Z" "$D" "$2" "$Z"; }
ok()   { printf '  %s✔ PASS%s   %-48s %s\n' "$V" "$Z" "$1" "${2-}"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘ FALLA%s  %-48s obtenido=%s  esperado=%s\n' "$R" "$Z" "$1" "${2-}" "${3-}"; FALLA=$((FALLA+1)); FALLIDOS+=("$1"); }
skip() { printf '  %s− SKIP%s    %-48s %s\n' "$A" "$Z" "$1" "${2-}"; SKIP=$((SKIP+1)); }
nota() { printf '  %s%s%s\n' "$D" "$1" "$Z"; }
eq()   { [[ "$2" == "$3" ]] && ok "$1" "$2" || bad "$1" "$2" "$3"; }
oco()  { oc ${CTX_ORI:+--context="$CTX_ORI"} "$@"; }
ocd()  { oc ${CTX_DST:+--context="$CTX_DST"} "$@"; }
j()    { printf '%s' "${1:-}" | jq -r "${2} // \"null\"" 2>/dev/null || echo null; }

for b in oc jq; do command -v $b >/dev/null || { echo "falta '$b' en el PATH"; exit 2; }; done
printf '%sPoC on-prem — preflight del camino paas-lab -> paas-arqlab%s\n' "$B" "$Z"

# Los dos contextos son OBLIGATORIOS. Si se dejan vacíos, oco() y ocd() corren los dos
# contra el contexto actual y el preflight mide un solo cluster creyendo que mide dos:
# los chequeos del destino salen "PASS" con datos del origen. Autodetectar y verificar
# que los API server sean REALMENTE distintos.
ALL_CTX=$(oc config get-contexts -o name 2>/dev/null)
pick() { printf '%s\n' "$ALL_CTX" | grep -i -- "$1" | grep -vi -- "${2:-@@nada@@}" | head -1; }
[[ -z "$CTX_ORI" ]] && CTX_ORI=$(pick 'paas-lab')
[[ -z "$CTX_DST" ]] && CTX_DST=$(pick 'arqlab')
[[ -z "$CTX_ORI" ]] && { echo "no encontré contexto de origen: pasá CTX_ORI=<nombre>"; exit 2; }
[[ -z "$CTX_DST" ]] && { echo "no encontré contexto de destino: pasá CTX_DST=<nombre>"; exit 2; }
SRV_O=$(oco whoami --show-server 2>/dev/null)
SRV_D=$(ocd whoami --show-server 2>/dev/null)
[[ -z "$SRV_O" ]] && { echo "el contexto de origen '$CTX_ORI' no responde"; exit 2; }
[[ -z "$SRV_D" ]] && { echo "el contexto de destino '$CTX_DST' no responde"; exit 2; }
if [[ "$SRV_O" == "$SRV_D" ]]; then
  echo "ORIGEN Y DESTINO APUNTAN AL MISMO API SERVER ($SRV_O)."
  echo "Los chequeos del destino serían del origen disfrazados. Corregí los contextos."
  exit 2
fi
nota "origen : $CTX_ORI  -> $SRV_O"
nota "destino: $CTX_DST  -> $SRV_D"
nota "FQDN de la prueba: $FQDN"

# Resolución DNS desde un pod del ORIGEN (es la que importa: la del bastión puede diferir).
resolver() {
  oco -n "$NS" exec -i deploy/bff -- python3 -c \
    "import socket;print(socket.gethostbyname('$1'))" 2>/dev/null || echo "no-resuelve"
}

# Sonda TCP+TLS+HTTP+skew desde un pod del origen, todo en una pasada.
sonda() {
  local ip="$1"; local sni="${2:-$FQDN}"
  oco -n "$NS" exec -i deploy/bff -- python3 - "$ip" "$sni" "$HOST_INTERNO" <<'PY' 2>/dev/null || echo '{"error":"no se pudo ejecutar en deploy/bff"}'
import http.client, json, re, socket, ssl, sys, time
from email.utils import parsedate_to_datetime
ip, fqdn, hosthdr = sys.argv[1], sys.argv[2], sys.argv[3]
out = {}
try:
    t0 = time.time(); s = socket.create_connection((ip, 443), timeout=8)
    out["tcp_ms"] = round((time.time() - t0) * 1000)
except Exception as e:
    print(json.dumps({"error": "tcp:%s" % type(e).__name__})); raise SystemExit
ctx = ssl._create_unverified_context()
try:
    t0 = time.time(); tls = ctx.wrap_socket(s, server_hostname=fqdn)
    out["tls_ms"] = round((time.time() - t0) * 1000)
    der = tls.getpeercert(True) or b""
    out["cert"] = sorted({n.decode() for n in re.findall(rb'[A-Za-z0-9*.\-]{6,}\.[a-z]{2,}', der)})[:6]
except Exception as e:
    out["error"] = "tls:%s" % type(e).__name__; print(json.dumps(out)); raise SystemExit
try:
    c = http.client.HTTPSConnection(fqdn, 443, context=ctx, timeout=8); c.sock = tls
    t0 = time.time(); c.request("GET", "/", headers={"Host": hosthdr})
    r = c.getresponse(); out["http"] = r.status
    out["http_ms"] = round((time.time() - t0) * 1000)
    d = r.getheader("Date")
    if d: out["skew_s"] = round(parsedate_to_datetime(d).timestamp() - time.time())
except Exception as e:
    out["error"] = "http:%s" % type(e).__name__
print(json.dumps(out))
PY
}

# ─────────────────────────────────────────────────────────────────────────────
esc "C1 — DNS y CNAMEs" \
    "a dónde apunta cada FQDN HOY, resuelto desde un pod del origen (no desde el bastión)"

RES_NEW=$(resolver "$FQDN")
RES_EKS=$(resolver "$FQDN_EKS")
nota "$FQDN      -> $RES_NEW"
nota "$FQDN_EKS  -> $RES_EKS   (destino EKS, el que ya usa arqlab como origen)"

if [[ "$RES_NEW" == "no-resuelve" ]]; then
  skip "CNAME de $FQDN" "todavía no existe"
  nota "ES LO ESPERADO hoy. Hay dos caminos:"
  nota "  a) pedir a redes/Infoblox el A/CNAME de $FQDN -> VIP del router de arqlab"
  nota "  b) destrabar ya con ServiceEntry resolution: STATIC apuntando a esa VIP"
  nota "     (ver origen-paas-lab/03-serviceentry-destino.yaml, bloque comentado al final)"
else
  ok "CNAME de $FQDN resuelve" "$RES_NEW"
fi

# Que resuelva NO significa que resuelva al destino correcto. Un FQDN ya tomado apuntando
# a otro lado es el peor caso: parece configurado y manda el tráfico a un cluster ajeno.
if [[ "$RES_NEW" != "no-resuelve" ]]; then
  PREF_NEW="${RES_NEW%.*.*}"; PREF_EKS="${RES_EKS%.*.*}"
  if [[ "$RES_EKS" != "no-resuelve" && "$PREF_NEW" == "$PREF_EKS" ]]; then
    bad "$FQDN apunta a on-prem" "$RES_NEW (misma /16 que el destino EKS: $PREF_EKS.x.x)" "un rango on-prem"
    nota "ESE NOMBRE YA ESTÁ TOMADO Y APUNTA A LA NUBE. No lo reutilices ni lo repuntes sin"
    nota "averiguar quién lo usa: elegí un FQDN libre y creá el registro on-prem apuntando"
    nota "a la VIP de ingress del destino (la que descubre el bloque de abajo)."
  fi
fi

if [[ "$RES_NEW" != "no-resuelve" && "$RES_NEW" == "$RES_EKS" ]]; then
  bad "los dos FQDN apuntan a IPs distintas" "ambos a $RES_NEW" "IPs distintas"
  nota "si $FQDN resuelve al MISMO destino que $FQDN_EKS, no estás probando arqlab: estás"
  nota "yendo a EKS con otro nombre. Es un falso positivo silencioso."
fi

# VIP real del router de arqlab, para comparar y para el modo STATIC.
VIP=$(ocd -n openshift-ingress get svc router-default \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
[[ -z "$VIP" ]] && VIP=$(ocd -n openshift-ingress get svc router-default \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
DOM=$(ocd get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
# El dominio de apps es la forma más barata de detectar que ocd está pegándole al cluster
# equivocado: tiene que decir arqlab, no lab.
nota "dominio de apps del destino: ${DOM:-?}"
case "${DOM:-}" in
  *arqlab*) ok "el contexto de destino ES arqlab" "$DOM" ;;
  "")       skip "dominio de apps del destino" "sin permisos sobre ingresses.config" ;;
  *)        bad "el contexto de destino ES arqlab" "$DOM" "apps.paas-arqlab..." ;;
esac
# Fallback: si el router no expone VIP, sirven las IPs de los nodos (el ingress hostNetwork
# y el router escuchan ahí).
if [[ -z "$VIP" ]]; then
  VIP=$(ocd get nodes -l node-role.kubernetes.io/infra= \
          -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  [[ -z "$VIP" ]] && VIP=$(ocd get nodes \
          -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  [[ -n "$VIP" ]] && nota "router sin VIP publicada; uso IP de nodo del destino como referencia"
fi
if [[ -n "$VIP" ]]; then
  ok "IP de referencia del destino" "$VIP"
  nota "es a ESTA red a la que tiene que apuntar el registro DNS que crees on-prem"
  if [[ "$RES_NEW" != "no-resuelve" && "${RES_NEW%.*.*}" != "${VIP%.*.*}" ]]; then
    bad "$FQDN apunta a la red del destino" "$RES_NEW" "algo en ${VIP%.*.*}.x.x"
  fi
else
  skip "IP de referencia del destino" "sin permisos para leerla"
fi

TARGET="${DST_IP:-}"
[[ -z "$TARGET" && "$RES_NEW" != "no-resuelve" ]] && TARGET="$RES_NEW"
[[ -z "$TARGET" ]] && TARGET="$VIP"

# ─────────────────────────────────────────────────────────────────────────────
esc "C2 — Conectividad L3 y TLS entre clusters" \
    "el gate que hace inviable todo lo demás: paas-lab -> router de arqlab, TCP 443"

if [[ -z "$TARGET" ]]; then
  skip "toda la sonda de red" "no hay IP destino (ni DNS, ni DST_IP, ni VIP del router)"
else
  nota "sondeando $TARGET:443 con SNI=$FQDN desde deploy/bff en el origen"
  S=$(sonda "$TARGET"); ERR=$(j "$S" '.error')
  case "$ERR" in
    tcp:*)
      bad "TCP 443 hacia $TARGET" "$ERR" "conexión establecida"
      nota "NO abrió el socket: esto sí es camino L3/firewall, y es un pedido a redes."
      ;;
    tls:*)
      bad "handshake TLS hacia $TARGET" "$ERR" "handshake completo"
      nota "OJO: el TCP SÍ conectó — el camino de red EXISTE. Falla el TLS."
      nota "Un reset en el handshake es el síntoma que describe el runbook §7.1: sin filter"
      nota "chain que matchee el SNI, Envoy resetea (errno=104). Ver la matriz de C2bis:"
      nota "compara VIP vs nodo y SNI logico vs SNI del certificado para aislar cuál de los dos."
      ;;
    null) ;;
    *) bad "sonda hacia $TARGET" "$ERR" "sin error" ;;
  esac
  if [[ "$ERR" == "null" ]]; then
    ok "TCP 443 hacia $TARGET" "$(j "$S" '.tcp_ms') ms"
    ok "handshake TLS" "$(j "$S" '.tls_ms') ms"
    nota "este RTT se le suma a CADA request y no se ve en pruebas locales"

    CERT=$(j "$S" '.cert|join(", ")')
    if [[ "$CERT" == *"paas-demo"* ]]; then
      ok "el SNI eligió el Gateway del destino" "$CERT"
    elif [[ "$CERT" == "null" ]]; then
      skip "certificado que presenta el destino" "no se pudo leer"
    else
      bad "el SNI eligió el Gateway del destino" "$CERT" "un cert con paas-demo"
      nota "no presenta un cert de paas-demo: el SNI no matcheó el filter chain esperado."
      nota "Contrastar con la matriz de C2bis y con el SAN real del cert (C3)."
    fi

    ST=$(j "$S" '.http')
    case "$ST" in
      401|403) ok "GET sin token -> rechazo" "$ST"; nota "el destino enforcea: prueba negativa OK" ;;
      200) bad "GET sin token -> rechazo" "$ST" "401 o 403"
           nota "EL DESTINO CONTESTA SIN EXIGIR TOKEN. Coincide con el bloqueante conocido: las"
           nota "AuthPolicy sobre gw-hostnet no estan Enforced. Ver 14-diagnostico-claims.md." ;;
      503) skip "GET sin token" "503 del router — Route sin endpoints o Gateway sin montar" ;;
      404) skip "GET sin token" "404 — el Host no matchea ningún HTTPRoute (revisar 10-httproute-backend.yaml)" ;;
      *)   skip "GET sin token" "status=$ST" ;;
    esac

    SK=$(j "$S" '.skew_s')
    if [[ "$SK" == "null" ]]; then skip "skew de reloj entre clusters" "sin header Date"
    elif (( ${SK#-} <= 30 )); then ok "skew de reloj entre clusters" "${SK}s"
    else bad "skew de reloj entre clusters" "${SK}s" "|skew| <= 30s"
         nota "el JWT-SVID dura 300s: un skew grande hace que el destino rechace TODOS los"
         nota "tokens con un 401 indistinguible del de una firma inválida. Revisar chrony."
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
esc "C2bis — Matriz de aislamiento del TLS" \
    "dos variables, cuatro combinaciones: ¿es el F5 o es el SNI?"

# El FQDN resuelve a una VIP del F5 (otra subred que los nodos). gw-hostnet es hostNetwork:
# escucha en la IP de los NODOS. Si el handshake anda contra el nodo pero no contra la VIP,
# el problema es la config del F5 y no Envoy. Y si anda con el SNI del certificado pero no
# con el logico, es matching de SNI en Envoy — que ademas responde qué poner en el
# DestinationRule (origen-paas-lab/04).
# gw-hostnet es hostNetwork: escucha en las IPs de SUS nodos, que no son cualquier nodo.
# Tomar .items[0] de todos los nodos es un error: ahí contesta el router default (se delata
# por el certificado *.apps.…) y uno concluye "el nodo anda" sin haber tocado el gateway.
NODO=$(ocd -n "$NS_GW" get pods -l "gateway.networking.k8s.io/gateway-name=$GW" \
        -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null)
if [[ -n "$NODO" ]]; then
  nota "nodos donde corre $GW (hostNetwork):"
  ocd -n "$NS_GW" get pods -l "gateway.networking.k8s.io/gateway-name=$GW" \
    -o custom-columns='POD:.metadata.name,NODO:.spec.nodeName,HOSTIP:.status.hostIP,ESTADO:.status.phase' \
    --no-headers 2>/dev/null | sed 's/^/        /'
else
  nota "no pude ubicar los pods de $GW; uso un nodo cualquiera (probablemente NO sea el gateway)"
  NODO=$(ocd get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
fi
printf '  %-26s %-42s %s\n' "DESTINO" "SNI" "RESULTADO"
for tgt_lbl in "VIP:$TARGET" "NODO:${NODO:-}"; do
  tgt_ip="${tgt_lbl#*:}"; [[ -z "$tgt_ip" ]] && continue
  for sni in "$FQDN" "$SNI_CERT"; do
    S2=$(sonda "$tgt_ip" "$sni"); E2=$(j "$S2" '.error')
    if [[ "$E2" == "null" ]]; then
      # armado en pasos a proposito: meter jq con comillas dobles dentro de una cadena
      # entre comillas dobles rompe el parseo del shell.
      T2=$(j "$S2" '.tls_ms'); H2=$(j "$S2" '.http')
      C2=$(printf '%s' "$S2" | jq -r '.cert // [] | join(",")' 2>/dev/null)
      RES="tls_ok ${T2}ms  http=${H2}  cert=${C2}"
    else
      RES="$E2"
    fi
    printf '  %-26s %-42s %s\n' "${tgt_lbl%%:*} $tgt_ip" "$sni" "$RES"
  done
done
nota "Lectura — MIRAR PRIMERO EL CERTIFICADO, dice QUIÉN atendió:"
nota "  cert con CN shard1.paas-demo…     -> llegaste al gw-hostnet. Recién ahí el resto vale."
nota "  cert con *.apps.paas-arqlab…      -> te atendió el ROUTER DEFAULT, no el gateway."
nota "                                       Un 'tls_ok' contra el router NO prueba nada del"
nota "                                       gateway; el 503 que sigue es del router."
nota "Después:"
nota "  todo resetea, con cualquier SNI   -> el listener NO TIENE CERTIFICADO. Es el caso ya"
nota "                                       medido en gw-hostnet (secret en warming). Verificar"
nota "                                       con dynamic_active_secrets ANTES de culpar al F5."
nota "  NODO(gw) ok + VIP falla           -> ahí sí, el F5/VIP no publica el 443"
nota "  SNI del cert ok + logico falla    -> matching de SNI en Envoy; usar ese SNI en 04"
nota "  los cuatro fallan                 -> listener https del Gateway (C5) y el cert"

# ─────────────────────────────────────────────────────────────────────────────
esc "C3 — Plataforma en arqlab" "que exista lo que los manifiestos 10-13 dan por sentado"

GC=$(ocd get gatewayclass openshift-default -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
eq "GatewayClass openshift-default Accepted" "${GC:-ausente}" "True"
KU=$(ocd -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
eq "Kuadrant/RHCL Ready" "${KU:-ausente}" "True"
ECS=$(ocd -n kuadrant-system get authorino -o jsonpath='{.items[0].spec.evaluatorCacheSize}' 2>/dev/null)
[[ "${ECS:-0}" -ge 10 ]] 2>/dev/null && ok "evaluatorCacheSize en el destino" "$ECS" \
                                     || skip "evaluatorCacheSize en el destino" "${ECS:-unset} (solo importa si arqlab también mintea)"

# El certificado del listener vive en el ns del GATEWAY (connlink-ingress), no en el de la PoC.
if ocd -n "$NS_GW" get secret "$CERT_SECRET" >/dev/null 2>&1; then
  T=$(ocd -n "$NS_GW" get secret "$CERT_SECRET" -o jsonpath='{.type}')
  eq "Secret $CERT_SECRET es kubernetes.io/tls" "$T" "kubernetes.io/tls"
  CRT=$(ocd -n "$NS_GW" get secret "$CERT_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null)
  N=$(printf '%s' "$CRT" | grep -c 'BEGIN CERTIFICATE')
  if (( N > 1 )); then ok "tls.crt trae la cadena" "$N certificados"
  else bad "tls.crt trae la cadena" "$N certificado" ">1 (hoja + intermedias)"
       nota "con solo la hoja el origen no arma la cadena y el handshake falla sin decir por qué"; fi
  # LO QUE DECIDE EL SNI: qué nombres cubre realmente.
  if command -v openssl >/dev/null; then
    SAN=$(printf '%s' "$CRT" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | tail -1)
    SUBJ=$(printf '%s' "$CRT" | openssl x509 -noout -subject 2>/dev/null)
    nota "subject: ${SUBJ:-?}"
    nota "SAN    : ${SAN:-<sin SAN>}"
    if [[ "$SAN" == *"*.paas-demo"* ]]; then
      ok "el cert cubre el wildcard *.paas-demo" "usar sni: $FQDN en origen-paas-lab/04"
    elif [[ "$SAN" == *"${FQDN%%.*}."* ]]; then
      ok "el cert cubre $FQDN" "usar sni: $FQDN"
    else
      bad "el cert cubre $FQDN" "${SAN:-sin SAN}" "un SAN que incluya $FQDN"
      nota "por eso el handshake con SNI=$FQDN puede resetear. Opciones: usar sni: $SNI_CERT"
      nota "en origen-paas-lab/04, o reemitir el cert agregando $FQDN a los SAN."
    fi
  else
    skip "SAN del certificado" "no hay openssl en el bastión — correr el comando a mano"
  fi
else
  skip "Secret $CERT_SECRET en $NS_GW" "no encontrado"
fi

CH=$(ocd auth can-i create routes/custom-host -n "$NS_DST" 2>/dev/null)
eq "permiso para Route con host propio" "${CH:-no}" "yes"
[[ "${CH:-no}" != "yes" ]] && nota "sin routes/custom-host no se puede publicar $FQDN en arqlab"

# ─────────────────────────────────────────────────────────────────────────────
esc "C4 — El origen puede emitir tokens" \
    "sin esto el destino no se puede validar de punta a punta"

AP=$(oco -n "$NS" get authpolicy "$POLICY_ORI" \
      -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}/{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
if [[ -z "$AP" || "$AP" == "/" ]]; then
  bad "AuthPolicy de egreso en paas-lab" "ausente" "Accepted/Enforced True/True"
  nota "es el bloqueante #2: aplicar origen-paas-lab/02-authpolicy-origen.yaml"
else
  eq "AuthPolicy de egreso Accepted/Enforced" "$AP" "True/True"
fi
ECSO=$(oco -n kuadrant-system get authorino -o jsonpath='{.items[0].spec.evaluatorCacheSize}' 2>/dev/null)
if [[ "${ECSO:-0}" -ge 10 ]] 2>/dev/null; then ok "evaluatorCacheSize en paas-lab" "$ECSO"
else bad "evaluatorCacheSize en paas-lab" "${ECSO:-unset}" ">=10"
     nota "bloqueante #1: con el mint en 485ms y el ext_authz en 200ms, sin cache falla casi todo"
     nota "aplicar origen-paas-lab/01-authorino-cache-size.yaml"; fi

# ─────────────────────────────────────────────────────────────────────────────
esc "C5 — Encadenamiento del montaje en arqlab" \
    "que las piezas no solo existan, sino que estén ENGANCHADAS entre sí"

# Rediseño 2026-09-09: el destino reusa gw-hostnet (ns connlink-ingress). No hay Gateway propio
# ni Route de OpenShift. Antes esta sección buscaba `ingress-gw-lab` y salteaba TODO en silencio.
if ! ocd -n "$NS_GW" get gateway "$GW" >/dev/null 2>&1; then
  bad "Gateway $GW en $NS_GW" "no existe" "presente"
else
  PROG=$(ocd -n "$NS_GW" get gateway "$GW" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  eq "Gateway $GW Programmed" "${PROG:-null}" "True"
  LC=$(ocd -n "$NS_GW" get gateway "$GW" -o jsonpath="{range .status.listeners[?(@.name=='$LISTENER')]}{range .conditions[*]}{.type}={.status} {end}{end}" 2>/dev/null)
  nota "listener $LISTENER: ${LC:-sin datos}"
  case "$LC" in
    *"ResolvedRefs=True"*) ok "el listener $LISTENER resolvió su certificado" "ResolvedRefs=True" ;;
    "") skip "condiciones del listener $LISTENER" "no encontrado" ;;
    *) bad "el listener $LISTENER resolvió su certificado" "$LC" "ResolvedRefs=True"
       nota "un InvalidCertificateRef acá es la causa raíz de todo lo que falle más arriba" ;;
  esac
  ATT=$(ocd -n "$NS_GW" get gateway "$GW" -o jsonpath="{.status.listeners[?(@.name=='$LISTENER')].attachedRoutes}" 2>/dev/null)
  if [[ "${ATT:-0}" =~ ^[0-9]+$ ]] && (( ATT > 0 )); then ok "routes attacheadas al listener $LISTENER" "$ATT"
  else bad "routes attacheadas al listener $LISTENER" "${ATT:-0}" ">0"; fi
fi

if ocd -n "$NS_DST" get httproute "$ROUTE" >/dev/null 2>&1; then
  ACC=$(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*]}{range .conditions[?(@.type=="Accepted")]}{.status}{end}{end}' 2>/dev/null)
  RR=$(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*]}{range .conditions[?(@.type=="ResolvedRefs")]}{.status}{end}{end}' 2>/dev/null)
  [[ "$ACC" == *True* ]] && ok "HTTPRoute $ROUTE adoptada por el Gateway" "Accepted=True" \
    || { bad "HTTPRoute $ROUTE adoptada por el Gateway" "${ACC:-sin condición}" "True"
         nota "solo condiciones kuadrant.io/* => el problema está en el Gateway, no en la policy"; }
  [[ "$RR" == *True* ]] && ok "backendRef de $ROUTE resuelve" "ResolvedRefs=True" \
    || bad "backendRef de $ROUTE resuelve" "${RR:-null}" "True"
  HN=$(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{.spec.hostnames[*]}' 2>/dev/null)
  nota "hostname que matchea: $HN"
  nota "el origen manda ese FQDN CON ':8080' (el egreso no reescribe el Host). Gateway API"
  nota "matchea sin puerto; si ves 404 del gateway (no del F5), es el primer lugar donde mirar."
else
  bad "HTTPRoute $ROUTE en $NS_DST" "ausente" "presente"
fi

if ocd -n "$NS_DST" get authpolicy "$POLICY" >/dev/null 2>&1; then
  A2=$(ocd -n "$NS_DST" get authpolicy "$POLICY" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}/{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
  eq "AuthPolicy $POLICY Accepted/Enforced" "${A2:-null}" "True/True"
  [[ "${A2:-}" != "True/True" ]] && nota "motivo: $(ocd -n "$NS_DST" get authpolicy "$POLICY" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  PR=$(ocd -n "$NS_DST" get authpolicy "$POLICY" -o json 2>/dev/null \
        | jq -r '[.spec.rules.authorization[]?.patternMatching.patterns[]?.predicate] | map(select(.!=null)) | length' 2>/dev/null)
  if [[ "${PR:-0}" -gt 0 ]] 2>/dev/null; then
    ok "los predicate sobrevivieron al apply" "$PR patrones"
    ocd -n "$NS_DST" get authpolicy "$POLICY" -o json 2>/dev/null \
      | jq -r '.spec.rules.authorization[]?.patternMatching.patterns[]?.predicate' 2>/dev/null \
      | sed 's/^/        /'
    ocd -n "$NS_DST" get authpolicy "$POLICY" -o json 2>/dev/null | grep -q "$SUB_ESPERADO" \
      && ok "el sub de paas-lab está en los claims-esperados" "$SUB_ESPERADO" \
      || bad "el sub de paas-lab está en los claims-esperados" "ausente" "$SUB_ESPERADO"
  else
    bad "los predicate sobrevivieron al apply" "0 con predicate" ">0"
  fi
else
  bad "AuthPolicy $POLICY en $NS_DST" "ausente" "presente"
fi

# Todas las AuthPolicy que compiten por el mismo gateway: si dos apuntan al mismo targetRef,
# Kuadrant marca una como overridden y podés estar mirando el status de la que NO se aplica.
nota "AuthPolicy en $NS_DST:"
APALL=$(ocd -n "$NS_DST" get authpolicy -o custom-columns='NOMBRE:.metadata.name,TARGET:.spec.targetRef.name,ACC:.status.conditions[?(@.type=="Accepted")].status,ENF:.status.conditions[?(@.type=="Enforced")].status' --no-headers 2>/dev/null)
printf '%s\n' "$APALL" | sed 's/^/        /'
NTOT=$(printf '%s\n' "$APALL" | grep -c . )
NENF=$(printf '%s\n' "$APALL" | awk 'NF && $NF=="True"' | grep -c . )
if [[ "${NTOT:-0}" -gt 0 && "${NENF:-0}" -eq 0 ]]; then
  bad "alguna AuthPolicy del namespace enforcea" "0 de $NTOT" ">=1"
  nota "NINGUNA está Enforced. No es un detalle: sobre ese gateway NO se aplica autorización"
  nota "a nada, y por eso pasa cualquier token. Es la explicación del hallazgo de claims."
  nota "Un Enforced=False que PERSISTE no es transitorio — ver 14-diagnostico-claims.md."
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s══ Resumen ══%s\n' "$B" "$Z"
printf '  %s%d PASS%s   %s%d FALLA%s   %s%d SKIP%s\n' "$V" "$PASS" "$Z" "$R" "$FALLA" "$Z" "$A" "$SKIP" "$Z"
if (( FALLA )); then printf '\n  %sFallaron:%s\n' "$R" "$Z"; for x in "${FALLIDOS[@]}"; do printf '   - %s\n' "$x"; done; fi
(( SKIP )) && nota "los SKIP no son fallos: indican qué falta montar para que ese chequeo tenga sentido"
exit $(( FALLA > 0 ))
