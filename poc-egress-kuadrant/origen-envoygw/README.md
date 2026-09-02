# `origen-envoygw/` — borrador: reemplazo de Istio por Gateway API estándar + Envoy Gateway

**Estado: borrador para revisión, no aplicado ni probado contra el cluster OCP real
(paas-arqlab).** Espejo de [`../origen/`](../origen/), archivo por archivo, con cada pieza
Istio-específica reemplazada por su equivalente en Gateway API estándar u otro provider
(Envoy Gateway).

## Qué cambia y por qué

| Archivo original (Istio) | Reemplazo acá | Estado |
|---|---|---|
| `01-gateway-egress.yaml` — `gatewayClassName: openshift-default` | `gatewayClassName: envoy-gateway` | Requiere instalar Envoy Gateway como segundo controller (ver comentario del archivo) |
| `02-serviceentry-destino.yaml` | `Service` sin selector + `EndpointSlice(addressType: FQDN)` | **Probado en vivo contra `cilium-1-35` y NO funciona con Istio** — ver más abajo. Con Envoy Gateway sí es el patrón documentado. |
| `03-httproute-egress.yaml` — `backendRef` con `group: networking.istio.io, kind: Hostname` | `backendRef` estándar `kind: Service` | Mecánico, sin riesgo — es Gateway API core |
| `04-destinationrule-tls.yaml` — TLS origination | `BackendTLSPolicy` (Gateway API Standard desde v1.4) | Cubre TLS. **No cubre el `connectionPool`** — ver el gap abajo |
| `05-authpolicy-wristband.yaml` | Sin cambios | Kuadrant/Authorino es agnóstico del Gateway API provider |
| `06-service-backend-local.yaml`, `07-networkpolicy.yaml` | Sin cambios | Ya usaban API core de Kubernetes, nada Istio-específico |
| `09-cutover-service-selector.yaml` | **SE ROMPE con Envoy Gateway** — workaround adentro del archivo | Confirmado en vivo del lado análogo EKS→OCP, ver más abajo |
| `08-rollout/*.yaml` | Mismo `backendRef` estándar aplicado a las 6 variantes de rollout | Transformación mecánica del mismo cambio de 03 |

## El hallazgo que motiva el caveat más importante

Antes de escribir estos archivos, probé el patrón `EndpointSlice(FQDN)` + `BackendTLSPolicy`
en un namespace descartable contra **`cilium-1-35`** (Istio 1.30.2, la misma familia que usa
OSSM en OpenShift por debajo de `gatewayClassName: openshift-default`). Resultado: **503 "no
healthy upstream"** — el log de `istiod` dice explícitamente `has no endpoints`. Istio arma el
cluster de Envoy pero nunca lo puebla con el endpoint FQDN.

**Conclusión**: este patrón no es un reemplazo de `ServiceEntry` mientras el provider sea
Istio/OSSM. Solo tiene sentido si además se instala **Envoy Gateway** como controller
alternativo — no se probó eso en vivo (esta sesión no tiene acceso al cluster OCP real), pero
sí es el patrón oficialmente documentado por el proyecto Envoy Gateway.

## Los hallazgos más graves: cuatro problemas reales, probados en vivo del lado EKS→OCP

Se probó el cutover real con Envoy Gateway, dos rondas, del lado análogo
(`poc-ingress-kuadrant/eks-origen-envoygw/`, mismo patrón, dirección EKS→OCP) contra
`cilium-1-35`. **Cortó tráfico real las dos veces**, por motivos distintos. Detalle completo con
logs y comandos en
[`poc-ingress-kuadrant/eks-origen-envoygw/README.md`](../../poc-ingress-kuadrant/eks-origen-envoygw/README.md).
Ninguno de los cuatro se reprodujo en este cluster OCP puntual (sin acceso desde esta sesión),
pero todos son mecanismos de Gateway API/Kuadrant estándar de los dos lados — asumir que aplican
igual acá:

1. **Cutover por selector roto** (Ronda 1, cortó tráfico): el pod del gateway con Envoy Gateway
   se crea en el namespace del controller (`envoy-gateway-system`), no en el de la app — un
   Service de Kubernetes no puede seleccionar pods de otro namespace. Workaround probado y
   confirmado que funciona a nivel de conectividad: `Service type: ExternalName` apuntando al
   nombre autogenerado cross-namespace (con su propio problema de estabilidad del hash) — está
   documentado dentro de `09-cutover-service-selector.yaml`.
2. **Mezclar backend local (IP) y remoto (FQDN) en la misma regla rompe la ruta**: con los dos
   `backendRefs` de peso 50/50 (uno `Service` normal, otro respaldado por `EndpointSlice(FQDN)`),
   Envoy Gateway loguea `Mixed endpointslice address type between backendRefs is not supported` y
   descarta el backend FQDN de la config combinada — sin importar el `weight`. Aislado (un solo
   backendRef, solo el FQDN), sí se resuelve.
