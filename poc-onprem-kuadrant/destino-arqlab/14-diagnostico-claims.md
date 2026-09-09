# Cerrar el hallazgo: por qué `claims-esperados` no rechaza en arqlab

## El hallazgo

Confirmado en vivo el 2026-09-02 (`vault-emisor-spiffe.md` §2quater): se cambió temporalmente el
`template` del `spiffe/role` en Vault a un `sub` no autorizado (`.../poc/impostor`), dejando todo
lo demás igual, y el token resultante **llegó al pod real de OCP con 200 OK**, con el `sub`
impostor decodificado del header recibido — no inferido. La `AuthPolicy` mostraba `Enforced: True`.

## Hipótesis DESCARTADAS (2026-09-09) — no volver sobre ellas

### ✗ Poda silenciosa del campo `predicate` por deriva de schema del CRD

La idea era que el structural schema del CRD no declarara `patternMatching.patterns[].predicate`
y lo descartara en silencio al aplicar, dejando patrones vacíos que no rechazan nada.

**Refutada.** Los tres predicados están completos en el objeto guardado:

```console
$ oc -n poc-ingress-kuadrant get authpolicy backend-ingress-vault-spiffe -o json | jq '..|.predicate? // empty'
"auth.identity.iss == \"https://vault-cluster-noprod-private-vault-...:8200\"\n"
"\"bff-eks.paas-demo.bancogalicia.com.ar\" in auth.identity.aud\n"
"auth.identity.sub == \"spiffe://poc-egress.bancogalicia.com.ar/poc/egress-gw\"\n"
```

### ✗ istiod no le empuja el `ext_authz` al gateway desplegado a mano

La idea era que, siendo `gw-hostnet` un DaemonSet creado a mano (class `ingress-hostnet`, no
autodesplegado por el controller), istiod no le asociara recursos por proxy — explicando de un
saque tanto este hallazgo como el bloqueo de SDS del runbook §7.2.

**Refutada.** El Envoy del gateway tiene la config:

```console
$ oc -n connlink-ingress exec ds/gw-hostnet -c istio-proxy -- \
    pilot-agent request GET config_dump | grep -o 'ext_authz\|kuadrant\|authorino' | sort | uniq -c
     63 authorino
      7 ext_authz
    149 kuadrant
```

Los dos hallazgos siguen siendo independientes: el de SDS es sobre certificados, este no.

## Lo que queda en pie, y el orden para atacarlo

Después de descartar esas dos, la pregunta se parte en dos ramas mutuamente excluyentes, y hay
**un solo dato** que decide cuál:

> **¿Authorino llegó a VER el request?**

- **NO lo vio** → el problema está *antes*: el wasm-shim de Kuadrant no matcheó el request contra
  ninguna action set, y lo dejó pasar sin evaluar. La policy es correcta y nunca se ejecuta.
- **Sí lo vio y devolvió `authorized:true`** → el problema es la *evaluación*: los predicados
  corren y dan verdadero cuando no deberían.

