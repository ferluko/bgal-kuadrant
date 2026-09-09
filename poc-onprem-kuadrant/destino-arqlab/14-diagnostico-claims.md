# Hallazgo de claims — **CAUSA RAÍZ ENCONTRADA (2026-09-09)**

## Resumen

Las `AuthPolicy` sobre el gateway `gw-hostnet` **nunca estuvieron enforceadas**. Kuadrant lo dice
en el status, con todas las letras:

```console
$ oc --context=paas-arqlab -n poc-ingress-kuadrant get authpolicy \
    -o custom-columns='NOMBRE:.metadata.name,TARGET:.spec.targetRef.name,ACC:…Accepted,ENF:…Enforced'
NOMBRE                         TARGET        ACC    ENF
backend-ingress-jwt            backend       True   False
backend-ingress-vault-spiffe   backend       True   False
backend-lab-vault-spiffe       backend-lab   True   False

$ … -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}'
AuthPolicy waiting for the following components to sync: [Gateway (connlink-ingress/gw-hostnet)]
```

**Las tres en `Enforced: False`.** No hay autorización aplicándose sobre ese gateway. Por eso pasó
el `sub` impostor: no es que la evaluación diera verdadero — **no hubo evaluación**.

## Por qué costó tanto

El 2026-09-02 se vio este mismo `Enforced: False` y se concluyó que era *"un estado transitorio
justo después de crear el recurso"*. **No lo era.** Semanas después sigue igual. Esa lectura
errónea desvió toda la investigación hacia mecanismos invisibles, y de ahí salieron dos hipótesis
que después hubo que refutar una por una.

La lección operativa: **un `Enforced: False` que persiste no es transitorio**, y su `message` suele
decir exactamente qué falta. Leerlo antes de teorizar.

## Por qué la config de Envoy no contradecía esto

El `config_dump` del `gw-hostnet` tiene 63 `authorino`, 7 `ext_authz` y 149 `kuadrant`, y eso
parecía descartar "Kuadrant no está actuando". No lo descarta:

Kuadrant instala el filtro `ext_authz` / wasm-shim en cuanto el `Gateway` lleva la label
`kuadrant.io/gateway: "true"`. Las **action sets** —las reglas que deciden a qué requests llamar a
Authorino— se pueblan recién cuando una policy queda `Enforced`. Con el filtro presente y sin
action sets, **todo request pasa de largo sin que se loguee nada**.

Encaja con los cuatro síntomas a la vez, incluido el más desconcertante:

| Síntoma | Explicación |
|---|---|
| El impostor pasa con 200 | no hay action set: nunca se llama a Authorino |
| `Accepted: True` | la policy es válida y Kuadrant la aceptó |
| Filtros presentes en Envoy | se instalan por la label del Gateway, no por la policy |
| Cero errores en logs | no hay error: no se ejecuta nada |

## Hipótesis descartadas en el camino — no volver sobre ellas

1. **✗ Poda del campo `predicate` por schema del CRD.** Refutada: los tres predicados están
   completos en el objeto guardado (`jq '..|.predicate? // empty'`).
2. **✗ istiod no le empuja el `ext_authz` al gateway desplegado a mano.** Refutada por el
   `config_dump` de arriba. Iba en la dirección correcta pero se verificó lo que no era: la
   pregunta no era *"¿está el filtro?"* sino *"¿Kuadrant considera sincronizado al gateway?"*.

## Lo que falta: por qué no sincroniza

El mensaje apunta a `Gateway (connlink-ingress/gw-hostnet)`. Ese gateway es de la GatewayClass
`ingress-hostnet`, servida por un controller propio (`istio.io/ingress-hostnet-controller`) y un
istiod aparte (`istiod-ingress-gw`, ver `runbook-gw-istio-hostnetwork.md`), distinto del que
maneja `openshift-default`.

Hipótesis de trabajo — **verificar antes de darla por buena**: el `kuadrant-operator` confirma la
sincronización contra el istiod que él conoce, y para un gateway servido por otro istiod esa
confirmación nunca llega.

El experimento de control es directo, y ya existe en el cluster: `egress-gw` de
`poc-egress-kuadrant` es `openshift-default` y su `AuthPolicy` sí estaba `Enforced: True`.

```bash
# ¿Enforcea sobre openshift-default y no sobre ingress-hostnet?
oc --context=paas-arqlab get authpolicy -A \
  -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,TARGET:.spec.targetRef.name,ENF:.status.conditions[?(@.type=="Enforced")].status'

# la clase de cada gateway, para cruzar
oc --context=paas-arqlab get gateway -A \
  -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,CLASE:.spec.gatewayClassName'

# qué dice el operador de este gateway
oc --context=paas-arqlab -n kuadrant-system logs deploy/kuadrant-operator-controller-manager \
  | grep -i 'gw-hostnet\|sync' | tail -30
```

Si el corte es limpio por GatewayClass, la causa está identificada y hay dos salidas:

1. **Usar un gateway de `openshift-default` para el ingreso de la PoC** — vuelve a poner sobre la
   mesa el diseño de `11-DESCARTADO-gateway-propio.md`, ahora por un motivo mucho mejor
   fundado que el original (el SDS ya no era el problema; esto sí lo es).
2. **Hacer que Kuadrant reconozca el gateway de `ingress-hostnet`** — caso de soporte con Red Hat.
   Es la salida correcta a largo plazo si `gw-hostnet` va a ser el ingreso productivo, porque
   *ninguna* `AuthPolicy` funciona sobre él hoy.

## La consecuencia que hay que subir, no dejar en el repo

Esto excede a la PoC. **El ingreso `gw-hostnet` no está aplicando ninguna política de
autorización de Kuadrant**, y su status lo viene diciendo desde que se creó. Cualquier cosa
publicada por ahí que se crea protegida por una `AuthPolicy`, no lo está.

## Cómo se prueba que quedó arreglado

Cuando `Enforced` pase a `True`, repetir la prueba negativa — la que sí sirve: cambiar
temporalmente el `template` del `spiffe/role` en Vault a un `sub` no autorizado, **reiniciar
Authorino** (con `cache.ttl: 250` si no se prueba con el token viejo y el resultado engaña), mandar
tráfico real, esperar `403`, y revertir.

No sirve mandar un `x-egress-token` basura desde el cliente: Authorino en el origen lo sobreescribe.
