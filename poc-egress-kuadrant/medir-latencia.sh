#!/usr/bin/env bash
# Mide la latencia del salto server -> server2 desde el bastión, agrupando por el pod que
# realmente atendió. Sirve para comparar antes y después de mover tráfico.
#
#   ./medir-latencia.sh            # 100 requests, sólo el camino por defecto
#   ./medir-latencia.sh 200        # 200 requests
#   ./medir-latencia.sh 100 --ab   # alterna con y sin `x-canary`: comparación PAREADA
#
# El modo `--ab` es el que vale para decidir. Alterna las dos variantes request a request,
# así los dos caminos ven el mismo instante, la misma red y la misma carga del cluster. Comparar
# una corrida de hoy contra otra de hace una hora mezcla el efecto que querés medir con todo lo
# que cambió en el medio.
#
# Mide `.upstream.latencyMs`, que es lo que el BFF cronometra alrededor de su llamada saliente:
# incluye el Envoy de egreso, Authorino, el salto de red y el backend. NO incluye el ingress ni
# el bastión, que son ruido común a las dos variantes.
set -uo pipefail

N="${1:-100}"
MODO="${2:-}"
URL="${URL:-http://10.254.28.68}"
HOST="${HOST:-app1.paas-demo.bancogalicia.com.ar}"

command -v jq >/dev/null || { echo "falta jq"; exit 2; }

python3 - "$N" "$MODO" "$URL" "$HOST" <<'PY'
import json, subprocess, sys, collections

n, modo, url, host = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
ab = (modo == "--ab")
datos = collections.defaultdict(list)
errores = collections.Counter()

def pedir(canary):
    cmd = ["curl", "-s", "--max-time", "15", "-H", "Host: " + host]
    if canary:
        cmd += ["-H", "x-canary: true"]
    cmd += [url + "/"]
    return subprocess.run(cmd, capture_output=True, text=True).stdout

for i in range(n):
    canary = ab and (i % 2 == 1)
    variante = "con x-canary" if canary else "por defecto"
    try:
        j = json.loads(pedir(canary))
        u = j.get("upstream") or {}
        st = u.get("status")
        if st != 200:
            errores["%s: status=%s %s" % (variante, st, (u.get("error") or "")[:40])] += 1
            continue
        env = (u.get("body") or {}).get("environment") or {}
        pod = env.get("HOSTNAME", "(sin HOSTNAME)")
        datos[(variante, pod)].append(u["latencyMs"])
    except Exception as e:
        errores["%s: %s" % (variante, type(e).__name__)] += 1

def pct(v, q):
    return v[min(len(v) - 1, int(len(v) * q))]

print("\n%-14s %-32s %5s %8s %8s %8s %8s" % ("variante", "pod que atendió", "n", "p50", "p90", "p99", "max"))
print("-" * 92)
resumen = {}
for (variante, pod), v in sorted(datos.items()):
    v.sort()
    print("%-14s %-32s %5d %7.1f %8.1f %8.1f %8.1f" % (variante, pod[:32], len(v), pct(v,.50), pct(v,.90), pct(v,.99), v[-1]))
    resumen.setdefault(variante, []).extend(v)

if len(resumen) == 2:
    a, b = sorted(resumen)          # "con x-canary" < "por defecto"
    va, vb = sorted(resumen[a]), sorted(resumen[b])
    d50 = pct(va,.50) - pct(vb,.50)
    d99 = pct(va,.99) - pct(vb,.99)
    print("\ndelta '%s' vs '%s':  p50 %+.1f ms   p99 %+.1f ms" % (a, b, d50, d99))
    print("(positivo = el canary es más lento, que es lo esperable si va al otro cluster)")

if errores:
    print("\nERRORES:")
    for k, c in errores.most_common():
        print("  %4d  %s" % (c, k))
else:
    print("\nsin errores")
PY
