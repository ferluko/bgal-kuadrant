#!/usr/bin/env bash
# preflight-paas-lab.sh — verificación READ-ONLY de paas-lab como TERCER cluster de la PoC
# Kuadrant/Vault-SPIFFE, más el cross-check contra el cluster destino elegido.
#
# ─────────────────────────────────────────────────────────────────────────────
# MODELO DE EJECUCIÓN — el bastión NO necesita llegar a Vault
# ─────────────────────────────────────────────────────────────────────────────
#
#   darqtesting01 ──oc/https──► API server de paas-lab ──► pod efímero ──https──► Vault HCP
#   (sin salida a internet)      (sí alcanzable)           (red del cluster)      :8200
#
# El OCP es el proxy: `oc run -i` abre stdin/stdout contra un pod que corre DENTRO del
# cluster, y ese pod sí tiene la ruta a Vault (misma que usa el CronJob de login, que ya
# funciona). El bastión solo necesita hablarle a los API servers. No hace falta ni salida a
# internet ni port-forward ni copiar el script a ningún lado.
#
# Si `oc run` está vedado por política, ver PROBE_MODE=manual más abajo: imprime el bloque
# exacto para pegar dentro de un pod que ya exista.
#
# ─────────────────────────────────────────────────────────────────────────────
# USO — desde darqtesting01, con los dos contextos ya cargados en el kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
#
#   ./preflight-paas-lab.sh                        # autodetecta contextos por substring
#   CTX_LAB=paas-lab CTX_DST=paas-arqlab ./preflight-paas-lab.sh
#   DESTINO=eks ./preflight-paas-lab.sh            # cross-check contra EKS en vez de arqlab
#   SKIP_VAULT=1 ./preflight-paas-lab.sh           # sin crear el pod efímero
#   PROBE_MODE=manual ./preflight-paas-lab.sh      # imprime los curl para pegar a mano
#
# NO aplica, NO parchea, NO borra. Única escritura: un pod efímero (--rm) y un mint de
# JWT-SVID (que no cambia estado en Vault). Se puede correr con tráfico andando.
#
# Dependencias en el bastión: oc. (jq es opcional — si no está, degrada con grep/sed.)
#
set -uo pipefail

# ─── parámetros ───────────────────────────────────────────────────────────────
CTX_LAB="${CTX_LAB:-}"                             # vacío ⇒ autodetectar por 'paas-lab'
CTX_DST="${CTX_DST:-}"                             # vacío ⇒ autodetectar según $DESTINO
DESTINO="${DESTINO:-arqlab}"                       # arqlab | eks | none
NS_KUADRANT="${NS_KUADRANT:-kuadrant-system}"
NS_POC="${NS_POC:-poc-egress-kuadrant}"
NS_POC_DST="${NS_POC_DST:-$NS_POC}"
SA_AUTHORINO="${SA_AUTHORINO:-authorino-authorino}"
VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200}"
VAULT_NS="${VAULT_NS:-admin/spiffe}"
SPIFFE_MOUNT="${SPIFFE_MOUNT:-spiffe}"
SPIFFE_ROLE="${SPIFFE_ROLE:-egress-gw-paas-lab}"
AUD_PROBE="${AUD_PROBE:-preflight.paas-lab.probe}"
IMG_PROBE="${IMG_PROBE:-}"                         # vacío ⇒ heredar la del CronJob (air-gap safe)
PROBE_MODE="${PROBE_MODE:-run}"                    # run | manual
CACHE_SIZE_MIN="${CACHE_SIZE_MIN:-10}"
MINT_BUDGET_MS="${MINT_BUDGET_MS:-200}"            # timeout fijo del ext_authz de Kuadrant

# ─── plumbing ─────────────────────────────────────────────────────────────────
P=0; W=0; F=0
# prefijo C_ a propósito: $Y/$G/$R son nombres demasiado fáciles de pisar más abajo
if [ -t 1 ]; then C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_Z=$'\033[0m'
else C_G=""; C_Y=""; C_R=""; C_B=""; C_Z=""; fi
sec()  { printf '\n%s══ %s %s\n' "$C_B" "$*" "$C_Z"; }
ok()   { P=$((P+1)); printf '  %sPASS%s  %s\n' "$C_G" "$C_Z" "$*"; }
warn() { W=$((W+1)); printf '  %sWARN%s  %s\n' "$C_Y" "$C_Z" "$*"; }
bad()  { F=$((F+1)); printf '  %sFAIL%s  %s\n' "$C_R" "$C_Z" "$*"; }
info() { printf '        %s\n' "$*"; }

