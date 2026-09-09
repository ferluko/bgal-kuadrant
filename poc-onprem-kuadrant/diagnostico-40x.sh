#!/usr/bin/env bash
# diagnostico-40x.sh — aísla de dónde sale un 40x en la cadena bff -> backend (paas-lab -> arqlab).
#
# La cadena tiene CINCO puntos que pueden devolver 4xx, y cada uno se arregla en un lado distinto:
#
#   bff ─► Service backend ─► egress-gw (AuthPolicy mintea) ─► TLS ─► router arqlab
#          (selector)          │ 403 si el mint falla          │      │ 404/503 si el SNI no matchea
#                              │                               │      ▼
#                              └─ 404 si el HTTPRoute de origen no matchea el Host
#                                                             ingress-gw-lab
#                                                             │ 404 si el Host no matchea el HTTPRoute
#                                                             │ 401 si el token no valida  (authn)
#                                                             │ 403 si los claims no pasan (authz)
#                                                             ▼
#                                                           backend
#
# El truco central: las AuthPolicy del destino devuelven MENSAJES DISTINTOS para 401 y 403
# ("falta o es invalido el token…" vs "no corresponde a un consumidor habilitado"). El cuerpo de
# la respuesta dice, solo, cuál de los dos falló. Este script lo lee y ramifica.
#
#   CTX_ORI=paas-lab CTX_DST=paas-arqlab ./diagnostico-40x.sh
#
# Solo lectura. No aplica ni reinicia nada (te dice cuándo hace falta).
set -uo pipefail

CTX_ORI="${CTX_ORI:-paas-lab}"
CTX_DST="${CTX_DST:-paas-arqlab}"
NS="${NS:-poc-egress-kuadrant}"
NS_DST="${NS_DST:-poc-ingress-kuadrant}"
NS_KUA="${NS_KUA:-kuadrant-system}"
URL_INT="${URL_INT:-http://backend.poc-egress-kuadrant.svc.cluster.local:8080}"
SPIFFE_ROLE="${SPIFFE_ROLE:-egress-gw-paas-lab}"
VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200}"
VAULT_NS="${VAULT_NS:-admin/spiffe}"
SECRET_TOK="${SECRET_TOK:-vault-egress-token-ocp}"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; D=$'\e[2m'; Z=$'\e[0m'
else B=; G=; R=; A=; D=; Z=; fi
sec()  { printf '\n%s══ %s ══%s\n' "$B" "$*" "$Z"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$Z" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$A" "$Z" "$*"; }
n()    { printf '    %s%s%s\n' "$D" "$*" "$Z"; }
oco()  { oc --context="$CTX_ORI" "$@" 2>/dev/null; }
ocd()  { oc --context="$CTX_DST" "$@" 2>/dev/null; }

# Ejecuta python DENTRO del pod bff. Es el único lugar desde donde el camino es el real:
# misma ClusterIP, mismo Service, misma política de egreso.
enbff() { oco -n "$NS" exec -i deploy/bff -- python3 - "$@"; }

sec "1. El request real, crudo — qué devuelve y QUIÉN lo devuelve"
RAW=$(enbff "$URL_INT" <<'PY' 2>&1
import json,sys,urllib.request,urllib.error
url=sys.argv[1]
req=urllib.request.Request(url)
try:
    r=urllib.request.urlopen(req,timeout=15)
    print(json.dumps({"status":r.status,"headers":dict(r.headers),"body":r.read().decode('utf-8','replace')[:4000]}))
except urllib.error.HTTPError as e:
    print(json.dumps({"status":e.code,"headers":dict(e.headers or {}),"body":e.read().decode('utf-8','replace')[:4000]}))
except Exception as e:
    print(json.dumps({"error":"%s: %s"%(type(e).__name__,e)}))
PY
)
printf '%s\n' "$RAW" | python3 -c '
import json,sys
d=sys.stdin.read()
try: j=json.loads(d)
except Exception: print("  salida no-JSON:\n"+d[:800]); raise SystemExit
if "error" in j: print("  ERROR DE RED (no hubo respuesta HTTP): %s"%j["error"]); raise SystemExit
print("  status  : %s"%j["status"])
h={k.lower():v for k,v in j["headers"].items()}
for k in ("server","x-envoy-upstream-service-time","x-ext-auth-reason","www-authenticate","content-type"):
    if k in h: print("  %-32s %s"%(k+":",h[k]))
print("  body    : %s"%j["body"][:600].replace("\n"," "))
' || true

