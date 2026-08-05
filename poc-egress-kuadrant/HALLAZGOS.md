# Hallazgos de la PoC de egreso

Lo que costó descubrir, con la evidencia que lo respalda. El [README](README.md) describe el
diseño y el procedimiento vigentes; acá está el porqué de varias de sus decisiones.

Casi todos comparten un patrón que conviene tener presente al leerlos: **el síntoma apuntaba
al lado equivocado**. Ninguno se detectó con un objeto en rojo — todos daban verde.

| # | Hallazgo | Dónde pega |
|---|---|---|
| [H1](#h1) | El echo server no encadena: el salto a migrar no existía | workload |
| [H2](#h2) | `oc apply` no reemplaza contenedores, los suma | despliegue |
| [H3](#h3) | echo-server no dice qué pod atendió — el conteo del canary era ciego | validación |
| [H4](#h4) | El cliente manda el `Host` con puerto | ruteo L7 |
| [H5](#h5) | El BFF devuelve 200 con el error adentro | validación |
| [H6](#h6) | `spec.rules[].name` se poda en silencio | Gateway API |
| [H7](#h7) | Cutover contra el gateway equivocado | intercepción |
| [H8](#h8) | `ServiceEntry` con `resolution: DNS` ignora `endpoints` | egreso |
| [H9](#h9) | **Authorino no valida su propio wristband** | diseño |
| [H10](#h10) | `x-request-id` se regenera en el gateway | observabilidad |
| [H11](#h11) | El claim `sub` no identifica a nadie | seguridad |
| [H12](#h12) | El destino real confirma que el Host viaja sin reescribir | diseño |
| [H13](#h13) | La prueba negativa de firma alterada no alteraba nada | validación |

---

<a id="h9"></a>
## H9. Authorino no puede validar su propio wristband — 2026-08-05

**El más caro, y el que cambia una decisión del ADR.** Son dos restricciones simultáneas, y
cada una tiene un mensaje que culpa al lado equivocado:

| Componente | Acepta | Si no se cumple |
|---|---|---|
| Verificador `jwt` (`jwksUrl`) | **sólo RS256** | 401 en destino indistinguible de "falta el token" |
| Firmador (`signingKeyRefs`) | RS256 sí, pero la clave **sólo en PKCS#1** | `invalid signing key algorithm` |

Con el diseño original (EC P-256 / ES256) el destino rechazaba el 100% de los tokens. Sólo se
vio subiendo el log de Authorino a `debug`:

```
cannot validate identity ... reason:
  "oidc: malformed jwt: unexpected signature algorithm \"ES256\"; expected [\"RS256\"]"
```

Todo lo demás estaba en verde: `AuthConfig` en `Ready=True`, `kid` coincidiendo, JWKS
sirviéndose bien, y las claves criptográficamente correctas.

Al pasar a RSA apareció la segunda restricción. `RS256` **está en el enum del CRD**, así que el
`apply` no protesta, pero `openssl genrsa` emite **PKCS#8** desde OpenSSL 3.x y Authorino sólo
parsea los formatos legacy — SEC1 para EC, PKCS#1 para RSA. El error dice `invalid signing key
algorithm`, culpando al algoritmo cuando el problema es el formato de la clave. Y esta falla es
**peor**: deja el `AuthConfig` del egreso sin reconciliar, el `ext_authz` falla cerrado y **se
cae el camino de la app entera**, no sólo la validación en destino.

**Consecuencia:** la única combinación que cierra el lazo es **RSA 2048 en PKCS#1**.
`keys/gen-signing-key.sh` fuerza el formato y lo verifica. Aplica igual al destino real: EKS
validando con Kuadrant habría fallado así, y el síntoma habría aparecido recién con los dos
clusters montados y la red abierta.

**Para el ADR:** la Opción B (Kuadrant validando en el destino) es viable, pero **no con la
configuración obvia**. Conviene que la excepción del ADR lo diga.

---

<a id="h1"></a>
## H1. El echo server no encadena — 2026-08-04

[`Ealenn/Echo-Server`](https://github.com/Ealenn/Echo-Server) sólo refleja el request entrante.
No tiene `BACKEND_URL`, `PROXY` ni `FORWARD`: **no hace llamadas salientes**.

La PoC asumía que `server` consumía `server2.echoserver.svc.cluster.local:8080`. No lo hacía:
**el salto que esta PoC migra no existía**, y toda la validación se apoyaba en `oc exec … curl`,
que prueba la red del pod pero no el camino de la aplicación.

**Consecuencia:** [`../echoserver-cascada/`](../echoserver-cascada/) — `server` pasa a ser un BFF
mínimo (stdlib de Python sobre ConfigMap) que refleja su propio request y le cuelga abajo la
respuesta completa de `server2`. El extremo sigue siendo `echo-server` sin tocar, que es donde
más rinde: devuelve crudo todo lo que le llegó, incluido el `x-egress-token`.

---

<a id="h2"></a>
## H2. `oc apply` no reemplaza contenedores, los suma — 2026-08-04

En la lista `containers` la estrategia de merge es **por `name`**. Si el Deployment original no
fue creado con `apply` (no tiene `kubectl.kubernetes.io/last-applied-configuration`), `apply` no
tiene cómo saber que el contenedor viejo sobra: **agrega el nuevo y conserva el anterior**.

Los dos bindean `:8080` en el network namespace del pod, el segundo muere con `EADDRINUSE`
(`errno -98`, exit 1) → **CrashLoopBackOff**, con el contenedor nuevo corriendo sano al lado y el
pod en `1/2`.

**Consecuencia:** `oc replace --force` para reemplazar un Deployment preexistente, y el chequeo
de "un solo contenedor" quedó como gate en `run-escenarios.sh` (E0).

---

<a id="h3"></a>
## H3. echo-server no dice qué pod atendió — 2026-08-04

En su salida, **`.host.hostname` es el header `Host`** del request y **`.host.ip` es la IP del
cliente**. Ninguno identifica al pod que respondió.

El §7.3 original contaba el reparto del canary con `grep -o 'server2[a-z0-9-]*'` sobre la
respuesta. Como el request va con `Host: server2.echoserver.svc.cluster.local`, ese grep
matcheaba el propio Host: daba **100 % "local" viniera la respuesta de donde viniera**. El
rollout 75/25 se veía correcto aunque el canary estuviera roto — un falso verde en el paso que
decide si la migración avanza.

**Consecuencia:** el pod sale de `.environment.HOSTNAME`, que exige `ENABLE__ENVIRONMENT=true`
en el `server2` de los dos lados. Y `.host.ip` sí sirve, pero para otra cosa: es la IP de origen
como la ve el destino, o sea la señal directa de que la intercepción tomó efecto.

---

<a id="h4"></a>
## H4. El cliente manda el `Host` con puerto — 2026-08-04

`urllib` arma `Host: server2.echoserver.svc.cluster.local:8080` (con puerto, porque no es el 80).
El listener del gateway de egreso declara `hostname:` **sin** puerto, y todas las verificaciones
del repo curleaban sin él.

**Resultado:** Istio normaliza el puerto y funciona. Pero el caso no estaba cubierto por ninguna
verificación, y si no normalizara serían **404 en el 100% del tráfico real** mientras el chequeo
con Host pelado seguía en verde.

**Consecuencia:** las verificaciones prueban las dos formas del Host. Si alguna vez falla, el fix
es quitar `hostname` del listener y dejar el matching a las `hostnames` del HTTPRoute.

---

<a id="h5"></a>
## H5. El BFF devuelve 200 con el error adentro — 2026-08-04

Corre con `MIRROR_UPSTREAM_STATUS=false`: un 404 o un 503 del gateway salen como **HTTP 200**
hacia el bastión, con el error escondido en `.upstream.status`.

**Consecuencia:** toda verificación mira `.upstream.status`, **nunca** `%{http_code}`. Un
`curl -w '%{http_code}'` contra la entrada da verde con el cutover roto.

---

<a id="h6"></a>
## H6. `spec.rules[].name` se poda en silencio — 2026-08-04

Es un campo reciente de Gateway API y el CRD de este cluster no lo tiene. El API server lo
**descarta al aplicar**: `oc apply` sale bien, el objeto queda `Accepted=True` y el campo no está.

**Consecuencia:** no detectar fases del rollout por el nombre de la rule. `run-escenarios.sh` las
detecta por el header match, que sí sobrevive. Vale como advertencia general: **un `apply`
exitoso no prueba que el spec haya quedado completo.**

---

<a id="h7"></a>
## H7. Cutover contra el gateway equivocado — 2026-08-04

El `Service server2` tenía el selector apuntando a `gw-echoserver` —el gateway de *entrada* del
app— en vez de a `egress-gw`. Su listener es el 80 y `server2` declara `targetPort: 8080`: no
había nadie escuchando ahí, y el BFF devolvía 502 con `Connection refused`.

**Consecuencia:** el assert anti-loop y la verificación de endpoints quedaron como gate en E0. El
riesgo hermano es peor: si el `backendRef` del HTTPRoute apuntara a `server2` en vez de
`server2-local`, post-cutover el Service selecciona los pods del propio gateway y el loop es
infinito entre Envoy y kube-proxy, con una firma por vuelta. Ningún contador de la app lo frena.

---

<a id="h8"></a>
## H8. `ServiceEntry` con `resolution: DNS` ignora `endpoints` — 2026-08-05

Para simular el destino se declaró el FQDN real con `resolution: DNS` y un bloque `endpoints`
apuntando al stand-in local, creyendo que los endpoints pisaban la resolución. **No la pisan:**
Envoy resolvió el FQDN por DNS al NLB de EKS —inalcanzable— y el request colgó hasta el timeout
del cliente, 5008 ms contra un `UPSTREAM_TIMEOUT_MS` de 5000.

El síntoma no señala a DNS: se ve como un backend que no responde.

**Consecuencia:** `resolution: STATIC` con una IP, que no resuelve nada. Es la única forma segura
de secuestrar un FQDN que ya resuelve a otra cosa. Y la comprobación que faltaba: leer los
clusters del Envoy y ver a qué IP apunta realmente.

---

<a id="h10"></a>
## H10. `x-request-id` se regenera en el gateway — 2026-08-04

Medido sobre un mismo request: entró al BFF `c1c30af4…`, salió del BFF `c1c30af4…` (el cliente lo
propaga fiel) y llegó al backend `1c60e4f2…`. Es el comportamiento por defecto de Envoy como edge
proxy (`preserve_external_request_id: false`), no un defecto de la cadena.

**Consecuencia:** un log del origen y uno del destino **no se van a poder unir por ese id**. Se
resuelve con un `EnvoyFilter` que ponga `preserve_external_request_id: true`, o adoptando
`traceparent`, que Envoy sí propaga. Definirlo **antes** de que haya dos clusters.

---

<a id="h11"></a>
## H11. El claim `sub` no identifica a nadie — 2026-08-04

Los tokens traen un `sub: 556cb5a2…` que **no está en `origen/05`**: lo agrega Authorino
derivándolo de la identidad, y la identidad es `anonymous`. Es estable y parece un principal.

**Consecuencia:** no autorizar por ese `sub` en el destino, ni darlo por prueba de que el
pendiente de identidad de workload esté resuelto.

---

<a id="h12"></a>
## H12. El destino real confirma que el Host viaja sin reescribir — 2026-08-05

Verificado contra el cluster EKS, no contra el stand-in. Desde un pod de `paas-arqlab`, sobre el
NLB del destino y con SNI `app2.paas-demo.bancogalicia.com.ar`:

| `Host` enviado | Respuesta |
|---|---|
| `server2.echoserver.svc.cluster.local:8080` | **401** + `www-authenticate: x-egress-token realm="egress-wristband"` |
| `app2.paas-demo.bancogalicia.com.ar` | 404 |
| el FQDN del NLB | 404 |

El 401 aparece **sólo con el Host interno**. Eso demuestra tres cosas de una:

1. El `HTTPRoute` del destino engancha por el Host del cliente original, o sea que **la decisión de
   §4 —no reescribir el Host, fijar el SNI en el `DestinationRule`— funciona contra el destino
   real** y no sólo contra el simulador.
2. El destino corre **Kuadrant, no Istio**: ese `realm` es el nombre de la identity source de la
   propia `AuthPolicy` del diseño. La Opción B del ADR está desplegada y enforceando.
3. La conectividad y el certificado están bien: el TLS cierra en 182 ms y los SAN del certificado
   del destino cubren `app2.paas-demo.bancogalicia.com.ar`.

**Lo que falta**, y es lo único: un wristband válido también recibe 401. La clave pública pineada
en el destino corresponde a una versión anterior del par de firma — se regeneró varias veces
durante la PoC. **El `kid` no lo delata**: es `egress-echoserver-1` en los dos lados, así que
coincide mientras la firma no valida, y el síntoma es un 401 con body vacío indistinguible de un
request sin credencial. Es exactamente el modo de falla que advierte `keys/gen-signing-key.sh`.

**Consecuencia:** el cierre de punta a punta depende de sincronizar esa clave — ver
[`pedido-jwks-eks.md`](pedido-jwks-eks.md). Nada del lado origen tiene que cambiar.

---

<a id="h13"></a>
## H13. La prueba negativa de firma alterada no alteraba nada — 2026-08-05

El test invalidaba la firma cambiando su **último carácter** (`${TOKEN%?}X`). En base64url ese
carácter aporta sólo 2 bits significativos; los otros 4 son relleno que el decodificador
descarta. El token real terminaba en `Q` (`010000`) y `X` es `010111`: **los 2 bits que importan
son idénticos**, así que el token "alterado" era byte a byte el mismo y el destino lo aceptó con
toda razón.

Durante un rato pareció un agujero de seguridad del destino. El agujero estaba en el test.

**Consecuencia:** la mutación va en el medio de la firma, donde siempre cambia un byte real.
Vale como recordatorio: **una prueba negativa que no falla puede estar mal construida**, y eso es
más probable que haber encontrado un bug de seguridad.