command -v oc >/dev/null || { echo "falta oc en el PATH"; exit 1; }
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1
# extrae "campo":"valor" de un JSON chato, sin jq
pluck() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"//; s/"$//'; }

# oc contra un contexto puntual; silencia stderr para que los "not found" no ensucien
L() { oc --context="$CTX_LAB" "$@" 2>/dev/null; }
D() { oc --context="$CTX_DST" "$@" 2>/dev/null; }

# ─── §0 contextos ─────────────────────────────────────────────────────────────
sec "0. Contextos en el kubeconfig del bastión"
ALL_CTX=$(oc config get-contexts -o name 2>/dev/null)
[ -z "$ALL_CTX" ] && { bad "el kubeconfig no tiene contextos"; exit 1; }
printf '%s\n' "$ALL_CTX" | sed 's/^/        /'

pick() { printf '%s\n' "$ALL_CTX" | grep -i -- "$1" | grep -vi -- "${2:-@@nada@@}" | head -1; }
[ -z "$CTX_LAB" ] && CTX_LAB=$(pick 'paas-lab')
case "$DESTINO" in
  arqlab) [ -z "$CTX_DST" ] && CTX_DST=$(pick 'arqlab') ;;
  eks)    [ -z "$CTX_DST" ] && CTX_DST=$(pick 'cilium\|eks') ;;
  none)   CTX_DST="" ;;
esac

if [ -z "$CTX_LAB" ]; then
  bad "no encontré un contexto que matchee 'paas-lab' — pasalo con CTX_LAB=<nombre>"
  exit 1
fi
ok "origen  (paas-lab): $CTX_LAB"
SRV_LAB=$(L whoami --show-server)
[ -z "$SRV_LAB" ] && { bad "el contexto $CTX_LAB no responde (¿token vencido? oc login)"; exit 1; }
info "server: $SRV_LAB   usuario: $(L whoami)"
info "OCP:    $(L get clusterversion version -o jsonpath='{.status.desired.version}')"

if [ -n "$CTX_DST" ]; then
  SRV_DST=$(D whoami --show-server)
  if [ -n "$SRV_DST" ]; then
    ok "destino ($DESTINO): $CTX_DST"
    info "server: $SRV_DST   OCP: $(D get clusterversion version -o jsonpath='{.status.desired.version}')"
  else
    warn "el contexto destino '$CTX_DST' no responde — el cross-check de §5 se saltea"
    CTX_DST=""
  fi
else
  warn "sin contexto destino (DESTINO=$DESTINO) — se saltea el cross-check de §5"
fi

# guard: que no sean el mismo cluster
if [ -n "$CTX_DST" ] && [ "$SRV_LAB" = "${SRV_DST:-}" ]; then
  bad "origen y destino apuntan al MISMO API server — revisá los contextos"; CTX_DST=""
fi

# ─── §1 Authorino / Kuadrant en paas-lab ──────────────────────────────────────
sec "1. Authorino / Kuadrant en paas-lab"

L get ns "$NS_KUADRANT" >/dev/null \
  && ok "namespace $NS_KUADRANT existe" || bad "no existe el namespace $NS_KUADRANT"
L get sa "$SA_AUTHORINO" -n "$NS_KUADRANT" >/dev/null \
  && ok "ServiceAccount $SA_AUTHORINO presente (es la identidad que valida Vault)" \
  || bad "falta la SA $SA_AUTHORINO — el bound_subject de Vault no va a cerrar"

AUTHORINO_CR=$(L get authorino -n "$NS_KUADRANT" -o jsonpath='{.items[0].metadata.name}')
ECS=$(L get authorino -n "$NS_KUADRANT" -o jsonpath='{.items[0].spec.evaluatorCacheSize}')
if [ -z "$ECS" ]; then
  bad "evaluatorCacheSize NO seteado en el CR Authorino (${AUTHORINO_CR:-no encontrado}) → default 1MB"
  info "cada escritura al cache del mint falla EN SILENCIO (tope por entrada = 1/1024 ≈ 1KB; el"
  info "JWT-SVID pesa ~1042 bytes) → mintea contra Vault en CADA request. Desde on-prem son ~0.5s"
  info "contra un ext_authz de ${MINT_BUDGET_MS}ms → fallo intermitente (~25% medido en arqlab)."
  info "fix: poc-egress-kuadrant/origen/vault/02-authorino-evaluator-cache-size.yaml"
