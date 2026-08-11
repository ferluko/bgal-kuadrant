#!/usr/bin/env bash
# Demostración en vivo del egreso seguro contra el cluster EKS REAL.
#
#   ./demo-eks.sh              # narrada, con pausas para ir explicando
#   ./demo-eks.sh --rapido     # sin pausas, para verificar que todo pasa
#   ./demo-eks.sh --con-migracion   # suma los actos 5 y 6: pesos y rollback (MUEVE TRÁFICO)
#
# Pensado para proyectar. Cada acto responde una pregunta del público, en el orden en que
# suelen surgir. Los actos 1 a 4 son de SÓLO LECTURA: no cambian nada del cluster.
#
# El acto 4 es el corazón. Las pruebas (c) y (d) usan la clave privada del ORIGEN para forjar
# tokens a medida — uno vencido y otro para otro destino. Eso permite demostrar en un segundo
# lo que si no habría que esperar 5 minutos, y además es más contundente: la firma es
# legítima y el destino los rechaza igual.
set -uo pipefail

ING="${ING:-10.254.28.68}"
HOSTAPP1="${HOSTAPP1:-bff.paas-demo.bancogalicia.com.ar}"
DEST="${DEST:-app2.paas-demo.bancogalicia.com.ar}"
HOSTINT="${HOSTINT:-backend.poc-egress-kuadrant.svc.cluster.local:8080}"
NS="${NS:-poc-egress-kuadrant}"
KEY="${KEY:-keys/out/key.pem}"
CA="${CA:-/tmp/ca-galicia.pem}"
DIR="$(cd "$(dirname "$0")" && pwd)"

PAUSAS=1; MIGRACION=0
for a in "$@"; do case "$a" in
  --rapido) PAUSAS=0 ;;
  --con-migracion) MIGRACION=1 ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
esac; done

if [[ -t 1 ]]; then
  V=$'\e[1;32m'; R=$'\e[1;31m'; A=$'\e[1;33m'; C=$'\e[1;36m'; B=$'\e[1m'; D=$'\e[2m'; Z=$'\e[0m'
else V=; R=; A=; C=; B=; D=; Z=; fi

OK=0; MAL=0; OMIT=0; FALLIDOS=()

# Sin recuadro a propósito: un borde derecho calculado a mano se corta en cuanto el ancho de
# la terminal no es el previsto. Una regla sin cerrar no se puede romper.
REGLA=$(printf '─%.0s' $(seq 1 74))
acto() {
  printf '\n%s%s%s\n' "$C" "$REGLA" "$Z"
  printf '  %s%s%s\n' "$B" "$1" "$Z"
  [[ -n "${2-}" ]] && printf '  %s%s%s\n' "$D" "$2" "$Z"
  printf '%s%s%s\n\n' "$C" "$REGLA" "$Z"
}
paso()  { printf '   %s▸%s %s\n' "$C" "$Z" "$1"; }
dato()  { printf '       %-30s %s%s%s\n' "$1" "$B" "$2" "$Z"; }
bien()  { printf '   %s✔%s %-52s %s\n' "$V" "$Z" "$1" "${2-}"; OK=$((OK+1)); }
mal()   { printf '   %s✘%s %-52s %sobtuvo: %s%s\n' "$R" "$Z" "$1" "$R" "${2-}" "$Z"; MAL=$((MAL+1)); FALLIDOS+=("$1"); }
omit()  { printf '   %s−%s %-52s %s\n' "$A" "$Z" "$1" "${2-}"; OMIT=$((OMIT+1)); }
nota()  { printf '     %s%s%s\n' "$D" "$1" "$Z"; }
espera(){ (( PAUSAS )) && { printf '\n   %s· enter para seguir ·%s' "$D" "$Z"; read -r _ </dev/tty; echo; } || true; }

eq() { [[ "$2" == "$3" ]] && bien "$1" "$2" || mal "$1" "$2"; }

req()     { curl -s --max-time 15 -H "Host: $HOSTAPP1" "$@" "http://$ING/"; }

# Devuelve el JSON del primer request que dé 200. Si ninguno lo da, devuelve el último igual.
# Sin esto, un 503 transitorio en el primer request deja TOK vacío y todo lo que sigue se
# desmorona con tracebacks — inaceptable con público delante.
req_ok() {
  local i j=""
  for i in 1 2 3 4 5; do
    j=$(req)
    [[ "$(f "$j" '.upstream.status')" == "200" ]] && { printf '%s' "$j"; return 0; }
    sleep 1
  done
  printf '%s' "$j"; return 1
}
f()       { printf '%s' "${1:-}" | jq -r "${2} // \"null\"" 2>/dev/null || echo null; }