3. **Causa raíz confirmada en una tercera ronda, y SOLUCIÓN encontrada y probada en una cuarta**:
   incompatibilidad binaria del plugin Wasm de Kuadrant. El wiring de Kuadrant con Envoy Gateway
   sí existe (`EnvoyExtensionPolicy`+`EnvoyPatchPolicy`) — primero hubo que habilitar
   `enableEnvoyPatchPolicy` (apagado por defecto en el Helm chart). Con eso resuelto, el tráfico
   igual colgaba: el binario `wasm-shim:v0.12.1` que usa Kuadrant no carga en el runtime WASM de
   Envoy Gateway v1.2.0 (`missing import: wasi_snapshot_preview1.sched_yield`), y al estar
   configurado fail-closed, todo el tráfico queda colgado en vez de fallar con un error claro.
   **La solución que funciona**: borrar el `AuthPolicy` de Kuadrant (detiene el reintento del
   plugin roto) y reemplazarlo por un `SecurityPolicy` nativo de Envoy Gateway (`ext_authz` gRPC
   directo a Authorino, sin plugin Wasm) + un `AuthConfig` mantenido a mano (Kuadrant genera el
   suyo con un host sintético como clave, que un `ext_authz` nativo no puede matchear — hay que
   recrearlo con el hostname real). Probado en vivo, tráfico real autorizado de punta a punta.
   Manifests y detalle completo en
   [`poc-ingress-kuadrant/eks-origen-envoygw/`](../../poc-ingress-kuadrant/eks-origen-envoygw/)
   (archivos `10-securitypolicy-authorino.yaml`, `11-authconfig-manual.yaml`, y el README).
4. **Exposición pública momentánea** (encontrada y corregida en el momento): Envoy Gateway crea
   por defecto `Service type: LoadBalancer`, no `ClusterIP` — con `AuthPolicy: anonymous`, eso es
   una ventana real de exposición. Se corrigió con un recurso `EnvoyProxy`
   (`envoyService.type: ClusterIP`) referenciado desde `spec.infrastructure.parametersRef` —
   confirmado que, aplicado desde el arranque, evita la ventana de exposición.

## El gap sin resolver: `connectionPool`

El `DestinationRule` original no es solo TLS — también carga el `connectionPool`
(`maxConnections: 64`, `connectTimeout: 5s`, `idleTimeout: 300s`) que **evitó un incidente real
medido en producción** (503 `URX,UF` contra el RTT real de EKS, ~170ms). `BackendTLSPolicy` no
tiene campo equivalente — es Gateway API estándar y solo cubre TLS.

`04-backendtlspolicy-destino.yaml` incluye un `BackendTrafficPolicy` (extensión propia de Envoy
Gateway, no Gateway API estándar) como mapeo best-effort, **sin verificar campo por campo**
contra la versión de Envoy Gateway instalada — hay que confirmarlo con
`kubectl explain backendtrafficpolicy.spec` antes de confiar en él, y repetir la medición de
RTT real que motivó los valores originales.

## Lo que no se tocó (fuera de alcance)

- El resto del cluster `cilium-1-35`/`null-alfa-136` sigue en Istio — esto es un borrador
  aislado a este flujo puntual, no una propuesta de migración cluster-wide.
- `EndpointSlice(addressType: FQDN)` salió con un warning de Kubernetes al aplicarlo
  (`spec.addressType: FQDN endpoints are deprecated`) — no confirmado el estado real de esa
  deprecación ni si Envoy Gateway va a requerir migrar a su propio recurso `Backend` en el
  mediano plazo (ver [Routing outside Kubernetes](https://gateway.envoyproxy.io/v1.5/tasks/traffic/routing-outside-kubernetes/)).

## Antes de aplicar esto de verdad

1. Resolver primero el enganche de Kuadrant/Authorino con Envoy Gateway (problema 3) — sin esto,
   ni un backend aislado sirve tráfico real, es el bloqueante más profundo de los cuatro.
2. Resolver el cutover por selector (workaround `ExternalName` ya confirmado a nivel de
   conectividad, sin confirmar estabilidad del hash ante recreación real del `Gateway`).
3. Si hace falta reparto por peso entre backend local y remoto, evaluar si homogeneizar el tipo
   de address de ambos backends evita el problema de mezcla (problema 2) — sin confirmar.
4. Incluir el fix de `EnvoyProxy`/`ClusterIP` desde el arranque en `01-gateway-egress.yaml`
   (confirmado que funciona), no como reacción.
5. Instalar Envoy Gateway en el cluster OCP real y confirmar que expone una `GatewayClass`
   aceptada.
6. Aplicar `02-service-endpointslice-destino.yaml` solo y confirmar que el `Service` sí resuelve
   endpoints reales (a diferencia de lo que pasó en Istio) — no asumir que el resultado en
   `cilium-1-35` no aplica acá, pero tampoco asumir que Envoy Gateway se comporta distinto sin
   confirmarlo en el cluster real.
5. Confirmar los campos de `BackendTrafficPolicy` contra la versión instalada, y repetir la
   medición de RTT real antes de dar por buena la tuning de conexión.