elif [ "$ECS" -lt "$CACHE_SIZE_MIN" ] 2>/dev/null; then
  bad "evaluatorCacheSize = $ECS (< $CACHE_SIZE_MIN) — mismo problema que el default"
else
  ok "evaluatorCacheSize = $ECS MB (alcanza para cachear el JWT-SVID)"
fi
for f in clusterWide supersedingHostSubsets logLevel; do
  info "$f: $(L get authorino "$AUTHORINO_CR" -n "$NS_KUADRANT" -o jsonpath="{.spec.$f}" || echo '<unset>')"
done
[ "$(L get authorino "$AUTHORINO_CR" -n "$NS_KUADRANT" -o jsonpath='{.spec.logLevel}')" = "debug" ] \
  && warn "logLevel=debug quedó puesto — revertir después de diagnosticar"

RDY=$(L get deploy authorino -n "$NS_KUADRANT" -o jsonpath='{.status.readyReplicas}/{.status.replicas}')
if [ -z "${RDY:-}" ] || [ "$RDY" = "/" ]; then
  bad "no encuentro el Deployment authorino en $NS_KUADRANT"
else
  ok "deployment authorino ready: $RDY"
  L get pods -n "$NS_KUADRANT" -l authorino-resource --no-headers \
    -o custom-columns='POD:.metadata.name,REINICIOS:.status.containerStatuses[0].restartCount,CREADO:.metadata.creationTimestamp' \
    | sed 's/^/        /'
fi

if L get crd authpolicies.kuadrant.io -o yaml | grep -q "prefix"; then
  ok "el CRD AuthPolicy ACEPTA credentials.customHeader.prefix (dialecto RHCL)"
else
  warn "el CRD AuthPolicy NO tiene customHeader.prefix (dialecto upstream)"
fi
info "igual NO usar el prefijo: confirmado en vivo que Authorino no lo saca al parsear."
L get csv -n "$NS_KUADRANT" --no-headers -o custom-columns='CSV:.metadata.name,FASE:.status.phase' \
  | sed 's/^/        /'

sec "1bis. Gateway API en paas-lab (OCP 4.18 — arqlab es 4.20, puede diferir)"
GC=$(L get gatewayclass --no-headers -o custom-columns='NOMBRE:.metadata.name,CONTROLLER:.spec.controllerName')
if [ -z "$GC" ]; then
  bad "no hay GatewayClasses — Gateway API / OSSM no está listo en este cluster"
  info "arqlab usa gatewayClassName: openshift-default (4.20). En 4.18 puede hacer falta OSSM3 + class 'istio'."
else
  ok "GatewayClasses disponibles:"; printf '%s\n' "$GC" | sed 's/^/        /'
  printf '%s' "$GC" | grep -q openshift-default \
    && info "'openshift-default' presente → 01-gateway-egress.yaml de arqlab aplica tal cual" \
    || warn "sin 'openshift-default' → hay que reescribir el Gateway para la class real de este cluster"
fi

# ─── §2 federación con Vault, lado cluster ────────────────────────────────────
sec "2. Federación con Vault — lado cluster (resuelve el typo jwt-paas-lab vs jwt-paas-lab1)"

CJ=$(L get cronjob -n "$NS_KUADRANT" -o name | grep -i vault | head -1)
MOUNT=""; JWT_ROLE=""; SECRET_NAME=""; CJ_IMG=""
if [ -z "$CJ" ]; then
  bad "no hay CronJob de login a Vault en $NS_KUADRANT"
