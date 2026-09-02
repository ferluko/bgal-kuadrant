# `eks-origen-envoygw/` — reemplazo de Istio por Gateway API estándar + Envoy Gateway

**Estado: PROBADO EN VIVO contra el cutover real en cuatro rondas (2026-08-26) y REVERTIDO las
cuatro veces.** No queda nada aplicado en `cilium-1-35` — se restauró el estado original
(`gatewayClassName: istio`, `backendRefs` con la extensión `kind: Hostname`, `AuthPolicy` de
Kuadrant) en los cuatro casos. **La Ronda 4 encontró una solución que funciona de punta a
punta** (tráfico real autorizado, confirmado con logs de Authorino) — ver la sección
"LA SOLUCIÓN" más abajo. Los cuatro problemas que llevaron hasta ahí, con sus workarounds, están
documentados en orden debajo de eso.

## Ronda 1 — corte por namespace del pod

1. Se instaló Envoy Gateway v1.2.0, se creó la `GatewayClass envoy-gateway`, y se aplicó
   `01-gateway-egress.yaml` sobre el `Gateway egress-gw` real (in-place, mismo nombre/namespace
   que el cutover en vivo).
2. Se aplicó `02-service-endpointslice-destino.yaml` — **funcionó**: a diferencia de Istio (donde
   `EndpointSlice(FQDN)` nunca resuelve, ver el hallazgo del spike contra `httpbin.org`), Envoy
   Gateway sí puebla el cluster de Envoy con el endpoint FQDN cuando es el único backend de la
   ruta. El `ServiceEntry` original queda genuinamente reemplazable con este provider, con matices
   (ver Problema 3).
3. Se aplicó `03-httproute-egress.yaml` → **corte de tráfico real**, `backend:8080` empezó a
   devolver `Connection refused`. Revertido de inmediato.

### Problema 1 — el cutover por selector se rompe

`09-cutover-service-selector.yaml` depende de que el pod del gateway viva en el **mismo
namespace** que el Service `backend` (Kubernetes no permite que un Service seleccione pods de
otro namespace — no es un bug, es la regla). Con Istio, el pod de `egress-gw` se crea en
`poc-ingress-kuadrant` (mismo ns que el `Gateway`). **Con Envoy Gateway, el pod se crea en
`envoy-gateway-system`** — el namespace del controller, no el de la app. El selector deja de
encontrar nada.

## Ronda 2 — con el workaround de la Ronda 1, dos problemas nuevos

Se reinstaló todo, esta vez con el fix del Problema 2 incluido desde el arranque, y con el
`ExternalName` de `09-cutover-service-selector.yaml` aplicado para probar el workaround del
Problema 1.

### El workaround del Problema 1 SÍ funciona

Convertir `backend` en un `Service` `type: ExternalName` apuntando al FQDN cross-namespace del
Service que Envoy Gateway crea automáticamente
(`envoy-poc-ingress-kuadrant-egress-gw-<hash>.envoy-gateway-system.svc.cluster.local`) — el DNS
resolvió al `ClusterIP` correcto, y una prueba directa por esa IP (sin pasar por el `HTTPRoute`)
devolvió `404` de Envoy, confirmando que la conectividad cruzando namespaces es real. El `<hash>`
se mantuvo idéntico entre las dos rondas (cambiar solo `gatewayClassName` in-place, sin borrar el
objeto `Gateway`) — no se confirmó si sobrevive a un borrado y recreación real del `Gateway`, que
es el escenario donde podría cambiar.

Con el `ExternalName` resuelto, el tráfico igual **volvió a fallar** — por dos motivos nuevos, no
relacionados al namespace:

### Problema 3 — mezclar backend local (IP) y remoto (FQDN) en la misma regla rompe la ruta

La ruta real tiene DOS `backendRefs` con peso 50/50: `backend-local` (Service normal, IP real) y
`backend-destino` (Service respaldado por `EndpointSlice(FQDN)`). Envoy Gateway logueó:

```
Mixed endpointslice address type between backendRefs is not supported
```

Y, confirmado inspeccionando el cluster real de Envoy (`/clusters` del admin): **solo quedó UN
endpoint configurado** (el de `backend-local`, IP real) — el backend FQDN se cayó silenciosamente
de la configuración combinada, sin importar el `weight` declarado. **Aislado (un solo
`backendRef`, solo `backend-destino`, sin mezclar)**, el FQDN sí se resuelve a un endpoint real
(`10.254.124.36:80`) — el problema es específicamente la combinación de tipos de address en la
misma regla, no el FQDN por sí solo.

### Problema 4 — causa raíz real, encontrada en la Ronda 3: incompatibilidad binaria del wasm-shim

