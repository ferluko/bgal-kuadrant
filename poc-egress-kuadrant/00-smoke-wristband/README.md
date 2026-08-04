# Smoke test — AuthPolicy y wristband sobre `openshift-default`

**Correr esto ANTES que cualquier otra cosa de la PoC.** Valida en un solo cluster, sin TLS, sin
F5 y sin segundo cluster, las tres cosas de las que depende todo lo demás:

1. Que un `Gateway` de la clase `openshift-default` rutea a un backend interno.
2. Que una `AuthPolicy` de RHCL **se enforcea** sobre esa clase — no sólo que queda `Accepted`.
3. Que `response.success.headers` con **`wristband`** funciona: Authorino firma un JWT con una
   clave del namespace y lo **inyecta en el request que va al upstream**.

El punto 3 es el que nadie probó: el smoke test de
[la guía de instalación de RHCL](../../../01_apim/13_guia_instalacion_rhcl_ocp420.md) §5 cubre OPA
deny-all y API key, pero no el wristband. Es además el componente con más superficie de falla de
toda la PoC (clave, algoritmo, `kid`, inyección de header).

Si algo de esto falla, no tiene sentido montar el gateway de egreso, el TLS origination ni el
cluster destino.

Todo vive en `echoserver`, no toca ningún objeto existente y se borra entero al final.

---

## Preparación

```bash
../keys/gen-signing-key.sh
oc apply -f ../keys/out/secret.yaml          # Secret egress-echoserver-1 en ns kuadrant-system
oc -n kuadrant-system get secret egress-echoserver-1 -o jsonpath='{.data}{"\n"}'   # debe tener key.pem
```

> **El Secret va en `kuadrant-system`, no en el namespace de la app.** Kuadrant traduce cada
> `AuthPolicy` a un `AuthConfig` en `kuadrant-system` y Authorino resuelve `signingKeyRefs` contra
> el namespace del **AuthConfig**, no el del `AuthPolicy`. Es el mismo motivo por el que el Secret
> de API key del smoke test de la guía de instalación de RHCL vive ahí. Ver el paso 3 para el
> síntoma exacto si se pone en el lugar equivocado.

## Paso 1 — routing (sin políticas)

```bash
oc apply -f 01-gateway-smoke.yaml
oc -n echoserver get gateway smoke-gw \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].message}{"\n"}'

oc apply -f 02-httproute-smoke.yaml
oc -n echoserver get httproute smoke-wristband \
  -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].message}{"\n"}'

oc -n echoserver run smoke-curl --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: smoke.egress.local' \
  http://smoke-gw-openshift-default.echoserver.svc.cluster.local:8080/
```

**Esperado: 200.** Si da 404, el route no enganchó (revisar `attachedRoutes` en el status del
Gateway). Si da 503, enganchó pero `server2` no tiene endpoints listos.

### LoadBalancer pendiente

Si el `Gateway` se creó **sin** la annotation `networking.istio.io/service-type: ClusterIP`, el
controller genera un Service `LoadBalancer` que en este cluster queda así:

```console
NAME                         TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)
smoke-gw-openshift-default   LoadBalancer   172.30.150.100   <pending>     15021:31154/TCP,8080:32118/TCP

Assigned to service(s) smoke-gw-openshift-default.echoserver.svc.cluster.local:8080,
but failed to assign to all requested addresses: address pending for hostname ...
```

**No bloquea el smoke test.** El mensaje dice `Assigned to service(s) ...:8080`, o sea que istiod
ya resolvió el mapeo de puertos y generó el listener de datos; lo único pendiente es la dirección
externa, que acá no existe porque el cluster no tiene proveedor de LB (IPI vSphere, el VIP de
ingress es `keepalived` atado a HAProxy). El curl por ClusterIP funciona igual.

Lo que sí conviene es corregirlo, y en el gateway de **egreso** no es opcional: un Service
`LoadBalancer` asigna nodePorts, y la `AuthPolicy` de egreso autentica con `anonymous` — cualquiera
que alcance ese nodePort obtendría un JWT firmado. La `NetworkPolicy` lo tapa, pero la exposición
no debería existir. Por eso `origen/01` lleva la annotation.

```bash
oc -n echoserver patch gateway smoke-gw --type merge \
  -p '{"metadata":{"annotations":{"networking.istio.io/service-type":"ClusterIP"}}}'
oc -n echoserver get svc -l gateway.networking.k8s.io/gateway-name=smoke-gw   # TYPE=ClusterIP, sin nodePorts
```

Si el Service sigue saliendo `LoadBalancer`, este controller no toma la annotation: probar la
variante con `infrastructure.parametersRef` comentada en `01-gateway-smoke.yaml`.