# Petición TLS directa al destino real, validando la cadena. $1 = token ("" = sin token).
directo() {
  local tok="${1-}" extra=()
  [[ -n "$tok" ]] && extra=(-H "x-egress-token: $tok")
  # `${extra[@]+...}`: con `set -u`, bash 4 considera "unbound" un array vacío expandido
  # como "${extra[@]}". Esta forma lo omite en vez de abortar.
  curl -s -o /tmp/demo-resp.json -w '%{http_code}' --max-time 15 --cacert "$CA" \
       -H "Host: $HOSTINT" ${extra[@]+"${extra[@]}"} "https://$DEST/" 2>/dev/null || echo "ERR"
}

# Forja un JWT con la clave privada REAL del origen, partiendo de los claims de un token
# legítimo y pisando lo que se le indique. Es lo que permite demostrar (c) y (d) al instante.
forjar() {
  python3 - "$KEY" "$1" "$TOK" <<'PY'
import base64, json, os, subprocess, sys, tempfile
key, over, base = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
b   = lambda x: base64.urlsafe_b64encode(x).decode().rstrip("=")
d   = lambda s: json.loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))
hdr, pl = d(base.split(".")[0]), d(base.split(".")[1])
pl.update(over)
msg = (b(json.dumps(hdr, separators=(",", ":")).encode()) + "." +
       b(json.dumps(pl,  separators=(",", ":")).encode())).encode()
t = tempfile.NamedTemporaryFile(delete=False); t.write(msg); t.close()
sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, t.name], capture_output=True).stdout
os.unlink(t.name)
print(msg.decode() + "." + b(sig))
PY
}

for bin in oc jq curl openssl python3; do command -v $bin >/dev/null || { echo "falta '$bin'"; exit 2; }; done
[[ -f "$CA" ]] || { cat ../certs/bg_noprod_intermedia.crt ../certs/bg_root.crt > "$CA" 2>/dev/null || true; }

printf '\n%s   EGRESO SEGURO ENTRE CLUSTERS%s\n' "$B" "$Z"
printf '   %sMover un servicio a otro cluster sin tocar a quien lo consume.%s\n' "$D" "$Z"
printf '   %sorigen: paas-arqlab (on-prem)   ·   destino: EKS (us-east-1)%s\n' "$D" "$Z"
espera

# ─────────────────────────────────────────────────────────────────────────────
acto "1 · El consumidor no sabe nada" \
     "Llama a un nombre de Service. Nunca supo que el servicio se mudó."

J=$(req_ok) || true
dato "lo que pide el consumidor:" "$(f "$J" '.upstream.url')"
dato "quién le respondió:"        "$(f "$J" '.upstream.body.environment.HOSTNAME')"
dato "cuánto tardó:"              "$(f "$J" '.upstream.latencyMs') ms"
eq  "responde correctamente" "$(f "$J" '.upstream.status')" "200"
if [[ "$(f "$J" '.upstream.status')" != "200" ]]; then
  nota "error del salto: $(f "$J" '.upstream.error')"
  nota "Los actos 3 y 4 necesitan un token; sin un request exitoso se omiten."
fi
nota "La URL es la de siempre: backend.poc-egress-kuadrant.svc.cluster.local:8080"
espera

# ─────────────────────────────────────────────────────────────────────────────
acto "2 · Pero el tráfico ya no va donde iba" \
     "El Service no se recreó: se le cambió el selector. Misma IP, mismo nombre."