Es el dato que faltó el 2026-09-02 ("no se pudo diagnosticar más sin logs de Authorino del lado
OCP en el momento exacto"). Sin él, cualquier hipótesis es adivinanza — ya van dos.

### Cómo obtenerlo

Terminal 1, seguir los logs de Authorino en el destino:

```bash
oc --context=paas-arqlab -n kuadrant-system logs -f deploy/authorino | grep -i 'authorized\|denied\|backend'
```

Terminal 2, generar UN request por el camino real y anotar la hora exacta:

```bash
date -u; oc --context=<origen> -n <ns> exec deploy/bff -- \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  http://backend.poc-ingress-kuadrant.svc.cluster.local:8080/
```

## Rama A — Authorino no vio el request

Hipótesis: **el `:authority` llega con puerto y el shim matchea sin puerto.**

El request cruza con `Host: backend.poc-ingress-kuadrant.svc.cluster.local:8080` (el egreso no
reescribe el Host — es el diseño). El `HTTPRoute` declara el hostname **sin** puerto. El
wasm-shim de Kuadrant arma sus action sets a partir de esos hostnames; si compara contra el
`:authority` crudo, `...cluster.local:8080` no matchea `...cluster.local` y el shim **no ejecuta
ninguna acción**: no llama a Authorino, no loguea nada, y el request sigue de largo.

Explica los cuatro síntomas a la vez, incluido el más raro — que no hay error en ningún lado:
el impostor pasando, `Enforced: True` honesto, cero logs de Authorino, y el filtro presente
en Envoy.

Verificación — mirar los hostnames que el shim tiene configurados de verdad:

```bash
oc --context=paas-arqlab -n connlink-ingress exec ds/gw-hostnet -c istio-proxy -- \
  pilot-agent request GET config_dump \
  | python3 -c 'import json,sys,re
d=sys.stdin.read()
for m in re.finditer(r"\{[^{}]*kuadrant[^{}]*\}", d):
    print(m.group(0)[:400])' | head -40
```

y contrastar con lo que llega de verdad, leído del propio backend (el `bff-cascada` devuelve los
headers que recibió el hop 2):

```bash
oc --context=<origen> -n <ns> exec deploy/bff -- \
  curl -sS http://backend.poc-ingress-kuadrant.svc.cluster.local:8080/ \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["upstream"]["body"]["request"]["headers"])'
```

Si el `host` que ve el backend trae `:8080` y el shim está configurado sin puerto, ahí está.

Salidas posibles: agregar el hostname **con** puerto al `HTTPRoute`, o mover el enforcement al
`Gateway` en vez del `HTTPRoute` (`targetRef` a `Gateway`, que no depende del match de hostname).

## Rama B — Authorino vio el request y autorizó

Candidatos, en orden:

1. **`aud` como lista vs string.** El claim llega como `["bff-eks..."]`. Si Authorino lo aplana a
   string, `in` en CEL hace *substring match*, y `"x" in "x"` es siempre verdadero. Quedó marcado
   como SIN VERIFICAR desde el 2026-09-02. Probar cambiando ese predicado a `==`.
2. **Dos AuthPolicy compitiendo por el mismo `targetRef`.** `backend-ingress-jwt` (wristband) y
   `backend-ingress-vault-spiffe` apuntan las dos al `HTTPRoute backend`. Kuadrant marca una como
   *overridden*. Si estás mirando el status de la que no se aplica, todo el análisis va al lugar
   equivocado:
   ```bash
   oc --context=paas-arqlab -n poc-ingress-kuadrant get authpolicy \
     -o custom-columns='NOMBRE:.metadata.name,TARGET:.spec.targetRef.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status,ENFORCED:.status.conditions[?(@.type=="Enforced")].status,MSG:.status.conditions[?(@.type=="Enforced")].message'
   ```
3. **Identidad no resuelta.** Si `auth.identity` es nulo, según cómo Authorino trate el error el
   patrón puede no evaluar a falso. Se distingue pidiendo un claim de vuelta en un header de
   respuesta: si la policy puede leerlo y devolverlo, la identidad resolvió.

## La prueba negativa, bien hecha

Lo que **no** sirve: mandar un `x-egress-token` basura desde el cliente — Authorino en el origen
sobreescribe cualquier valor que mande el cliente.

Lo que **no** sirve tampoco: pegarle al hostname externo con `Host` a mano por el puerto 80. Eso
golpea un listener distinto del que usa el tráfico real y puede estar bypaseando la policy en vez
de probarla. Así se invalidó la primera prueba negativa.

Lo que **sí** funciona: cambiar temporalmente el `template` del `spiffe/role` en Vault a un `sub`
no autorizado. Así el token que sale por el camino real es genuinamente inválido, sin tocar nada
de Kubernetes.

```bash
# 1. Guardar el template actual
curl -sS "$V/spiffe/role/<rol>" -H "$H" -H "X-Vault-Token: $T" | python3 -m json.tool
# 2. Cambiarlo a un sub no autorizado
curl -sS -X POST "$V/spiffe/role/<rol>" -H "$H" -H "X-Vault-Token: $T" \
  -d '{"template": "{\"sub\": \"spiffe://poc-egress.bancogalicia.com.ar/paas-lab/impostor\"}", "ttl": "300"}'
# 3. IMPRESCINDIBLE: vaciar el cache, si no se prueba con el token viejo y el resultado engaña
oc --context=<origen> -n kuadrant-system rollout restart deployment authorino
# 4. Tráfico real. ESPERADO: 403. Si da 200, el hallazgo se reproduce.
# 5. REVERTIR el template y confirmar con tráfico que el sub volvió al bueno.
```

El paso 3 es el que faltó la primera vez: con `cache.ttl: 250` un cambio en Vault tarda hasta
250 s en verse.

## Por qué cerrarlo ahora

paas-lab entra como tercer cluster. Si `claims-esperados` no evalúa, **cualquier workload que
consiga un token de Vault entra a cualquier destino**: el `sub` deja de ser un control y pasa a
ser decoración. Con dos clusters era un hallazgo; con tres, es el argumento central de la PoC
—identidad por workload— quedando sin sustento demostrable.
