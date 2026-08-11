#!/usr/bin/env bash
# Diagnóstico y reparación del montaje del destino OCP, recorriendo la cadena de Gateway
# API **de abajo hacia arriba** y parando en el primer escalón roto.
#
#   CTX_DST=paas-dev1-lowmz ./27-reparar.sh
#   CTX_DST=paas-dev1-lowmz CRT=./wildcard.crt KEY=./wildcard.key ./27-reparar.sh
#
# POR QUÉ DE ABAJO HACIA ARRIBA
#
# La cadena es una escalera y Kuadrant está al final:
#
#   Secret -> listener -> Gateway -> HTTPRoute -> AuthPolicy
#
# Cuando se rompe un escalón bajo, el error se reporta arriba de todo y con un mensaje que
# no nombra ni al Gateway ni al Secret. El caso medido el 2026-08-05 en `paas-dev1-lowmz`:
# faltaba el Secret del wildcard y el síntoma fue
#
#   AuthPolicy ... Enforced=False: "AuthPolicy is not in the path to any existing routes"
#
# que manda a revisar el JWKS, que estaba perfecto. Ver [H14](../HALLAZGOS.md#h14).
#
# Es idempotente: se puede correr las veces que haga falta, y en verde no toca nada.
set -uo pipefail

CTX_DST="${CTX_DST:-}"
NS_DST="${NS_DST:-echoserver}"
GW="${GW:-ingress-gw}"
ROUTE="${ROUTE:-backend}"
POLICY="${POLICY:-backend-ingress-jwt}"
LISTENER="${LISTENER:-https}"
CERT_SECRET="${CERT_SECRET:-paas-demo-wildcard-tls}"
FQDN="${FQDN:-app2.paas-demo.bancogalicia.com.ar}"
DST_IP="${DST_IP:-10.254.34.2}"
HOST_INTERNO="${HOST_INTERNO:-backend.poc-egress-kuadrant.svc.cluster.local:8080}"
CRT="${CRT:-}"   # opcional: si el Secret falta, se crea con estos dos archivos
KEY="${KEY:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -t 1 ]]; then V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; Z=$'\e[0m'
else V=; R=; A=; B=; D=; Z=; fi
paso(){ printf '\n%s>> %s%s\n' "$B" "$1" "$Z"; }
ok(){   printf '   %s✔%s %s\n' "$V" "$Z" "$1"; }
err(){  printf '   %s✘%s %s\n' "$R" "$Z" "$1"; }
adv(){  printf '   %s!%s %s\n' "$A" "$Z" "$1"; }
inf(){  printf '   %s%s%s\n' "$D" "$1" "$Z"; }

ocd(){ oc ${CTX_DST:+--context="$CTX_DST"} "$@"; }

# Corta la corrida explicando qué arreglar. No tiene sentido seguir subiendo la escalera:
# todo lo de arriba va a fallar por herencia y el diagnóstico se vuelve ruido.
cortar(){ printf '\n   %sEl primer escalón roto es este. Arreglarlo y volver a correr.%s\n\n' "$B" "$Z"; exit 1; }

for b in oc jq openssl; do command -v $b >/dev/null || { echo "falta '$b' en el PATH"; exit 2; }; done
printf '%sDestino OCP — reparación en cadena%s\n' "$B" "$Z"
inf "cluster: ${CTX_DST:-<contexto actual>}   ns: $NS_DST   gateway: $GW   fqdn: $FQDN"