else
  ok "CronJob: $CJ"
  CJ_CMD=$(L get "$CJ" -n "$NS_KUADRANT" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command[2]}')
  SCHED=$(L get "$CJ" -n "$NS_KUADRANT" -o jsonpath='{.spec.schedule}')
  CJ_SA=$(L get "$CJ" -n "$NS_KUADRANT" -o jsonpath='{.spec.jobTemplate.spec.template.spec.serviceAccountName}')
  CJ_IMG=$(L get "$CJ" -n "$NS_KUADRANT" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')
  # el CronJob desplegado es la fuente de verdad de qué mount autentica de verdad.
  # El command trae el JSON escapado (\"role\": \"...\"), así que sacamos los backslashes
  # primero y después parseamos plano — si no, el patrón se rompe contra el escapado real.
  CJ_CLEAN=$(printf '%s' "$CJ_CMD" | tr -d '\\')
  MOUNT=$(printf '%s' "$CJ_CLEAN"    | grep -o 'auth/[A-Za-z0-9_-]*/login' | head -1 | cut -d/ -f2)
  JWT_ROLE=$(printf '%s' "$CJ_CLEAN" | grep -o '"role"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//')
  SECRET_NAME=$(printf '%s' "$CJ_CLEAN" | grep -o 'secret generic [A-Za-z0-9_.-]*' | head -1 | awk '{print $3}')
  info "schedule       : ${SCHED:-?}     (*/30 parejo; */50 corre en :00 y :50, irregular)"
  info "serviceAccount : ${CJ_SA:-?}"
  info "imagen         : ${CJ_IMG:-?}   ← se reusa para el pod de sondeo (pulleable seguro)"
  info "mount EN USO   : auth/${MOUNT:-?}     ← el que realmente autentica"
  info "role jwt       : ${JWT_ROLE:-?}"
  info "secret destino : ${SECRET_NAME:-?}"
  [ "${CJ_SA:-}" = "$SA_AUTHORINO" ] \
    && ok "el CronJob corre con la misma SA que Authorino" \
    || bad "el CronJob NO usa $SA_AUTHORINO — la identidad no coincide con la que mintea"
  case "${SCHED:-}" in */30*) ok "schedule parejo de 30 min (TTL del token = 1h)";;
    *) warn "schedule '${SCHED:-?}' — verificar que refresque antes de los 3600s del token";; esac
  case "${MOUNT:-}" in
    *1) warn "el mount en uso termina en '1' — coincide con el typo del paso 2a (jwt-paas-lab1)";;
  esac
fi

JOBS=$(L get jobs -n "$NS_KUADRANT" --sort-by=.metadata.creationTimestamp --no-headers \
       -o custom-columns='JOB:.metadata.name,OK:.status.succeeded,FALLOS:.status.failed,FIN:.status.completionTime' \
       | grep -i vault | tail -5)
if [ -n "$JOBS" ]; then
  printf '%s\n' "$JOBS" | sed 's/^/        /'
  printf '%s' "$JOBS" | tail -1 | grep -qE '[[:space:]]1[[:space:]]' \
    && ok "el último job de login terminó OK" \
    || warn "el último job no muestra succeeded=1 — mirar sus logs"
else
  warn "no hay Jobs del CronJob todavía (¿nunca corrió?)"
fi

SECRET_NAME="${SECRET_NAME:-vault-egress-token-paas-lab}"
SEC_TS=$(L get secret "$SECRET_NAME" -n "$NS_KUADRANT" -o jsonpath='{.metadata.creationTimestamp}')
TOK=$(L get secret "$SECRET_NAME" -n "$NS_KUADRANT" -o jsonpath='{.data.client_token}' | base64 -d 2>/dev/null)
if [ -z "$TOK" ]; then
  bad "el Secret $SECRET_NAME no existe o no tiene client_token"
else
  ok "Secret $SECRET_NAME poblado (${#TOK} chars, creado $SEC_TS)"
  info "si Authorino quedó con el valor viejo cacheado manda X-Vault-Token vacío → Vault responde"
  info "'permission denied' sin la key data → 403 'no such key: data'. Fix: rollout restart authorino."
fi

RL=$(L get role -n "$NS_KUADRANT" -o name | grep -i vault | head -1)
RB=$(L get rolebinding -n "$NS_KUADRANT" -o name | grep -i vault | head -1)
[ -n "$RL" ] && ok "Role: $RL  resourceNames: $(L get "$RL" -n "$NS_KUADRANT" -o jsonpath='{.rules[*].resourceNames}')" \
             || bad "falta el Role que deja al SA escribir el Secret"
[ -n "$RB" ] && ok "RoleBinding: $RB" || bad "falta el RoleBinding"

sec "2bis. Issuer y claves de firma de paas-lab (auth/$MOUNT usa pubkeys ESTÁTICAS)"
OIDC=$(L get --raw /.well-known/openid-configuration)
ISS=$(printf '%s' "$OIDC" | pluck issuer)
if [ -n "$ISS" ]; then
  ok "issuer real del cluster: $ISS"
  info "tiene que coincidir EXACTO con el bound_issuer de auth/$MOUNT/config"
else
  warn "no pude leer /.well-known/openid-configuration — verificar el issuer a mano"