Con `backend-destino` como único `backendRef` (sin mezcla), el endpoint se resolvía pero **las
requests igual colgaban hasta timeout** (`cx_total: 0` en las stats de Envoy). La hipótesis
inicial ("Kuadrant no se engancha solo a Envoy Gateway") **era incorrecta** — Kuadrant sí tiene
un mecanismo real: `EnvoyExtensionPolicy` (plugin Wasm) + `EnvoyPatchPolicy` (cluster hacia
Authorino), documentado oficialmente por el proyecto
([Kuadrant Architectural Overview](https://docs.kuadrant.io/1.2.x/architecture/docs/design/architectural-overview-v1/)).
Se investigó con paciencia en una tercera ronda:

1. **Primer hallazgo real**: `EnvoyPatchPolicy` viene **deshabilitado por defecto** en Envoy
   Gateway — el status decía literalmente `"EnvoyPatchPolicy is disabled in the EnvoyGateway
   configuration"`. Se corrigió con `config.envoyGateway.extensionApis.enableEnvoyPatchPolicy:
   true` en los values del Helm chart. Con eso, ambas políticas de Kuadrant pasaron a
   `Accepted: True`.
2. **Causa raíz definitiva, con eso ya resuelto**: el tráfico seguía colgando. Los logs del propio
   proxy de Envoy mostraban:
   ```
   Failed to load Wasm module due to a missing import: wasi_snapshot_preview1.sched_yield
   Wasm VM failed Failed to initialize Wasm code
   Plugin configured to fail closed failed to load
   ```
   El binario `quay.io/kuadrant/wasm-shim:v0.12.1` que usa Kuadrant **no es compatible con el
   runtime WASM que trae empaquetado Envoy Gateway v1.2.0** — le falta una función WASI
   (`sched_yield`) que el plugin necesita para inicializar. Como el plugin está configurado
   fail-closed (postura de seguridad correcta: si el plugin de auth no carga, no dejar pasar
   tráfico sin autenticar), el resultado es que **todo el tráfico queda colgado indefinidamente**
   en vez de fallar con un error claro — de ahí el timeout, no un `503` inmediato.

## LA SOLUCIÓN — Ronda 4: bypass del plugin Wasm, probado en vivo y FUNCIONA

En vez de esperar una combinación de versiones compatible (no confirmada, sin acceso a la matriz
oficial), se armó un camino alternativo que evita el plugin Wasm de Kuadrant por completo,
usando piezas 100% nativas de Envoy Gateway + Authorino directo. **Probado en vivo — tráfico real
autorizado de punta a punta, confirmado con logs de Authorino (`authorized: true` en las 5
requests de prueba).**

### Los tres cambios respecto del intento con Kuadrant/AuthPolicy

1. **`Gateway` sin la label `kuadrant.io/gateway: "true"`** — de todas formas no alcanza solo,
   Kuadrant igual intenta enganchar el plugin Wasm mientras exista un `AuthPolicy` apuntando a una
   ruta de ese Gateway (el trigger real es el `AuthPolicy`, no la label).
2. **Borrar el `AuthPolicy`** (`kubectl delete authpolicy egress-backend-jwt`) — esto es lo que
   efectivamente detiene a Kuadrant de recrear el `EnvoyExtensionPolicy`/`EnvoyPatchPolicy` rotos,
   liberando el listener para que acepte cualquier otra config.
3. **Reemplazar el wiring de Kuadrant por dos piezas nativas de Gateway API/Envoy Gateway**:

   **a) `SecurityPolicy`** (extensión propia de Envoy Gateway, no Kuadrant) — configura `ext_authz`
   nativo de Envoy apuntando directo al gRPC de Authorino, sin ningún plugin Wasm de por medio:
   ```yaml
   apiVersion: gateway.envoyproxy.io/v1alpha1
   kind: SecurityPolicy
   metadata:
     name: egress-backend-authorino
     namespace: poc-ingress-kuadrant
   spec:
     targetRefs:
       - group: gateway.networking.k8s.io
         kind: HTTPRoute
         name: egress-backend
     extAuth:
       grpc:
         backendRefs:
           - group: ""
             kind: Service
             name: authorino-authorino-authorization
             namespace: kuadrant-system
             port: 50051
   ```
   Necesita un `ReferenceGrant` en `kuadrant-system` para permitir la referencia cross-namespace
   (regla estándar de seguridad de Gateway API, no algo específico de este caso):
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1beta1
   kind: ReferenceGrant
   metadata:
     name: allow-securitypolicy-to-authorino
     namespace: kuadrant-system
   spec:
     from:
       - group: gateway.envoyproxy.io
         kind: SecurityPolicy
         namespace: poc-ingress-kuadrant
     to:
       - group: ""
         kind: Service
         name: authorino-authorino-authorization
   ```

   **b) `AuthConfig` manual** (`authorino.kuadrant.io/v1beta3`, aplicado directo, sin `AuthPolicy`
   de por medio) — acá está el segundo hallazgo importante: el `AuthConfig` que genera Kuadrant
   normalmente usa un **host sintético** (un hash, ej. `cfb5fab78fad...`) como clave de
   `spec.hosts`, no el hostname real — porque el wasm-shim resuelve la ruta/acción por su cuenta y
   le pasa ese contexto a Authorino. Un `ext_authz` nativo de Envoy, en cambio, le manda a
   Authorino el `:authority` REAL de la request — así que el `AuthConfig` tiene que tener el
   hostname real en `spec.hosts`, no el hash. Se replicó a mano el `spec` del `AuthConfig`
   original (mismo wristband, mismos claims, misma clave de firma) pero con
   `hosts: ["backend", "backend.poc-ingress-kuadrant", "backend.poc-ingress-kuadrant.svc",
   "backend.poc-ingress-kuadrant.svc.cluster.local"]` en vez del hash.

### El costo de esta solución

**Se pierde la gestión declarativa vía `AuthPolicy`** — con este camino, el `AuthConfig` se
mantiene a mano (o con tooling propio), no autogenerado por Kuadrant a partir de un CR de alto
nivel. Sigue siendo Authorino real haciendo la autorización real (mismo wristband, misma clave de
firma, mismo resultado), pero se pierde la capa de abstracción y gestión de Kuadrant para este
Gateway puntual. Es el trade-off real de evitar el bug del wasm-shim: correcto y funcional, pero
más manual.

### Problema 2 — exposición pública momentánea (Ronda 1, corregido antes de la Ronda 2)

Envoy Gateway crea por defecto un `Service` `type: LoadBalancer` (NLB real) para el Gateway, sin
las annotations de `scheme: internal` que Istio necesitaba explícitamente. Con
`AuthPolicy: anonymous` en este gateway, eso es una ventana real de exposición. Se corrigió con un
recurso `EnvoyProxy` (`spec.provider.kubernetes.envoyService.type: ClusterIP`) referenciado desde
`spec.infrastructure.parametersRef` del `Gateway` — confirmado en la Ronda 2 que aplicándolo desde
el arranque el `Service` sale `ClusterIP` directo, sin ventana de exposición.

## Resumen de lo que sí y no funciona con Envoy Gateway

| Pieza | Resultado |
|---|---|
| `EndpointSlice(FQDN)` como único backend de una ruta | Funciona |
| `EndpointSlice(FQDN)` mezclado con un backend de tipo Service normal en la misma regla | **No funciona** — se cae silenciosamente de la config |
| Exposición del Service (`ClusterIP` vs `LoadBalancer`) | Funciona, pero hay que configurarlo explícito (`EnvoyProxy`), no es el default |
| Cutover por selector de labels cross-namespace | No funciona nativamente — workaround `ExternalName` sí funciona, con caveat de estabilidad del hash |
| Kuadrant `EnvoyExtensionPolicy`/`EnvoyPatchPolicy` (el wiring en sí) | Existe y se generó bien, una vez habilitado `enableEnvoyPatchPolicy` (apagado por defecto) |
| Plugin Wasm de Kuadrant (`wasm-shim:v0.12.1`) cargando en Envoy Gateway v1.2.0 | **No** — incompatibilidad binaria confirmada (`missing import: wasi_snapshot_preview1.sched_yield`), fail-closed |
| `SecurityPolicy` nativo (`ext_authz` gRPC directo a Authorino) + `AuthConfig` manual | **SÍ funciona** — probado en vivo, tráfico real autorizado de punta a punta (Ronda 4) |
| `BackendTLSPolicy`/`BackendTrafficPolicy` | No se llegó a probar (puerto 443 diferido en el original por el bloqueo §7.2 de OCP) |

## Antes de volver a intentar esto en vivo

1. Usar el camino de la Ronda 4 (`SecurityPolicy` + `AuthConfig` manual) en vez de esperar una
   versión compatible de `wasm-shim` — es la solución confirmada, no un mapeo teórico.
2. Definir cómo se va a mantener el `AuthConfig` manual a largo plazo (Terraform/GitOps propio,
   ya que deja de estar autogenerado por el `AuthPolicy` de Kuadrant) — es el costo real de este
   camino.
3. El reparto 50/50 real (Problema 3) necesita que AMBOS backends sean del mismo tipo de
   address — evaluar si convertir `backend-local` también a un patrón FQDN/EndpointSlice
   homogéneo evita el problema, sin confirmar.
4. Incluir el fix de `EnvoyProxy`/`ClusterIP` desde el arranque (ya confirmado que funciona).
5. Confirmar la estabilidad del `<hash>` del Service autogenerado ante un borrado real del
   `Gateway` (se mantuvo idéntico en tres rondas seguidas, pero siempre con el mismo objeto
   `Gateway`, nunca borrado y recreado desde cero).
6. El puerto 443/TLS sigue bloqueado por el §7.2 de SDS en OCP — no relacionado a este cambio.

## Nota aparte — lo que quedó de esta sesión, sin relación con Envoy Gateway

Durante la Ronda 1 se encontró y corrigió un incidente real preexistente: Karpenter llevaba 14
días roto en `cilium-1-35` (`EC2NodeClass.subnetSelectorTerms` buscaba un tag
(`karpenter.sh/discovery: devops-cilium-1-35`) que no matcheaba ningún subnet — el valor real era
`eks`). Eso dejó al cluster sin poder autoescalar durante una reclamación de nodos SPOT esa misma
mañana, con casi todo el workload real en `Pending` durante horas — cutover incluido, por una
causa totalmente ajena a esta migración. Se corrigió el selector en `main.tf` (cluster raíz, no
este borrador) y Karpenter volvió a autoescalar. Ese fix queda aplicado y no hay motivo para
revertirlo.