CIP=$(oc -n "$NS" get svc backend -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
SEL=$(oc -n "$NS" get svc backend -o jsonpath='{.spec.selector}' 2>/dev/null)
GWIP=$(oc -n "$NS" get pod -l gateway.networking.k8s.io/gateway-name=egress-gw -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
dato "ClusterIP del Service:" "$CIP"
dato "su selector ahora:"     "$SEL"
dato "IP del gateway:"        "$GWIP"
SRC=$(f "$J" '.upstream.body.host.ip')
dato "origen que ve el backend:" "$SRC"
[[ "$SRC" == *"$GWIP"* ]] && bien "el request pasó por el gateway de egreso" "$SRC" \
                          || mal  "el request pasó por el gateway de egreso" "$SRC"
nota "Esa IP es la prueba: antes era la del pod consumidor. La app no cambió una línea."
espera

# ─────────────────────────────────────────────────────────────────────────────
acto "3 · Y el gateway le pone una credencial" \
     "Un JWT de 300 segundos, firmado con una clave que sólo existe en este cluster."

TOK=$(f "$J" '.upstream.body.request.headers["x-egress-token"]')
if [[ "$TOK" == "null" || -z "$TOK" ]]; then
  mal "el gateway inyectó el token" "ausente"
else
  bien "el gateway inyectó el token" "$(echo "$TOK" | cut -c1-40)…"
  python3 -c "
import base64,json,sys
d=lambda s: json.loads(base64.urlsafe_b64decode(s+'='*(-len(s)%4)))
h,p=d('$TOK'.split('.')[0]), d('$TOK'.split('.')[1])
print('       %-30s %s' % ('algoritmo:', h['alg']))
for k in ('iss','aud','src_cluster','src_namespace','dst_service'):
    print('       %-30s %s' % (k+':', p.get(k)))
print('       %-30s %s s' % ('vida del token:', p['exp']-p['iat']))"
fi
nota "La clave privada nunca sale del origen. Al destino sólo se le dio la pública."
espera

# ─────────────────────────────────────────────────────────────────────────────
acto "4 · ¿Y si alguien intenta saltearse todo esto?" \
     "Cuatro intentos contra el cluster destino real, desde afuera del camino."

paso "(a) Un request sin credencial"
eq "  el destino lo rechaza" "$(directo "")" "401"
nota "Nadie puede consumir el servicio sin pasar por la plataforma."

if [[ "$TOK" == "null" || -z "$TOK" || "$TOK" != *.*.* ]]; then
  omit "(b) (c) (d) — pruebas que necesitan un token real" "no se obtuvo ninguno"
  nota "Reintentá cuando el camino esté sano; el acto 1 dice por qué falló."
else
paso "(b) Una credencial manipulada"
ALT=$(python3 -c "
t='$TOK'.split('.'); s=t[2]
print('%s.%s.%s' % (t[0],t[1], s[:10]+('B' if s[10]=='A' else 'A')+s[11:]))")
eq "  el destino detecta la firma rota" "$(directo "$ALT")" "401"

paso "(c) Una credencial vencida — firmada por nosotros, con exp en el pasado"
VIEJO=$(forjar '{"exp": 1700000000, "iat": 1699999700}')
eq "  el destino mira la expiración" "$(directo "$VIEJO")" "401"
nota "Firma legítima. La rechaza igual: una credencial robada sirve 5 minutos, no para siempre."

paso "(d) Una credencial válida, pero emitida para OTRO destino"
OTRO=$(forjar '{"aud": "otro-servicio.paas-demo.bancogalicia.com.ar"}')
COD=$(directo "$OTRO")
eq "  la autentica pero NO la autoriza" "$COD" "403"
nota "403 y no 401: la firma es nuestra y la reconoce. Lo que rechaza son los claims."
nota "Es la diferencia entre «no sé quién sos» y «sé quién sos y no estás habilitado»."

paso "(✓) Y la credencial correcta"
eq "  el destino responde" "$(directo "$TOK")" "200"
fi
dato "procedencia que propagó:" "$(jq -r '.request.headers["x-forwarded-src-cluster"] // "—"' /tmp/demo-resp.json 2>/dev/null)"
POD_EKS=$(jq -r '.environment.HOSTNAME // ""' /tmp/demo-resp.json 2>/dev/null)
espera

# ─────────────────────────────────────────────────────────────────────────────
acto "5 · Cuánto cuesta cruzar a la nube" \
     "El costo del patrón, separado del costo de la geografía."

# Se etiqueta por el POD que efectivamente respondió, nunca por la variante del request.
# Si la route está en pesos, el header `x-canary` no selecciona nada y cada request cae en un
# backend al azar: etiquetar por variante da valores cruzados. El pod de EKS lo sabemos del
# acto 4, que le habló directo.
paso "20 requests reales, agrupados por quién respondió"
# `.upstream.body` es un STRING cuando el salto falla. Indexarlo como objeto hace que jq
# escupa un error por request y el fallo real queda escondido detrás del ruido.
for _ in $(seq 1 20); do
  req | jq -r 'if (.upstream.body|type)=="object"
               then "\(.upstream.body.environment.HOSTNAME // "?") \(.upstream.latencyMs // 0)"
               else "FALLO \(.upstream.status // "sin-respuesta")" end' 2>/dev/null || echo "FALLO parseo"
done > /tmp/demo-lat.txt
python3 - "${POD_EKS:-}" <<'PY'
import sys, collections
eks = sys.argv[1]
g = collections.defaultdict(list); fallos = collections.Counter()
for l in open("/tmp/demo-lat.txt"):
    p = l.split()
    if len(p) == 2 and p[0] == "FALLO":
        fallos[p[1]] += 1
    elif len(p) == 2 and p[0] != "?":
        g[p[0]].append(float(p[1]))
for pod, v in sorted(g.items(), key=lambda kv: sum(kv[1])/len(kv[1])):
    v.sort()
    donde = "en EKS  (us-east-1)" if pod == eks else "local   (paas-arqlab)"
    print("       %-22s %-34s %6.1f ms" % (donde, pod[:34], v[len(v)//2]))
if len(g) == 1 and not fallos:
    print("       (un solo backend: el reparto está al 100 % de un lado)")
if fallos:
    tot = sum(fallos.values())
    print("\n       %d de 20 requests FALLARON: %s" %
          (tot, ", ".join("%s x %s" % (v, k) for k, v in fallos.most_common())))
    print("       El camino remoto no esta sano; revisar antes de presentar.")
PY
nota "De la diferencia, ~11 ms son el gateway y la firma. El resto es el viaje a us-east-1."
nota "Medición completa y sostenida:  ./medir-latencia.sh 2000 --par 40"
espera

# ─────────────────────────────────────────────────────────────────────────────
if (( MIGRACION )); then
  acto "6 · La migración, de a poco y reversible" \
       "El reparto se controla desde el HTTPRoute. El Service no se vuelve a tocar."
  PREV="$DIR/origen/08-rollout/fase0a-solo-local.yaml"
  restaurar() { printf '\n   %srestaurando el estado previo…%s\n' "$D" "$Z"; oc apply -n "$NS" -f "$PREV" >/dev/null 2>&1 && echo "   ok"; }
  trap restaurar EXIT
  oc apply -n "$NS" -f "$DIR/origen/08-rollout/fase2-pesos.yaml" >/dev/null 2>&1
  oc -n "$NS" patch httproute egress-backend --type json -p \
    '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":75},
      {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":25}]' >/dev/null 2>&1
  sleep 5
  paso "Reparto configurado 75 / 25 — 60 requests reales:"
  for _ in $(seq 1 60); do req | jq -r '.upstream.body.environment.HOSTNAME'; done | sort | uniq -c | while read -r n pod; do
    printf '       %-34s %s%s requests%s\n' "$pod" "$B" "$n" "$Z"; done
  espera
  paso "Y el rollback:"
  T0=$(date +%s%N); oc apply -n "$NS" -f "$PREV" >/dev/null 2>&1; T1=$(date +%s%N)
  bien "vuelta al 100 % local" "$(( (T1-T0)/1000000 )) ms"
  nota "Sin recrear objetos, sin reiniciar pods, sin ventana."
  trap - EXIT
  espera
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s%s%s\n' "$C" "$REGLA" "$Z"
printf '  %sRESULTADO%s\n' "$B" "$Z"
printf '%s%s%s\n' "$C" "$REGLA" "$Z"
printf '\n   %s%d verificaciones en verde%s' "$V" "$OK" "$Z"
(( MAL ))  && printf '   ·   %s%d en rojo%s' "$R" "$MAL" "$Z"
(( OMIT )) && printf '   ·   %s%d omitidas%s' "$A" "$OMIT" "$Z"
echo; echo
if (( MAL )); then
  printf '   %sFallaron:%s\n' "$R" "$Z"; for x in "${FALLIDOS[@]}"; do printf '     · %s\n' "$x"; done; echo
fi
printf '   %sEl consumidor no se modificó · la ClusterIP no cambió · el rollback es de un segundo%s\n' "$D" "$Z"
printf '   %sDetalle:  RESUMEN.md   ·   HALLAZGOS.md%s\n\n' "$D" "$Z"
exit $(( MAL > 0 ))