fi
KIDS=$(L get --raw /openid/v1/jwks | grep -o '"kid"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//; s/"$//')
if [ -n "$KIDS" ]; then
  ok "kids de firma de SA tokens vigentes en paas-lab:"; printf '%s\n' "$KIDS" | sed 's/^/        /'
  info "RIESGO: estas claves se cargaron UNA VEZ en jwt_validation_pubkeys. Si OCP rota la clave"
  info "de firma de SA, el login rompe y no hay discovery que lo tape."
else
  warn "no pude leer /openid/v1/jwks"
fi

# ─── §3 Vault en vivo, con el cluster como proxy ──────────────────────────────
sec "3. Vault en vivo — el OCP como proxy (el bastión no le habla a Vault)"
MINTED_SUB=""; MINTED_AUD=""
build_probe() {
cat <<PODSCRIPT
set -u
V="$VAULT_ADDR/v1"; H="X-Vault-Namespace: $VAULT_NS"
b64url() { tr '_-' '/+' | awk '{n=length(\$0)%4; if(n==2)\$0=\$0"=="; else if(n==3)\$0=\$0"="; print}' | base64 -d 2>/dev/null; }
pk() { grep -o "\"\$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"//; s/"\$//'; }

echo "### 3.1 alcanzabilidad a Vault desde la red del cluster"
# OJO: sys/health devuelve 404 bajo X-Vault-Namespace (vive en el root namespace), así que
# NO sirve como sonda. Se usa un GET plano al JWKS público: no necesita token ni namespace
# header, y es exactamente el endpoint que va a consultar el Authorino del destino.
echo "REACH=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "\$V/$VAULT_NS/$SPIFFE_MOUNT/.well-known/keys" 2>&1)"

echo "### 3.2 login con la identidad real (misma SA que usa Authorino)"
SA=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "SA_ISS=\$(printf %s "\$SA" | cut -d. -f2 | b64url | pk iss)"
echo "SA_SUB=\$(printf %s "\$SA" | cut -d. -f2 | b64url | pk sub)"
echo "SA_AUD_RAW=\$(printf %s "\$SA" | cut -d. -f2 | b64url | grep -o '"aud":\[[^]]*\]')"
L=\$(curl -sS --max-time 15 -X POST "\$V/auth/$MOUNT/login" -H "\$H" \
      -d "{\\"role\\": \\"$JWT_ROLE\\", \\"jwt\\": \\"\$SA\\"}")
echo "LOGIN_POLICIES=\$(printf %s "\$L" | grep -o '"token_policies":\[[^]]*\]')"
echo "LOGIN_TTL=\$(printf %s "\$L" | grep -o '"lease_duration":[0-9]*' | cut -d: -f2 | sort -rn | head -1)"
echo "LOGIN_ERR=\$(printf %s "\$L" | grep -o '"errors":\[[^]]*\]')"

echo "### 3.3 mint con el client_token del Secret (exactamente lo que hace Authorino)"
M=\$(curl -sS --max-time 15 -X POST "\$V/$SPIFFE_MOUNT/role/$SPIFFE_ROLE/mintjwt" \
      -H "\$H" -H "X-Vault-Token: \$VAULT_SESSION_TOKEN" -d '{"audience": "$AUD_PROBE"}')
echo "MINT_ERR=\$(printf %s "\$M" | grep -o '"errors":\[[^]]*\]')"
T=\$(printf %s "\$M" | pk token)
if [ -n "\$T" ]; then
  PL=\$(printf %s "\$T" | cut -d. -f2 | b64url)
  echo "MINT_BYTES=\$(printf %s "\$T" | wc -c | tr -d ' ')"
  echo "TOK_ALG=\$(printf %s "\$T" | cut -d. -f1 | b64url | pk alg)"
  KID=\$(printf %s "\$T" | cut -d. -f1 | b64url | pk kid); echo "TOK_KID=\$KID"
  echo "TOK_SUB=\$(printf %s "\$PL" | pk sub)"
  echo "TOK_ISS=\$(printf %s "\$PL" | pk iss)"
  echo "TOK_AUD=\$(printf %s "\$PL" | grep -o '"aud":\[[^]]*\]')"
  E=\$(printf %s "\$PL" | grep -o '"exp":[0-9]*' | cut -d: -f2)
  I=\$(printf %s "\$PL" | grep -o '"iat":[0-9]*' | cut -d: -f2)
  echo "TOK_TTL=\$((E-I))"
else
  echo "TOK_KID="; KID=""
fi

echo "### 3.4 JWKS publico (lo que consulta el Authorino del DESTINO)"
J=\$(curl -sS --max-time 15 "\$V/$VAULT_NS/$SPIFFE_MOUNT/.well-known/keys")
echo "JWKS_KIDS=\$(printf %s "\$J" | grep -o '"kid"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//; s/"\$//' | tr '\n' ',')"
if [ -n "\$KID" ] && printf %s "\$J" | grep -q "\$KID"; then echo "KID_MATCH=si"; else echo "KID_MATCH=no"; fi

echo "### 3.5 latencia del mint — CON REUSO DE CONEXION"
# Cinco invocaciones separadas de curl miden 5 handshakes TLS, no 5 mints: infla el numero
# ~3x (medido: 485 ms separados vs 160 ms reusando). Authorino usa pool, asi que lo que
# importa es el numero tibio. Una sola invocacion con la URL repetida reusa la conexion.
MU="\$V/$SPIFFE_MOUNT/role/$SPIFFE_ROLE/mintjwt"
curl -sS -o /dev/null -w '%{time_total}\n' --max-time 30 -X POST -H "\$H" \
  -H "X-Vault-Token: \$VAULT_SESSION_TOKEN" -d '{"audience": "$AUD_PROBE"}' \
  "\$MU" "\$MU" "\$MU" "\$MU" "\$MU" "\$MU" \
  | awk '{printf "%.0f ", \$1*1000} END{print ""}' | sed 's/^/LAT_MS=/'
PODSCRIPT
}

if [ "${SKIP_VAULT:-0}" = "1" ]; then
  warn "SKIP_VAULT=1 — salteando los chequeos contra Vault"
elif [ -z "$MOUNT" ] || [ -z "$TOK" ]; then
  bad "sin mount o sin client_token no puedo probar Vault — resolver §2 primero"
elif [ "$PROBE_MODE" = "manual" ]; then
  warn "PROBE_MODE=manual — no creo el pod. Pegá esto DENTRO de un pod del cluster:"
  echo; echo "export VAULT_SESSION_TOKEN='<el client_token del Secret $SECRET_NAME>'"
  build_probe; echo
else
  IMG="${IMG_PROBE:-${CJ_IMG:-alpine/k8s:1.30.0}}"
  info "pod efímero: imagen $IMG, SA $SA_AUTHORINO, ns $NS_KUADRANT (se borra solo)"
  info "el Warning de PodSecurity 'restricted' que imprime oc es benigno: es advertencia, no"
  info "rechazo — el pod arranca igual y se borra al terminar."
  info "mount=auth/$MOUNT  role_jwt=$JWT_ROLE  role_spiffe=$SPIFFE_MOUNT/$SPIFFE_ROLE  aud=$AUD_PROBE"
  OUT=$(oc --context="$CTX_LAB" run "vault-preflight-$$" -n "$NS_KUADRANT" --rm -i --restart=Never \
          --image="$IMG" --quiet --request-timeout=180s \
          --env="VAULT_SESSION_TOKEN=$TOK" \
          --overrides="{\"spec\":{\"serviceAccountName\":\"$SA_AUTHORINO\"}}" \
          -- sh -c "$(build_probe)" 2>&1)
  printf '%s\n' "$OUT" | sed 's/^/        /'

  g() { printf '%s' "$OUT" | grep -m1 "^$1=" | cut -d= -f2-; }
  case "$(g REACH)" in
    200|429|472|473|501|503) ok "Vault alcanzable desde paas-lab (HTTP $(g REACH)) — el proxy por el cluster funciona";;
    "") bad "sin respuesta — el pod no llegó a correr (¿imagen no pulleable? ¿SCC? probá PROBE_MODE=manual)";;
    *)  bad "Vault NO alcanzable desde paas-lab (código '$(g REACH)') — sin esto no hay federación";;
  esac
  if [ -n "$(g LOGIN_POLICIES)" ]; then
    ok "login OK → $(g LOGIN_POLICIES), TTL $(g LOGIN_TTL)s"
    printf '%s' "$(g LOGIN_POLICIES)" | grep -q "mint-only" \
      && ok "la policy acotada está asignada (no la de admin)" \
      || warn "no veo una policy 'mint-only' — ¿quedó con spiffe-administrator-policy?"
  else
    bad "el login falló: $(g LOGIN_ERR)"
    info "revisar bound_subject / bound_issuer / jwt_validation_pubkeys de auth/$MOUNT"
    info "SA real → iss=$(g SA_ISS)  sub=$(g SA_SUB)  aud=$(g SA_AUD_RAW)"
  fi
  if [ -z "$(g MINT_ERR)" ] && [ -n "$(g TOK_KID)" ]; then
    MINTED_SUB="$(g TOK_SUB)"; MINTED_AUD="$(g TOK_AUD)"
    ok "mint OK → sub=$MINTED_SUB"
    info "iss=$(g TOK_ISS)  aud=$MINTED_AUD  ttl=$(g TOK_TTL)s  alg=$(g TOK_ALG)  $(g MINT_BYTES) bytes"
    case "$MINTED_SUB" in
      *paas-lab*) ok "el sub identifica a paas-lab (distinguible de arqlab y de EKS)";;
      *) warn "el sub NO menciona paas-lab: '$MINTED_SUB' — revisar el template del role";;
    esac
  else
    bad "el mint falló: $(g MINT_ERR) — revisar la policy y el role $SPIFFE_MOUNT/$SPIFFE_ROLE"
  fi
  [ "$(g KID_MATCH)" = "si" ] \
    && ok "el kid del token está en el JWKS público → el destino puede validar la firma" \
    || bad "el kid NO aparece en el JWKS ($(g JWKS_KIDS)) — el destino va a rechazar por firma"
  LAT="$(g LAT_MS)"
  if [ -n "$LAT" ]; then
    MAXL=$(printf '%s\n' $LAT | tr ' ' '\n' | grep -v '^$' | sort -n | tail -1)
    # La PRIMERA muestra incluye el handshake; las siguientes son el numero real.
    if [ "${MAXL:-0}" -gt "$MINT_BUDGET_MS" ] 2>/dev/null; then
      warn "latencia del mint: ${LAT}ms (max ${MAXL}ms) > ${MINT_BUDGET_MS}ms del ext_authz"
      info "ignorar la PRIMERA muestra (handshake). Si las demas entran holgadas, el timeout"
      info "no es el problema; si rozan el limite, hay margen insuficiente y falla con jitter."
      info "sin cache real de Authorino esto es fallo intermitente (arqlab: ~25% en 15 reqs)."
      info "con evaluatorCacheSize OK + cache.ttl 250 se mintea 1 vez cada 250s, no por request."
    else
      ok "latencia del mint: ${LAT}ms — entra en el presupuesto de ${MINT_BUDGET_MS}ms"
    fi
  fi