echo
n "LECTURA — MIRAR PRIMERO x-ext-auth-reason: lo pone Envoy con el motivo EXACTO del ext_authz."
n "  'no such key: data'  -> ORIGEN. Vault no devolvió {data:{token}}: respondió un error."
n "                          Casi siempre X-Vault-Token vacío/vencido => Authorino tiene un valor"
n "                          stale del Secret leído por sharedSecretRef. Ver punto 9."
n "  ausente + 401/403    -> el rechazo es del DESTINO; leer el body (mensajes de abajo)."
n "  ausente + 500 'Internal Server Error.' de istio-envoy"
n "                       -> NO es un deny: la llamada al ext_authz FALLO (UNAVAILABLE)."
n "                          Causa medida: el mint a Vault tarda ~160 ms y el ext_authz de"
n "                          Kuadrant corta a 200ms FIJOS. Pasa en cada cache-miss (ttl 250s)."
n "                          Se confirma con el loop del punto 11."
n ""
n "LECTURA DEL BODY — cada mensaje apunta a un lado distinto:"
n "  'falta o es invalido el token de egreso'      -> 401 AUTHN en el DESTINO: firma/parseo/JWKS"
n "  'no corresponde a un consumidor habilitado'   -> 403 AUTHZ en el DESTINO: claims (aud/sub/iss)"
n "  body vacío + server: envoy + 404              -> ningún HTTPRoute matcheó el Host"
n "  'Application is not available' / HTML         -> contestó el ROUTER de OpenShift, no el gateway"
n "  403 sin mensaje de los de arriba              -> AUTHZ en el ORIGEN: el mint de Vault falló"

sec "2. ¿La app está sana? (saltea toda la malla)"
enbff <<'PY' 2>&1 | sed 's/^/  /'
import json,urllib.request,urllib.error
for u in ("http://backend-local.poc-egress-kuadrant.svc.cluster.local:8080/",
          "http://backend.poc-egress-kuadrant.svc.cluster.local:8080/healthz"):
    try:
        r=urllib.request.urlopen(u,timeout=8); print("%-70s %s"%(u,r.status))
    except urllib.error.HTTPError as e: print("%-70s %s"%(u,e.code))
    except Exception as e: print("%-70s %s"%(u,type(e).__name__))
PY
n "backend-local OK y backend 40x => el problema es el camino, no la app."

sec "3. ¿A quién apunta el Service backend? (¿hubo cutover?)"
SEL=$(oco -n "$NS" get svc backend -o jsonpath='{.spec.selector}')
echo "  selector : $SEL"
oco -n "$NS" get endpoints backend -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" -> "}{.targetRef.name}{"\n"}{end}' | sed 's/^/  /'
case "$SEL" in
  *gateway*) ok "post-cutover: los endpoints son el gateway de egreso" ;;
  *) warn "PRE-cutover: el Service apunta a los pods locales, el tráfico NI SALE del cluster."
     n "Si igual ves 40x, viene del backend local, no del cruce." ;;
esac

sec "4. El token que se está minteando AHORA — aud/sub/iss reales"
TOK=$(oco -n "$NS_KUA" get secret "$SECRET_TOK" -o jsonpath='{.data.client_token}' | base64 -d 2>/dev/null)
AUD_POL=$(oco -n "$NS" get authpolicy egress-backend-vault-spiffe -o jsonpath='{.spec.rules.metadata.vault_mint.http.body.expression}' 2>/dev/null)
CKEY=$(oco -n "$NS" get authpolicy egress-backend-vault-spiffe -o jsonpath='{.spec.rules.metadata.vault_mint.cache.key.expression}' 2>/dev/null)
echo "  audiencia configurada en la AuthPolicy : $AUD_POL"
echo "  cache.key                              : $CKEY"
if [ -z "$TOK" ]; then
  bad "no pude leer el Secret $SECRET_TOK — sin eso no puedo mintear de prueba"