# ─────────────────────────────────────────────────── R1. la clase, o no hay controller
paso "R1. GatewayClass openshift-default"
GC=$(ocd get gatewayclass openshift-default -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
if [[ "$GC" == "True" ]]; then
  ok "Accepted=True"
else
  err "no está Accepted (=${GC:-ausente})"
  inf "sin la clase, el Gateway se crea igual pero NINGÚN controller lo mira: no hay status,"
  inf "el HTTPRoute nunca se adopta y el error termina apareciendo en la AuthPolicy."
  inf "crearla con 01_apim/13_guia_instalacion_rhcl_ocp420.md"
  cortar
fi

# ─────────────────────────────────────────────────── R2. el certificado del listener
paso "R2. Secret del wildcard ($CERT_SECRET)"
if ! ocd -n "$NS_DST" get secret "$CERT_SECRET" >/dev/null 2>&1; then
  err "no existe"
  if [[ -n "$CRT" && -n "$KEY" ]]; then
    inf "creándolo desde $CRT / $KEY"
    ocd -n "$NS_DST" create secret tls "$CERT_SECRET" --cert="$CRT" --key="$KEY" \
      --dry-run=client -o yaml | ocd apply -f - >/dev/null && ok "Secret creado" || { err "no se pudo crear"; cortar; }
  else
    inf "crearlo con la cadena completa, o volver a correr con CRT=... KEY=...:"
    inf "  oc -n $NS_DST create secret tls $CERT_SECRET --cert=wildcard.crt --key=wildcard.key"
    cortar
  fi
fi

TIPO=$(ocd -n "$NS_DST" get secret "$CERT_SECRET" -o jsonpath='{.type}')
[[ "$TIPO" == "kubernetes.io/tls" ]] && ok "tipo kubernetes.io/tls" || { err "tipo $TIPO — tiene que ser kubernetes.io/tls"; cortar; }

PEM=$(ocd -n "$NS_DST" get secret "$CERT_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null)
N=$(grep -c 'BEGIN CERTIFICATE' <<<"$PEM")
if (( N > 1 )); then
  ok "tls.crt trae la cadena ($N certificados)"
else
  adv "tls.crt trae sólo $N certificado (la hoja)"
  inf "si la CA raíz que cargaste en el Secret destino-ca del ORIGEN no firma directo esta"
  inf "hoja, Envoy no puede armar la cadena y el handshake falla con un 503 genérico."
fi

SAN=$(openssl x509 -noout -ext subjectAltName <<<"$PEM" 2>/dev/null | tr -d ' ')
inf "SAN: ${SAN:-(no se pudo leer)}"
DOM="*.${FQDN#*.}"
if grep -qF -e "DNS:$FQDN" -e "DNS:$DOM" <<<"$SAN"; then
  ok "el SAN cubre $FQDN"
else
  err "el SAN NO cubre $FQDN ni $DOM"
  inf "Envoy valida el nombre contra el SAN, no contra el CN: el handshake va a fallar."
  cortar
fi

# La otra falla silenciosa del par: cert y key que no se corresponden. El Secret se crea
# igual y el listener puede llegar a Programmed, pero el handshake nunca cierra.
MC=$(openssl x509 -noout -modulus <<<"$PEM" 2>/dev/null | openssl md5)
MK=$(ocd -n "$NS_DST" get secret "$CERT_SECRET" -o jsonpath='{.data.tls\.key}' | base64 -d 2>/dev/null \
     | openssl rsa -noout -modulus 2>/dev/null | openssl md5)
[[ -n "$MC" && "$MC" == "$MK" ]] && ok "la clave privada corresponde al certificado" \
                                 || adv "no se pudo confirmar que la clave corresponda al certificado"

# ─────────────────────────────────────────────────── R3. el Gateway y su listener
paso "R3. Gateway $GW"
ocd -n "$NS_DST" get gateway "$GW" >/dev/null 2>&1 || { err "no existe — aplicar 21-gateway-ingress.yaml"; cortar; }

PROG=$(ocd -n "$NS_DST" get gateway "$GW" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
LCOND=$(ocd -n "$NS_DST" get gateway "$GW" \
        -o jsonpath="{range .status.listeners[?(@.name=='$LISTENER')]}{range .conditions[*]}{.type}={.status}({.reason}) {end}{end}" 2>/dev/null)
ATT=$(ocd -n "$NS_DST" get gateway "$GW" \
      -o jsonpath="{.status.listeners[?(@.name=='$LISTENER')].attachedRoutes}" 2>/dev/null)
inf "listener $LISTENER: ${LCOND:-sin condiciones}"

if [[ "$PROG" != "True" ]]; then
  err "Programmed=${PROG:-vacío}"
  [[ "$LCOND" == *"InvalidCertificateRef"* ]] && inf "es el certificado: revisar R2 (nombre del Secret, ns, tipo)"
  [[ "$LCOND" == *"NoConflicts=False"* ]]     && inf "hay otro Gateway peleando el mismo puerto en este ns"
  cortar
fi
ok "Programmed=True"

LABEL=$(ocd -n "$NS_DST" get gateway "$GW" -o jsonpath='{.metadata.labels.kuadrant\.io/gateway}' 2>/dev/null)
[[ "$LABEL" == "true" ]] && ok "label kuadrant.io/gateway presente" \
                         || { err "falta la label kuadrant.io/gateway=true"; inf "sin ella Kuadrant no gestiona políticas sobre este Gateway"; cortar; }

# ResolvedRefs=True no prueba que el certificado haya LLEGADO al proxy: se calcula contra
# lo que istiod puede leer y la entrega por SDS se evalúa después (runbook de ingress §7.2).
POD=$(ocd -n "$NS_DST" get pod -l gateway.networking.k8s.io/gateway-name="$GW" -o name 2>/dev/null | head -1)
if [[ -n "$POD" ]]; then
  SDS=$(ocd -n "$NS_DST" exec "$POD" -- curl -s 'localhost:15000/config_dump?resource=dynamic_active_secrets' 2>/dev/null | grep -c '"name"')
  (( ${SDS:-0} > 0 )) && ok "el certificado llegó al proxy ($SDS secretos activos)" \
                      || adv "el proxy no reporta secretos activos — posible bloqueo de entrega por SDS"
else
  adv "no hay pods del data plane todavía"
fi

# ─────────────────────────────────────────────────── R4. la adopción del HTTPRoute
paso "R4. HTTPRoute $ROUTE adoptado por el Gateway"
ocd -n "$NS_DST" get httproute "$ROUTE" >/dev/null 2>&1 || { err "no existe — aplicar 23-httproute-backend.yaml"; cortar; }

# La condición `Accepted` la escribe el controller de Gateway API. Si el status SÓLO trae
# `kuadrant.io/AuthPolicyAffected`, el HTTPRoute no fue adoptado por ningún Gateway: es
# exactamente el estado que produce el "not in the path to any existing routes" de R5.
ACC=$(ocd -n "$NS_DST" get httproute "$ROUTE" \
      -o jsonpath='{range .status.parents[*]}{range .conditions[?(@.type=="Accepted")]}{.status}{end}{end}' 2>/dev/null)
inf "attachedRoutes del listener: ${ATT:-0}"
if [[ "$ACC" == *"True"* ]]; then
  ok "Accepted=True"
else
  err "el HTTPRoute NO fue adoptado (sin condición Accepted del controller de Gateway API)"
  inf "todo su status es: $(ocd -n "$NS_DST" get httproute "$ROUTE" -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}={.status} {end}{end}' 2>/dev/null)"
  inf "revisar que parentRefs apunte a '$GW' y sectionName a '$LISTENER', y que el listener"
  inf "acepte routes de este namespace (allowedRoutes.namespaces.from: Same)."
  cortar
fi

RR=$(ocd -n "$NS_DST" get httproute "$ROUTE" \
     -o jsonpath='{range .status.parents[*]}{range .conditions[?(@.type=="ResolvedRefs")]}{.status}{end}{end}' 2>/dev/null)
[[ "$RR" == *"True"* ]] && ok "ResolvedRefs=True" \
                        || { err "ResolvedRefs=$RR — el backendRef backend:8080 no resuelve"; cortar; }

# ─────────────────────────────────────────────────── R5. la AuthPolicy, recién ahora
paso "R5. AuthPolicy $POLICY"
CMK=$(ocd -n "$NS_DST" get cm jwks-egress-origen -o jsonpath='{.data.jwks\.json}' 2>/dev/null | jq -r '.keys[0] | "\(.kid) \(.kty)"' 2>/dev/null)
if [[ -z "$CMK" ]]; then
  err "falta el ConfigMap jwks-egress-origen — crearlo desde ../keys/out/jwks.json"
  cortar
fi
ok "JWKS pineado: $CMK"
[[ "$CMK" == *"RSA"* ]] || adv "el JWKS no es RSA: Authorino sólo verifica RS256 y va a rechazar TODOS los tokens"

READY=$(ocd -n "$NS_DST" get pod -l app=jwks-egress -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null)
[[ "$READY" == *Running* ]] && ok "server de JWKS Running" || { err "el server de JWKS no está Running ($READY)"; cortar; }

# Recrear la policy es lo que fuerza a Authorino a re-leer el JWKS —cachea el fetch,
# incluso el fallido— y a Kuadrant a reconstruir la topología con el HTTPRoute ya adoptado.
inf "recreando la AuthPolicy para forzar el refresh del AuthConfig"
ocd -n "$NS_DST" delete authpolicy "$POLICY" >/dev/null 2>&1
sleep 3
ocd apply -f "$DIR/25-authpolicy-jwt.yaml" >/dev/null 2>&1 || { err "falló el apply de 25-authpolicy-jwt.yaml"; cortar; }

for _ in $(seq 1 20); do
  E=$(ocd -n "$NS_DST" get authpolicy "$POLICY" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
  [[ "$E" == "True" ]] && break; sleep 3
done
if [[ "${E:-}" == "True" ]]; then
  ok "Enforced=True"
else
  err "no llegó a Enforced (=${E:-vacío})"
  inf "motivo: $(ocd -n "$NS_DST" get authpolicy "$POLICY" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  AUTH=$(ocd -n kuadrant-system get deploy -o name 2>/dev/null | grep -i authorino | head -1)
  ocd -n kuadrant-system logs "$AUTH" --since=3m 2>/dev/null \
    | grep -iE 'jwks|invalid|verif|unauthenticated|failed|error' | tail -10 | sed 's/^/     /'
  cortar
fi

# ─────────────────────────────────────────────────── R6. el gate de punta a punta
paso "R6. Gate del destino, desde afuera del cluster"
SUBJ=$(openssl s_client -connect "$DST_IP:443" -servername "$FQDN" </dev/null 2>/dev/null \
       | openssl x509 -noout -subject 2>/dev/null)
if grep -qF "paas-demo" <<<"$SUBJ"; then
  ok "el SNI eligió el gateway del destino — $SUBJ"
else
  err "el certificado que presenta $DST_IP no es el del gateway: ${SUBJ:-(sin respuesta)}"
  inf "el SNI no matcheó ninguna Route de passthrough: revisar 22-route-passthrough.yaml"
  inf "  oc -n $NS_DST get route app2-egress-passthrough -o jsonpath='{.status.ingress[*].conditions[*].reason}{\"\\n\"}'"
  cortar
fi

ST=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
     --resolve "$FQDN:443:$DST_IP" -H "Host: $HOST_INTERNO" "https://$FQDN/" 2>/dev/null)
case "$ST" in
  401) ok "GET sin token -> 401 — el destino enforcea (prueba negativa (a) del README §7.4)" ;;
  200) err "GET sin token -> 200: el destino CONTESTA SIN EXIGIR TOKEN"; cortar ;;
  503) err "GET sin token -> 503: es del router, no del destino (Route sin endpoints)"; cortar ;;
  *)   err "GET sin token -> ${ST:-sin respuesta}"; cortar ;;
esac

printf '\n%sLa cadena está entera. Seguir con la batería:%s\n' "$B" "$Z"
inf "cd ../sim-destino && CTX_DST=${CTX_DST:-<ctx>} NS_SIM=$NS_DST GW_DST=$GW DST_IP=$DST_IP SITE=dev1-lowmz ./run-escenarios.sh"