fi

# ─── §4 topología de la app en paas-lab ───────────────────────────────────────
sec "4. App y topología en paas-lab / $NS_POC"
if ! L get ns "$NS_POC" >/dev/null; then
  warn "no existe el namespace $NS_POC (probá NS_POC=<el tuyo>)"
else
  ok "namespace $NS_POC existe"
  L get deploy -n "$NS_POC" --no-headers -o custom-columns='DEPLOY:.metadata.name,READY:.status.readyReplicas' \
    | sed 's/^/        /'
  NB=$(L get pods -n "$NS_POC" -l app=bff --no-headers | grep -c Running)
  [ "${NB:-0}" -ge 1 ] && ok "$NB pod(s) bff Running" || warn "no veo pods bff Running (¿otro label?)"
  SEL=$(L get svc backend -n "$NS_POC" -o jsonpath='{.spec.selector}')
  if [ -n "$SEL" ]; then
    info "Service backend selector: $SEL"
    printf '%s' "$SEL" | grep -qi 'gateway' \
      && info "→ apunta al gateway de egreso: el cutover YA está hecho" \
      || info "→ apunta a los pods locales: pre-cutover"
  else
    warn "no existe el Service backend en $NS_POC"
  fi
  info "bff UPSTREAM_URL: $(L get deploy bff -n "$NS_POC" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="UPSTREAM_URL")].value}' || echo '<vacío>')"
  echo
  for k in gateway.gateway.networking.k8s.io httproute.gateway.networking.k8s.io \
           authpolicy.kuadrant.io serviceentry.networking.istio.io destinationrule.networking.istio.io; do
    R=$(L get "$k" -n "$NS_POC" --no-headers -o custom-columns='N:.metadata.name')
    [ -z "$R" ] && { info "${k%%.*}: (ninguno)"; continue; }
    for n in $R; do
      C=$(L get "$k" "$n" -n "$NS_POC" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}')
      A=$(L get "$k" "$n" -n "$NS_POC" -o jsonpath='{range .status.parents[*]}{.conditions[*].type}={.conditions[*].status} {end}')
      info "${k%%.*}/$n  ${C:-$A}"
    done
  done