## Paso 2 — ¿enforcea de verdad?

```bash
oc apply -f 03-authpolicy-denyall.yaml
oc -n echoserver get authpolicy smoke-denyall \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}{"\n"}'

# mismo curl que el paso 1
```

**Esperado: 403.**

Un **200 con `Accepted=True` y `Enforced=True` es el peor resultado posible**: significa que el
operador aceptó y empujó la política pero el data plane de esta `GatewayClass` no tiene enganchado
el ext_authz de Kuadrant. Es un hallazgo de plataforma que hay que escalar antes de seguir — no se
arregla desde esta PoC.

```bash
oc -n echoserver delete authpolicy smoke-denyall
```

## Paso 3 — el wristband

```bash
oc apply -f 04-authpolicy-wristband.yaml
oc -n echoserver get authpolicy smoke-wristband \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}{"\n"}'

oc -n echoserver run smoke-curl --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sS -H 'Host: smoke.egress.local' \
  http://smoke-gw-openshift-default.echoserver.svc.cluster.local:8080/
```

**Esperado: 200 y, en el cuerpo reflejado por el echo server, un header `x-egress-token` con un
JWT** (tres segmentos separados por punto, empezando en `eyJ`).

### Si no devuelve 200 con el header

Primero mirar si el `AuthPolicy` llegó a sincronizar:

```bash
oc -n echoserver get authpolicy smoke-wristband \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}{"\n"}'
oc -n kuadrant-system logs deploy/authorino --tail=100 | grep -Ei 'Reconciler error|wristband'
```

**Síntoma más común — el Secret en el namespace equivocado:**

```
AuthPolicy waiting for the following components to sync: [AuthConfig (ab6349c1...)]

Reconciler error ... "AuthConfig":{"name":"ab6349c1...","namespace":"kuadrant-system"},
                     "error":"Secret \"egress-echoserver-1\" not found"

outgoing authorization response ... "authorized":false,"response":"NOT_FOUND",
                                    "message":"Service not found"
```

El `AuthConfig` vive en `kuadrant-system` aunque el `AuthPolicy` esté en `echoserver`, y ahí busca
el Secret. Fix: `../keys/gen-signing-key.sh` (ya genera el Secret con
`namespace: kuadrant-system`) y reaplicar.

> Un dato valioso escondido en ese error: **si Authorino loguea `incoming authorization request`,
> el paso 2 ya está probado.** El ext_authz está enganchado al data plane de `openshift-default`
> y Kuadrant enforcea; lo que falla es la config, no el camino.

Si el 200 llega **sin** el header y el `AuthConfig` sí sincronizó, el problema es la emisión del
wristband: revisar que el Secret tenga la entrada `key.pem` y que el `algorithm` del
`signingKeyRefs` coincida con la clave (`ES256` para una EC P-256).

## Paso 4 — validar el token contra el JWKS que va a ir al destino

Este paso mata por adelantado el riesgo del `kid` y prueba que la clave pública que se pinea en el
cluster destino efectivamente verifica lo que el origen firma.

```bash
./check-token.py '<pegar el x-egress-token>' ../keys/out/jwks.json
```

Comprueba `alg=ES256`, `exp` ≈ 300s, los claims (`iss`, `aud`, `src_cluster`, `src_namespace`,
`dst_service`), que el `kid` del token esté en el JWKS, y **verifica la firma**.

Si avisa que el `kid` no coincide, regenerar el JWKS con el `kid` real
(`../keys/gen-signing-key.sh <kid-real>`) o editarlo en `destino/11-jwks-static.yaml`. Sin esto, el
destino rechazaría todos los tokens y el síntoma aparecería recién con los dos clusters montados.

## Limpieza

```bash
oc -n echoserver delete authpolicy smoke-wristband
oc -n echoserver delete httproute smoke-wristband
oc -n echoserver delete gateway smoke-gw
```

El Secret de firma se conserva: es el mismo que usa `origen/05`.

---

## Criterio de salida

| Paso | Resultado | Sin esto |
|---|---|---|
| 1 | 200 | no hay routing; nada de la PoC funciona |
| 2 | 403 | Kuadrant no enforcea sobre `openshift-default` → escalar a plataforma |
| 3 | 200 + header `x-egress-token` | no hay inyección de JWT; hay que ir al firmador propio (README §8.6) |
| 4 | firma válida y `kid` coincidente | el destino rechazaría todo, con síntoma tardío |

Los cuatro en verde habilitan la etapa A del [README principal](../README.md#6-orden-de-aplicación).
