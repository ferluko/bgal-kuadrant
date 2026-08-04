# Cascada de echo servers — simular BFF → backend

`bastión → server → server2 → server (anida la respuesta) → bastión`

Workload base para las PoCs de red (ingress con Kuadrant, egreso con wristband, cutover
del `Service server2`). Sirve para lo que un echo server suelto no puede probar: **que el
salto interno efectivamente ocurrió**, con qué headers, contra qué IP y en cuánto tiempo.

## 1. Echo-Server de Ealenn no encadena

[`Ealenn/Echo-Server`](https://github.com/Ealenn/Echo-Server) refleja el request entrante y
nada más. Todos sus controles operan sobre su **propia** respuesta:

| Control | Query | Header | Qué hace |
|---|---|---|---|
| Status | `echo_code` | `X-ECHO-CODE` | responde 200–599 |
| Body | `echo_body` | `X-ECHO-BODY` | body a medida |
| Env en body | `echo_env_body` | `X-ECHO-ENV-BODY` | valor de una env var |
| Headers | `echo_header` | `X-ECHO-HEADER` | headers de respuesta |
| Latencia | `echo_time` | `X-ECHO-TIME` | demora 0–60000 ms |
| Archivos | `echo_file` | `X-ECHO-FILE` | lista/sirve un directorio |

No existe `BACKEND_URL`, `PROXY`, `FORWARD` ni `UPSTREAM`: **no hace llamadas salientes**,
así que el hop intermedio no se puede armar con él. (Sí lo hace `podinfo` con
`--backend-url`, pero su `/echo` reenvía el *body posteado*, no un GET con su path y sus
headers — no es el modelo BFF que buscamos.)

## 2. La adaptación

Sólo el **hop intermedio** necesita reemplazo. El extremo sigue siendo `echo-server`, que es
justo donde más rinde: devuelve crudo todo lo que le llegó (headers, IP de origen, query,
body), incluido el `x-egress-token` que inyecta la `AuthPolicy` de la PoC de egreso.

| Hop | Workload | Imagen | Rol |
|---|---|---|---|
| 1 | `server` | `ubi9/python-312` + ConfigMap | BFF: refleja **y** llama al hop 2 |
| 2 | `server2` | `ealen/echo-server:0.9.2` | backend, echo terminal sin adaptar |

El BFF son ~150 líneas de stdlib de Python montadas por ConfigMap: sin build, sin pip, sin
registry propio. Devuelve el mismo esqueleto JSON que echo-server (`host` / `http` /
`request`) y le cuelga abajo la respuesta completa del hop 2:

```jsonc
{
  "hop": "server",
  "host": { "hostname": "server-xxx", "ip": "10.128.2.7", "ips": ["..."] },
  "http": { "method": "GET", "originalUrl": "/api/pedidos?id=42", "path": "/api/pedidos" },
  "request": { "query": {...}, "cookies": {}, "body": "", "headers": {...} },
  "upstream": {
    "url": "http://server2.echoserver.svc.cluster.local:8080/api/pedidos?id=42",
    "requestHeaders": {...},   // lo que el hop 1 mandó
    "status": 200,
    "headers": {...},
    "body": { "host": {...}, "http": {...}, "request": {...} },  // el echo del hop 2
    "latencyMs": 3.4
  }
}
```

### Qué propaga

Todos los headers entrantes **salvo** los hop-by-hop (`host`, `connection`,
`content-length`, `transfer-encoding`, `upgrade`, `te`, `trailer`, `proxy-*`, `expect`,
`accept-encoding`) más lo que se liste en `STRIP_HEADERS`. Es decir que atraviesan la
cascada `Authorization`, `traceparent`, `x-b3-*`, `x-request-id` y los `X-ECHO-*` — que
llegan al hop 2 y **el echo-server los obedece**: podés forzar desde el bastión que el
backend devuelva 503 o demore 2 s y ver cómo lo reporta el BFF.

Agrega dos headers propios: `X-Cascade-Via` (traza acumulada de hops) y `X-Echo-Depth`
(profundidad, corta ciclos).

Reenvía método, path, query y body sin tocar.

### Configuración del BFF

| Env | Default | |
|---|---|---|
| `PORT` | `8080` | |
| `HOP_NAME` | hostname | nombre del hop en la salida |
| `UPSTREAM_URL` | *(vacío)* | **vacío ⇒ echo terminal, no encadena** |
| `UPSTREAM_KEEP_PATH` | `true` | reenviar path+query |
| `UPSTREAM_TIMEOUT_MS` | `5000` | |
| `UPSTREAM_ERROR_STATUS` | `502` | status propio si el upstream no responde |
| `MIRROR_UPSTREAM_STATUS` | `false` | `true` ⇒ devolver el status del hop 2 |
| `MAX_DEPTH` | `5` | corta cascadas infinitas |
| `ENABLE_ENVIRONMENT` | `false` | incluir `os.environ` en la salida |
| `STRIP_HEADERS` | *(vacío)* | headers a no propagar, separados por coma |

Headers de control desde el cliente: `X-Cascade-Skip: 1` hace que ese hop responda **sin**
llamar al upstream — sirve para aislar si el problema está en la entrada o en el salto.

`/healthz` y `/readyz` responden sin encadenar, para que un hop 2 caído no marque NotReady
al hop 1.

## 3. Desplegar

Respaldar primero el `server` actual, si existe:

```bash
oc -n echoserver get deploy server -o yaml > /tmp/server-deploy.bak.yaml
```

ConfigMap y `server2` van con `apply` sin vueltas:

```bash
oc apply -n echoserver -f 00-configmap-bff.yaml -f 02-server2-echo.yaml
```

**`server` NO va con `apply` si ya existe** — usar `replace --force`:

```bash
oc -n echoserver replace --force -f 01-server-bff.yaml
```

> **Por qué, verificado en `paas-arqlab` (2026-08-04).** En la lista `containers` la
> estrategia de merge es **por `name`**. Si el `server` original no fue creado con `apply`
> (no tiene la anotación `kubectl.kubernetes.io/last-applied-configuration`), `oc apply` no
> tiene cómo saber que el contenedor viejo sobra: **agrega `bff` y conserva el anterior**. El
> pod queda con dos contenedores compartiendo el network namespace, los dos bindean `:8080`,
> y el segundo muere con `EADDRINUSE` → exit 1 → **CrashLoopBackOff**, con el `bff` corriendo
> sano al lado (pod en `1/2`).
>
> `replace --force` borra y recrea el Deployment: hay unos segundos sin `server`, irrelevante
> en la PoC. Chequeo de que quedó un solo contenedor:
>
> ```bash
> oc -n echoserver get pod -l app=server \
>   -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
> ```

El manifiesto mantiene a propósito el label `app: server` y el puerto `8080`, así que el
`Service server`, el `HTTPRoute app1` y las policies de Kuadrant siguen enganchando.

Si `server2` ya está desplegado no hace falta aplicar `02`: está para dejar documentada la
config con la que se probó — en particular `PORT=8080`, que **no es cosmético**: el default
de la imagen es 80 y bajo `restricted-v2` (UID arbitrario) no puede bindear puerto
privilegiado.

Para 3+ niveles, `03-server3-cascada-n-niveles.yaml`: el mismo ConfigMap sirve para
cualquier hop, encadenando por `UPSTREAM_URL` y anidando en `.upstream.body.upstream.body`.

## 4. Probar

```bash
./test-cascada.sh
```

Cubre: cascada básica, propagación de headers vista desde el hop 2, path/query, POST con
body, `X-ECHO-CODE: 503`, `X-ECHO-TIME: 2000`, timeout → 502, y `X-Cascade-Skip`.

### Entrando por el APIM (3scale / APIcast)

El `server` se puede publicar como backend de un producto de 3scale en lugar de (o además
de) el `HTTPRoute` directo. La URL incluye el path del producto y las credenciales van por
header:

```bash
URL=https://echoserver-b2c.apps.paas-arqlab.bancogalicia.com.ar/v1 INSECURE=1 \
HDRS='app_id: <app_id>;app_key: <app_key>' ./test-cascada.sh
```

Verificado contra `echoserver-b2c` en `paas-arqlab` (2026-08-04): la cascada atraviesa
APIcast sin cambios — `hop1 = server-…`, `hop2 = server2-564d58898-dhcpr`, `status 200`,
`10.4 ms`.

Dos salvedades al correr el script completo por esta vía:

- **Los mapping rules del producto tienen que aceptar los paths** que usan los casos 3 y 4
  (`/a/b/c`, `/pagos`). Si el producto sólo mapea `/`, esos casos van a dar 404 del APIM, no
  del BFF — se distingue porque la respuesta no trae `hop`.
- **APIcast puede filtrar headers.** Si los casos 5 y 6 (`X-ECHO-CODE`, `X-ECHO-TIME`) no
  surten efecto, mirá `.upstream.body.request.headers` del caso 2: ahí se ve exactamente qué
  llegó al hop 2 y si el header se perdió en el APIM o en el BFF.

Un vistazo rápido de quién contestó en cada hop:

```bash
curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/api/pedidos?id=42 \
  | jq '{hop1: .host.hostname, hop2: .upstream.body.environment.HOSTNAME,
         hop2_vio_ip: .upstream.body.host.ip,
         status: .upstream.status, ms: .upstream.latencyMs}'
```

> **Trampa de echo-server, verificada contra `0.9.2`:** en su salida `.host.hostname` es el
> **header `Host`** del request y `.host.ip` es la **IP del cliente**. Ninguno de los dos
> identifica al pod que atendió — con `Host: server2.echoserver.svc.cluster.local` el campo
> `hostname` devuelve ese FQDN venga la respuesta del pod local o del cluster remoto. El
> único dato del pod es `.environment.HOSTNAME`, y sólo aparece con `ENABLE__ENVIRONMENT=true`
> (por eso `02-server2-echo.yaml` lo pone en `true`). Atajo equivalente:
> `curl -H 'X-ECHO-ENV-BODY: HOSTNAME'` devuelve sólo el hostname como body.
>
> `.host.ip` sí es útil en la PoC de egreso, pero por otra razón: es la **IP de origen tal
> como la ve el hop 2**, o sea si el request llegó del pod del BFF o del gateway de egreso.

## 5. Cómo se usa en las PoCs

- **Egreso (`poc-egress-kuadrant`)** — el README dice que `server` consume
  `http://server2.echoserver.svc.cluster.local:8080`; con esto **realmente lo consume**. El
  cutover cambia el selector del `Service server2` al gateway de egreso y el BFF no se
  entera: mismo FQDN, misma ClusterIP. Lo que valida la migración es que
  `.upstream.body.request.headers["x-egress-token"]` aparezca y que
  `.upstream.body.environment.HOSTNAME` pase a ser un pod del cluster destino.
- **Rollout progresivo** — con los pesos del HTTPRoute, un loop de curls y
  `jq -r '.upstream.body.environment.HOSTNAME'` da el reparto local/remoto real, request a
  request.
- **Ingress** — `.request.headers` del hop 1 muestra qué agregó el F5 y qué agregó Envoy
  (`x-forwarded-for`, `x-forwarded-proto`, `x-envoy-*`).

## 6. Verificación y límites

Probado localmente (fuera del cluster), primero con instancias del BFF encadenadas entre sí
y después con el **hop 2 corriendo la imagen real `docker.io/ealen/echo-server:0.9.2`**:

- cascada con path y query reenviados tal cual, y `Authorization` / headers custom llegando
  al hop 2 (leídos desde el propio echo del hop 2, no desde lo que dice el BFF);
- POST con body JSON atravesando los dos hops;
- `X-ECHO-CODE: 503` propagado → `.upstream.status = 503` y el hop 1 igual responde 200;
- `X-ECHO-TIME: 2000` → `latencyMs` medida por el hop 1 = 2009 ms;
- `X-ECHO-TIME: 6000` con `UPSTREAM_TIMEOUT_MS=5000` → hop 1 devuelve `502` con
  `TimeoutError` a los 5001 ms;
- upstream caído → `502` con `URLError: Connection refused`;
- `X-Cascade-Skip: 1` y `/healthz` sin encadenar;
- cascada de 3 niveles: `X-Echo-Depth` incrementando (1, 2) y `X-Cascade-Via` acumulando
  (`server`, `server,server2b`).

**En `paas-arqlab` (OCP 4.20, 2026-08-04)** quedó verificada la cascada de punta a punta,
entrando por el APIM (`echoserver-b2c` → APIcast → `server`):

- pull de `ubi9/python-312:1`, montaje del ConfigMap y arranque bajo `restricted-v2` con
  `runAsNonRoot` + `readOnlyRootFilesystem` + `drop: ALL`;
- hop 1 → hop 2 por el FQDN del Service, `status 200` en **10,4 ms**;
- identificación de los dos pods (`server-…` / `server2-564d58898-dhcpr`), con
  `.upstream.body.environment.HOSTNAME` resolviendo correcto en el hop 2;
- IP de origen vista por el hop 2 (`::ffff:10.131.1.196`) — la línea de base pre-cutover
  para la PoC de egreso.

**No ejercitado todavía en cluster:** el resto de `test-cascada.sh` (POST con body,
`X-ECHO-CODE`, `X-ECHO-TIME`, timeout → 502, `X-Cascade-Skip`) y la cascada de 3 niveles.

**Límites conocidos:**

- El BFF abre una conexión TCP nueva por request al upstream (`urllib` no hace keep-alive).
  Para una PoC de red es más bien una ventaja — cada request reejercita DNS, TCP y política
  de egreso — pero no sirve para medir performance.
- Sin soporte de HTTP/2 ni gRPC hacia el upstream.
- Sin streaming: el body del upstream se lee entero en memoria antes de responder.
- `ThreadingHTTPServer` es un hilo por conexión. Alcanza de sobra para pruebas manuales y
  loops de curl; no es un generador de carga.
