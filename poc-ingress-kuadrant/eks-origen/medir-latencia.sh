#!/usr/bin/env bash
# Copia adaptada de poc-egress-kuadrant/medir-latencia.sh para el sentido
# EKS -> OCP. Misma lógica de medición (percentiles, agrupado por pod que
# atendió, delta entre backends); diferencias de fondo:
#
#   1. `bff` acá es ClusterIP (no expuesto afuera), así que no se puede pegar
#      con curl local desde el bastión como hace el script original.
#
#   2. TODO el loop de concurrencia corre DENTRO del pod runner, con UN SOLO
#      `kubectl exec` (no uno por request). Verificado en vivo (2026-08-14):
#      con un exec por request, 40 reqs --par 5 tardaban 1m21s reales para
#      ~46s de trabajo efectivo — el overhead de abrir sesión (API server ->
#      kubelet -> contenedor) por cada request domina todo, no la red ni el
#      camino real (los contadores de Envoy mostraban cx_total=15 para
#      rq_total=592, sin errores: la reutilización de conexión ya andaba
#      bien, el problema nunca fue el pool). Con un solo exec y concurrencia
#      manejada adentro (bash + `wait -n`, ventana deslizante real, mismo
#      comportamiento que el ThreadPoolExecutor de antes) el overhead de
#      exec se paga UNA vez, no N veces.
#
#   3. Progreso en vivo: un "." por request completado, a stderr, mientras
#      corre — antes el script se quedaba en silencio total hasta el final
#      (se sentía colgado aunque estuviera trabajando).
#
#   4. Pega contra `bff` (00-bff.yaml), NO directo contra egress-gw/backend —
#      es lo que mide la experiencia real del consumidor, y es lo único que
#      trae el wrapper `.upstream.*` (bff encadena hacia backend; backend
#      solo, sin bff adelante, es un echo-server plano sin ese wrapper).
#      Pod real que atendió en `.upstream.body.environment.HOSTNAME`,
#      latencia en `.upstream.latencyMs` (medida por el propio bff alrededor
#      de su llamada saliente — incluye egress-gw + wristband + red +
#      backend, no incluye el hop hacia bff en sí).
#
#   ./medir-latencia.sh              # 100 requests EN SERIE
#   ./medir-latencia.sh 200          # 200 requests
#   ./medir-latencia.sh 200 --par 10 # 10 en paralelo: mide CAPACIDAD, no latencia
#
# POR DEFECTO ES EN SERIE — mismo motivo que el original: sin concurrencia no
# hay cola, así que lo que se mide es el costo intrínseco del camino.
#
# No hay modo `--ab` (x-canary): acá todavía no existe split por peso ni
# canary por header (eso es lo que sería el equivalente de
# poc-egress-kuadrant/origen/08-rollout/, no armado todavía de este lado).
set -uo pipefail

N="${1:-100}"
MODO="${2:-}"
PAR="${3:-1}"
KCTX="${KCTX:-devops-cilium-1-35}"
NS="${NS:-poc-ingress-kuadrant}"
BFF_SVC="${BFF_SVC:-bff.${NS}.svc.cluster.local:8080}"
[ "$MODO" = "--par" ] || PAR=1
[ "$PAR" -ge 1 ] || PAR=1

command -v jq >/dev/null || { echo "falta jq"; exit 2; }