fi

# ─── §5 cross-check origen ↔ destino ──────────────────────────────────────────
sec "5. Cross-check: ¿el destino ($DESTINO) acepta lo que paas-lab mintea?"
if [ -z "$CTX_DST" ]; then
  warn "sin contexto destino — saltado"
else
  info "namespace destino consultado: $NS_POC_DST (en arqlab el ns que VALIDA es poc-ingress-kuadrant)"
  VALIDATORS=0; SKIPPED=0
  AP=$(D get authpolicy -n "$NS_POC_DST" -o name | head -10)
  if [ -z "$AP" ]; then
    warn "no hay AuthPolicy en $NS_POC_DST del destino (probá NS_POC_DST=<ns>)"
  else
    for a in $AP; do
      APY=$(D get "$a" -n "$NS_POC_DST" -o yaml)
      if ! printf '%s' "$APY" | grep -q 'jwksUrl\|issuerUrl'; then
        info "$a — es una AuthPolicy de ORIGEN (mintea, no valida): la salteo"
        SKIPPED=$((SKIPPED+1)); continue
      fi
      VALIDATORS=$((VALIDATORS+1))
      info "AuthPolicy destino: $a"
      info "  jwksUrl : $(printf '%s' "$APY" | grep -o 'jwksUrl:.*' | head -1 | cut -d' ' -f2-)"
      info "  header  : $(printf '%s' "$APY" | grep -A2 customHeader | grep 'name:' | head -1 | awk '{print $2}')"
      printf '%s' "$APY" | grep -q 'prefix:' && warn "  tiene 'prefix:' — Authorino no lo saca; el origen debe mandar el JWT crudo"

      SUBS=$(printf '%s' "$APY" | grep -o 'spiffe://[^"]*' | sort -u)
      AUDS=$(printf '%s' "$APY" | grep -o '"[a-z0-9.-]*\.bancogalicia\.com\.ar"' | tr -d '"' | sort -u)
      info "  subs aceptados : $(printf '%s' "$SUBS" | tr '\n' ' ')"
      info "  auds aceptadas : $(printf '%s' "$AUDS" | tr '\n' ' ')"

      if [ -n "$MINTED_SUB" ]; then
        printf '%s\n' "$SUBS" | grep -qx "$MINTED_SUB" \
          && ok "  el sub de paas-lab YA está aceptado por este destino" \
          || bad "  el sub de paas-lab ($MINTED_SUB) NO está en claims-esperados → va a dar 403"
      fi
      printf '%s' "$APY" | grep -q 'auth.identity.sub ==' \
        && warn "  el sub se compara con '==' (un solo valor) → pasar a lista + 'in' para admitir paas-lab"
      info "  → la audiencia del mint de paas-lab tiene que ser una de las de arriba;"
      info "    el probe de §3 minteó ${MINTED_AUD:-<sin dato: Vault no sondeado>}"
    done
    [ "$VALIDATORS" -eq 0 ] && bad "en $NS_POC_DST del destino no hay ninguna AuthPolicy que VALIDE JWT ($SKIPPED de origen) — probá NS_POC_DST=poc-ingress-kuadrant"
  fi
  D get authorino -n "$NS_KUADRANT" -o jsonpath='{.items[0].spec.evaluatorCacheSize}' \
    | sed 's/^/        destino evaluatorCacheSize: /'; echo
fi

# ─── resumen ──────────────────────────────────────────────────────────────────
sec "Resumen"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n\n' "$C_G" "$P" "$C_Z" "$C_Y" "$W" "$C_Z" "$C_R" "$F" "$C_Z"
cat <<'FIN'
  Pendientes de diseño que ningún chequeo automático resuelve:

  1. LA AUDIENCIA NO SE CONMUTA CON EL HTTPRoute. Va hardcodeada en el body del mint de la
     AuthPolicy de origen y se valida en el destino. Cambiar el backendRef no alcanza: hay que
     cambiar la audiencia Y el cache.key — si no, Authorino reusa hasta 250s el token de la
     audiencia vieja y el 403 parece un problema de red.

  2. EL SUB DE paas-lab hay que habilitarlo en el destino (hoy pinean un único sub con '==').

  3. EL INGRESO gw-hostnet DE arqlab NO ENFORCEA: ninguna AuthPolicy sobre ese gateway está
     Enforced (Kuadrant reporta que no lo sincroniza). Mientras siga así, un 200 cruzando a
     arqlab no prueba que la autorización funcione. Ver
     poc-onprem-kuadrant/destino-arqlab/14-diagnostico-claims.md.
FIN
exit 0