else
  IMG=$(oco -n "$NS_KUA" get cronjob -o jsonpath='{.items[0].spec.jobTemplate.spec.template.spec.containers[0].image}')
  AUD=$(printf '%s' "$AUD_POL" | grep -o '[a-z0-9.-]*\.bancogalicia\.com\.ar' | head -1)
  oc --context="$CTX_ORI" run diag40x-$$ -n "$NS_KUA" --rm -i --restart=Never --quiet \
     --image="${IMG:-alpine/k8s:1.30.0}" --request-timeout=120s \
     --env="T=$TOK" --overrides='{"spec":{"serviceAccountName":"authorino-authorino"}}' \
     -- sh -c "
      b64(){ tr '_-' '/+' | awk '{n=length(\$0)%4; if(n==2)\$0=\$0\"==\"; else if(n==3)\$0=\$0\"=\"; print}' | base64 -d 2>/dev/null; }
      M=\$(curl -sS --max-time 15 -X POST '$VAULT_ADDR/v1/spiffe/role/$SPIFFE_ROLE/mintjwt' \
            -H 'X-Vault-Namespace: $VAULT_NS' -H \"X-Vault-Token: \$T\" -d '{\"audience\": \"$AUD\"}')
      echo \"\$M\" | grep -q '\"errors\"' && { echo \"MINT_ERROR=\$M\"; exit 0; }
      J=\$(echo \"\$M\" | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
      echo 'CLAIMS DEL TOKEN QUE VIAJA:'
      printf %s \"\$J\" | cut -d. -f2 | b64
     " 2>&1 | sed 's/^/  /'
fi

sec "5. Lo que el DESTINO exige — comparar campo por campo con el punto 4"
ocd -n "$NS_DST" get authpolicy -o custom-columns='NOMBRE:.metadata.name,TARGET:.spec.targetRef.name,ACC:.status.conditions[?(@.type=="Accepted")].status,ENF:.status.conditions[?(@.type=="Enforced")].status' --no-headers | sed 's/^/  /'
echo
ocd -n "$NS_DST" get authpolicy backend-lab-vault-spiffe -o json 2>/dev/null \
  | jq -r '.spec.rules.authorization[]?.patternMatching.patterns[]?.predicate' 2>/dev/null | sed 's/^/  /'
echo "  header que espera: $(ocd -n "$NS_DST" get authpolicy backend-lab-vault-spiffe -o jsonpath='{.spec.rules.authentication.*.credentials.customHeader.name}' 2>/dev/null)"
echo "  jwksUrl          : $(ocd -n "$NS_DST" get authpolicy backend-lab-vault-spiffe -o jsonpath='{.spec.rules.authentication.*.jwt.jwksUrl}' 2>/dev/null)"
echo "  hostname del HTTPRoute destino: $(ocd -n "$NS_DST" get httproute backend-lab -o jsonpath='{.spec.hostnames[*]}' 2>/dev/null)"
n "El Host que MANDA el origen es 'backend.poc-egress-kuadrant.svc.cluster.local:8080' — CON puerto."
n "Si el 40x es 404 del gateway destino, ese es el primer sospechoso."

sec "6. Logs de Authorino — ORIGEN (¿falló el mint?)"
oco -n "$NS_KUA" logs --tail=40 deploy/authorino 2>/dev/null \
  | grep -i 'denied\|error\|no such key\|vault\|unauthor' | tail -12 | sed 's/^/  /' || n "sin líneas relevantes"
n "'no such key: data' = Authorino mandó el X-Vault-Token vacío (estado stale)."
n "Fix conocido: oc --context=$CTX_ORI -n $NS_KUA rollout restart deployment authorino"

sec "7. Logs de Authorino — DESTINO (¿llegó el request?)"
# OJO: en arqlab el MISMO Authorino atiende su rol de ORIGEN (poc-egress-kuadrant, hacia EKS) y
# el de DESTINO (poc-ingress-kuadrant, recibe a paas-lab). Sin filtrar se ven los de origen y uno
# cree que son del cruce. El discriminante: el destino ve el FQDN interno del ORIGEN paas-lab.
ocd -n "$NS_KUA" logs --tail=300 deploy/authorino 2>/dev/null \
  | grep 'backend\.poc-egress-kuadrant\.svc\.cluster\.local' \
  | grep -o '"ts":"[^"]*"\|"authorized":[a-z]*\|"message":"[^"]*"' | paste -d' ' - - - 2>/dev/null \
  | tail -8 | sed 's/^/  /' || n "sin líneas del cruce"
n "SIN NINGUNA LÍNEA = Authorino del destino NUNCA vio el request: el 40x es del gateway o del"
n "router, no de la autorización. Mirar el punto 5 (hostname) y el estado del listener."

sec "9. Si fue 'no such key: data' — el token de sesión de Vault"
SEC_TS=$(oco -n "$NS_KUA" get secret "$SECRET_TOK" -o jsonpath='{.metadata.creationTimestamp}')
POD_TS=$(oco -n "$NS_KUA" get pods -l authorino-resource -o jsonpath='{.items[0].metadata.creationTimestamp}')
echo "  Secret $SECRET_TOK creado : ${SEC_TS:-?}"
echo "  pod de Authorino creado   : ${POD_TS:-?}"
n "SI EL POD ES MÁS VIEJO QUE EL SECRET, es el caso: Authorino se quedó con el valor que leyó al"
n "arrancar, y el CronJob ya rotó el token (cada 30 min; TTL del token = 1h)."
echo
echo "  ¿el token del Secret sirve HOY? (si esto da 200, el token está bien y el problema es Authorino)"
if [ -n "${TOK:-}" ]; then
  IMG2=$(oco -n "$NS_KUA" get cronjob -o jsonpath="{.items[0].spec.jobTemplate.spec.template.spec.containers[0].image}")
  OV='{"spec":{"serviceAccountName":"authorino-authorino"}}'
  oc --context="$CTX_ORI" run diag40xtok-$$ -n "$NS_KUA" --rm -i --restart=Never --quiet \
     --image="${IMG2:-alpine/k8s:1.30.0}" --request-timeout=90s --env="T=$TOK" \
     --overrides="$OV" \
     -- sh -c 'curl -sS --max-time 15 -X POST "'"$VAULT_ADDR"'/v1/spiffe/role/'"$SPIFFE_ROLE"'/mintjwt" \
        -H "X-Vault-Namespace: '"$VAULT_NS"'" -H "X-Vault-Token: $T" -d "{\"audience\": \"probe\"}" \
        | head -c 300' 2>&1 | sed "s/^/  /"
  echo
  n "Si eso trae un token => el Secret está bien y el problema es la copia que tiene Authorino."
  n "Si trae 'permission denied / invalid token' => el token del Secret venció: mirar el CronJob."
fi
echo
n "FIX INMEDIATO (band-aid conocido, ya usado en arqlab):"
n "  oc --context=$CTX_ORI -n $NS_KUA rollout restart deployment authorino"
n "  oc --context=$CTX_ORI -n $NS_KUA rollout status deployment authorino"
n "PERO OJO: si el pod vuelve a quedarse con un token fijo, esto REAPARECE cuando ese token"
n "vence (1h). Para saber si es un time bomb y no un incidente puntual: reiniciar, confirmar"
n "que anda, y volver a probar 70-80 min después SIN tocar nada. Si vuelve el 403, el diseño"
n "necesita que Authorino relea el Secret, no reinicios."

sec "11. Loop de 10 requests — distingue timeout de rechazo"
n "Un ext_authz que se pasa de los 200ms falla SOLO en el cache-miss. El patrón es inconfundible:"
n "la primera falla y las siguientes andan, y vuelve a fallar ~250s después."
enbff <<'PYLOOP' 2>&1 | sed 's/^/  /'
import json,time,urllib.request,urllib.error
u="http://backend.poc-egress-kuadrant.svc.cluster.local:8080/"
for i in range(1,11):
    t=time.time()
    try:
        r=urllib.request.urlopen(u,timeout=20); code=str(r.status); b=r.read()
        try: pod=json.loads(b).get("environment",{}).get("HOSTNAME","?")
        except Exception: pod="?"
    except urllib.error.HTTPError as e: code=str(e.code); pod="-"
    except Exception as e: code=type(e).__name__; pod="-"
    print("%2d  %-22s %6.0f ms   pod=%s"%(i,code,(time.time()-t)*1000,pod))
    time.sleep(1)
PYLOOP
n "TODAS 200            -> el camino funciona; el 500 anterior fue el cache-miss."
n "1 falla + 9 en 200   -> confirmado: timeout del ext_authz en el mint. Ver el doc 16."
n "TODAS fallan igual   -> no es timing: mirar el punto 1 y el estado del destino."

sec "12. La trampa del cache — leer si cambiaste la audiencia hace poco"
n "La AuthPolicy cachea el JWT-SVID con cache.key constante y ttl 250s. Si cambiaste la audiencia"
n "(o el role de Vault), Authorino sigue sirviendo el token VIEJO hasta 250s, y el destino lo"
n "rechaza por 'aud'. Un 403 que aparece con retraso y se arregla solo es exactamente esto."
n "Para descartarlo YA:"
n "  oc --context=$CTX_ORI -n $NS_KUA rollout restart deployment authorino"
n "  oc --context=$CTX_ORI -n $NS_KUA rollout status deployment authorino"
n "  ...y repetir el punto 1."
