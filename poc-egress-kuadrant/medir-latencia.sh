#!/usr/bin/env bash
# Mide la latencia del salto server -> server2 desde el bastión, agrupando por el pod que
# realmente atendió. Sirve para comparar antes y después de mover tráfico.
#
#   ./medir-latencia.sh              # 100 requests EN SERIE
#   ./medir-latencia.sh 200          # 200 requests
#   ./medir-latencia.sh 100 --ab     # alterna con y sin `x-canary` (sólo útil en fase 1)
#   ./medir-latencia.sh 200 --par 10 # 10 en paralelo: mide CAPACIDAD, no latencia
#
# POR DEFECTO ES EN SERIE: un request por vez, esperando el anterior. Sin concurrencia no hay
# cola ni contención, así que lo que se mide es el costo intrínseco de un request. Es lo que hay
# que usar para comparar caminos.
#
# `--par N` lanza N en vuelo simultáneamente. Responde otra pregunta —cuánto aguanta el gateway—
# y sus percentiles NO son comparables con los de la corrida en serie: incluyen el tiempo en cola.
#
# `--ab` alterna con y sin `x-canary` request a request. Sólo tiene sentido con `fase1-canary`
# aplicada; con pesos el header no matchea nada y las dos variantes ven el mismo reparto. El
# script lo detecta y avisa.
#
# El agrupamiento que importa es POR POD, no por variante: es lo que distingue el backend local
# del remoto. El delta se calcula entre pods.
#
# Mide `.upstream.latencyMs`, que es lo que el BFF cronometra alrededor de su llamada saliente:
# incluye el Envoy de egreso, Authorino, el salto de red y el backend. NO incluye el ingress ni
# el bastión, que son ruido común a todas las variantes.
set -uo pipefail

N="${1:-100}"
MODO="${2:-}"
PAR="${3:-1}"
URL="${URL:-http://10.254.28.68}"
HOST="${HOST:-app1.paas-demo.bancogalicia.com.ar}"

command -v jq >/dev/null || { echo "falta jq"; exit 2; }

python3 - "$N" "$MODO" "$URL" "$HOST" "$PAR" <<'PY'
import json, subprocess, sys, collections, time
from concurrent.futures import ThreadPoolExecutor

n, modo, url, host = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
par = max(1, int(sys.argv[5])) if modo == "--par" else 1
ab = (modo == "--ab")

def pedir(i):
    canary = ab and (i % 2 == 1)
    cmd = ["curl", "-s", "--max-time", "20", "-H", "Host: " + host]
    if canary:
        cmd += ["-H", "x-canary: true"]
    cmd += [url + "/"]
    return ("con x-canary" if canary else "por defecto",
            subprocess.run(cmd, capture_output=True, text=True).stdout)

t0 = time.time()
if par > 1:
    with ThreadPoolExecutor(max_workers=par) as ex:
        crudo = list(ex.map(pedir, range(n)))
else:
    crudo = [pedir(i) for i in range(n)]
wall = time.time() - t0

datos = collections.defaultdict(list)
por_variante = collections.defaultdict(collections.Counter)
errores = collections.Counter()
for variante, salida in crudo:
    try:
        u = (json.loads(salida) or {}).get("upstream") or {}
        if u.get("status") != 200:
            errores["%s: status=%s %s" % (variante, u.get("status"), (u.get("error") or "")[:40])] += 1
            continue
        pod = ((u.get("body") or {}).get("environment") or {}).get("HOSTNAME", "(sin HOSTNAME)")
        datos[pod].append(u["latencyMs"])
        por_variante[variante][pod] += 1
    except Exception as e:
        errores["%s: %s" % (variante, type(e).__name__)] += 1

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
    print("\n(un solo backend: no hay delta que calcular)")

if ab and len(por_variante) == 2:
    a, b = sorted(por_variante)
    if set(por_variante[a]) == set(por_variante[b]) and len(por_variante[a]) > 1:
        print("\n*** OJO: las dos variantes reparten entre los MISMOS backends.")
        print("    El header x-canary no esta seleccionando nada: la route no tiene regla de canary")
        print("    (probablemente este en fase2-pesos). El modo --ab no aporta; leer la tabla por pod.")

if errores:
    print("\nERRORES:")
    for k, c in errores.most_common():
        print("  %4d  %s" % (c, k))
else:
    print("\nsin errores")
PY
