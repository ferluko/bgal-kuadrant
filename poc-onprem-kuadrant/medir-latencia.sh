#!/usr/bin/env bash
# Copia de poc-egress-kuadrant/medir-latencia.sh para el cruce on-prem
# paas-lab -> paas-arqlab. Misma lógica (percentiles, agrupado por pod, delta
# entre backends). Lo que cambia:
#
#   - URL/Host del BFF de paas-lab (`bff-lab.paas-demo…`), no el de arqlab.
#   - El salto remoto es app3 -> router default de arqlab (10.254.28.1), con
#     mint JWT-SVID de Vault en el egreso. Ese mint entra en `.upstream.latencyMs`.
#   - `--ab` sigue siendo fase 1 (header `x-canary`). Con pesos (fase 2) no
#     selecciona nada: el script lo detecta y avisa, igual que el original.
#
# El agrupamiento que importa es POR POD: distingue backend local (paas-lab)
# del remoto (arqlab). El delta es el costo del cruce: RTT + TLS + Vault + dest.
#
#   ./medir-latencia.sh              # 100 requests EN SERIE
#   ./medir-latencia.sh 200          # 200 requests
#   ./medir-latencia.sh 100 --ab     # alterna con y sin `x-canary` (sólo fase 1)
#   ./medir-latencia.sh 200 --par 10 # 10 en paralelo: mide CAPACIDAD, no latencia
#
# POR DEFECTO ES EN SERIE: un request por vez. Sin cola ni contención, se mide
# el costo intrínseco del camino. Es lo que hay que usar para comparar local vs
# remoto. `--par N` responde otra pregunta —cuánto aguanta el gateway— y sus
# percentiles NO son comparables con la corrida en serie.
#
# Mide `.upstream.latencyMs`: lo que el BFF cronometra alrededor de su llamada
# saliente. Incluye Envoy de egreso, Authorino/Vault, TLS y el backend. NO
# incluye el ingress ni el bastión.
#
# Si el FQDN no resuelve desde el bastión:
#   URL=http://<vip-paas-lab> HOST=bff-lab.paas-demo.bancogalicia.com.ar ./medir-latencia.sh
set -uo pipefail

N="${1:-100}"
MODO="${2:-}"
PAR="${3:-1}"
URL="${URL:-http://bff-lab.paas-demo.bancogalicia.com.ar}"
HOST="${HOST:-bff-lab.paas-demo.bancogalicia.com.ar}"

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
            body = u.get("body")
            if isinstance(body, str):
                detalle = body[:80].replace("\n", " ")
            else:
                detalle = (u.get("error") or "")[:40]
            errores["%s: status=%s %s" % (variante, u.get("status"), detalle)] += 1
            continue
        pod = ((u.get("body") or {}).get("environment") or {}).get("HOSTNAME", "(sin HOSTNAME)")
        datos[pod].append(u["latencyMs"])
        por_variante[variante][pod] += 1
    except Exception as e:
        errores["%s: %s" % (variante, type(e).__name__)] += 1

pct = lambda v, q: v[min(len(v) - 1, int(len(v) * q))]

print("\nmodo: %s   requests: %d   duracion: %.1fs" %
      ("EN SERIE" if par == 1 else "PARALELO x%d" % par, n, wall))
print("bff: %s  Host: %s" % (url, host))
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
    print("  (el lento es el cruce a arqlab: RTT + TLS + mint Vault; el rapido es backend-local)")
elif len(resumen) == 1:
    print("\n(un solo backend: no hay delta que calcular — HTTPRoute 100% local o 100% remoto)")

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