RUNNER="latencia-runner-$$"
cleanup() { kubectl --context="$KCTX" -n "$NS" delete pod "$RUNNER" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "levantando pod runner ($RUNNER)..." >&2
kubectl --context="$KCTX" -n "$NS" run "$RUNNER" --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal --command -- sleep infinity >/dev/null
kubectl --context="$KCTX" -n "$NS" wait --for=condition=Ready pod/"$RUNNER" --timeout=60s >/dev/null

# Todo el loop corre adentro del pod en un solo `kubectl exec`. `wait -n`
# (bash >=4.3, presente en ubi9-minimal) da ventana deslizante real: en
# cuanto termina CUALQUIER curl en vuelo, arranca el siguiente — mismo
# comportamiento que el ThreadPoolExecutor que reemplaza.
REMOTE_SCRIPT="
mkdir -p /tmp/out
running=0
for j in \$(seq 1 $N); do
  curl -s --max-time 20 'http://$BFF_SVC/' > /tmp/out/\$j.json &
  running=\$((running+1))
  if [ \"\$running\" -ge $PAR ]; then
    wait -n
    running=\$((running-1))
    echo -n '.' >&2
  fi
done
wait
echo '' >&2
for j in \$(seq 1 $N); do
  echo '===RESP==='
  cat /tmp/out/\$j.json
  echo
done
"

echo "corriendo $N requests (par=$PAR)..." >&2
python3 - "$N" "$PAR" "$KCTX" "$NS" "$RUNNER" "$REMOTE_SCRIPT" <<'PY'
import json, subprocess, sys, collections, time

n, par, kctx, ns, runner, remote_script = (
    int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
)

cmd = ["kubectl", "--context", kctx, "-n", ns, "exec", runner, "--", "bash", "-c", remote_script]

t0 = time.time()
# stderr SIN capturar: hereda la terminal, así los "." de progreso se ven en
# vivo mientras corre. stdout SÍ se captura, es lo que se parsea después.
proc = subprocess.run(cmd, stdout=subprocess.PIPE, text=True)
wall = time.time() - t0

crudo = [chunk for chunk in proc.stdout.split("===RESP===\n") if chunk.strip()]

datos = collections.defaultdict(list)
errores = collections.Counter()
for salida in crudo:
    try:
        u = (json.loads(salida) or {}).get("upstream") or {}
        if u.get("status") != 200:
            errores["status=%s %s" % (u.get("status"), (u.get("error") or "")[:40])] += 1
            continue
        pod = ((u.get("body") or {}).get("environment") or {}).get("HOSTNAME", "(sin HOSTNAME)")
        datos[pod].append(u["latencyMs"])
    except Exception as e:
        errores[type(e).__name__] += 1

if len(crudo) != n:
    errores["respuestas recibidas != N pedido (%d != %d, exec falló?)" % (len(crudo), n)] += 1

pct = lambda v, q: v[min(len(v) - 1, int(len(v) * q))]

print("\nmodo: %s   requests: %d   duracion: %.1fs" %
      ("EN SERIE" if par == 1 else "PARALELO x%d" % par, n, wall))
if par > 1:
    print("throughput: %.1f req/s   (los percentiles incluyen tiempo en cola: NO comparar con la corrida en serie)"
          % (n / wall if wall else 0))

print("\n%-34s %5s %8s %8s %8s %8s" % ("pod que atendio", "n", "p50", "p90", "p99", "max"))
print("-" * 76)
resumen = {}
for pod, v in sorted(datos.items(), key=lambda kv: pct(sorted(kv[1]), .50)):
    v.sort()
    print("%-34s %5d %7.1f %8.1f %8.1f %8.1f" % (pod[:34], len(v), pct(v,.50), pct(v,.90), pct(v,.99), v[-1]))
    resumen[pod] = v

if len(resumen) == 2:
    (pa, va), (pb, vb) = sorted(resumen.items(), key=lambda kv: pct(kv[1], .50))
    print("\ndelta entre backends:  p50 %+.1f ms   p90 %+.1f ms   p99 %+.1f ms" %
          (pct(vb,.50)-pct(va,.50), pct(vb,.90)-pct(va,.90), pct(vb,.99)-pct(va,.99)))
    print("  rapido: %s     lento: %s" % (pa[:34], pb[:34]))
    tot = len(va) + len(vb)
    print("  reparto medido: %d%% / %d%%" % (100*len(va)//tot, 100*len(vb)//tot))
elif len(resumen) == 1:
    print("\n(un solo backend: no hay delta que calcular — todavia no hay split local/remoto de este lado)")

if errores:
    print("\nERRORES:")
    for k, c in errores.most_common():
        print("  %4d  %s" % (c, k))
else:
    print("\nsin errores")
PY
