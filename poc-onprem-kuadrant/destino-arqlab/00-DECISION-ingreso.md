# Decisión: por dónde entra el tráfico de paas-lab en arqlab

Esta decisión dio tres vueltas en un día. Se documentan las tres porque cada una se tomó con la
información disponible en ese momento, y porque la conclusión final depende de dos mediciones que
no existían al principio.

## Estado final: Gateway propio `openshift-default` + Route passthrough

**No se usa `gw-hostnet`.** Dos bloqueos medidos, ninguno de los cuales se puede resolver desde
esta PoC:

### 1. El listener 443 no tiene certificado (SDS sigue bloqueado)

```console
$ oc -n connlink-ingress exec ds/gw-hostnet -c istio-proxy -- \
    pilot-agent request GET config_dump   # (extracto de SecretsConfigDump)
activos : ['default', 'ROOTCA']
warming : ['kubernetes-gateway://connlink-ingress/shard1-paas-demo',
           'kubernetes://destino-ca-cacert']
```

El certificado nunca llegó al proxy. Envoy no puede terminar TLS en 443, y por eso **cualquier
handshake contra ese gateway resetea** — que es exactamente el `tls:ConnectionResetError` que dio
la sonda desde paas-lab.

`ResolvedRefs=True` en el listener **no contradice esto**: es justamente el síntoma que define el
hallazgo del runbook §7.2 — la condition en verde con el secret en `warming`. Durante unas horas
se dio el bloqueo por resuelto leyendo esa condition; era incorrecto.

**Dato nuevo**: son *dos* secrets atascados, no uno (`destino-ca-cacert` también). No es un
problema de un Secret puntual: **ese proxy no está recibiendo material criptográfico por SDS.**

### 2. Ninguna `AuthPolicy` sobre ese gateway está `Enforced`

```
backend-ingress-jwt            backend       Accepted=True   Enforced=False
backend-ingress-vault-spiffe   backend       Accepted=True   Enforced=False
backend-lab-vault-spiffe       backend-lab   Accepted=True   Enforced=False

motivo: waiting for the following components to sync: [Gateway (connlink-ingress/gw-hostnet)]
```

Para una PoC cuyo objeto es la autorización entre clusters, esto es descalificante por sí solo:
aunque el TLS funcionara, no se estaría midiendo nada.

### Lo que probablemente los une — hipótesis, no conclusión

`gw-hostnet` es GatewayClass `ingress-hostnet`, servida por un controller y un istiod propios
(`istiod-ingress-gw`). El proxy recibe la configuración estática —listeners, filtros de Kuadrant,
todo eso está en el `config_dump`— pero **no recibe secrets y Kuadrant no lo considera
sincronizado**. Encaja con que istiod no asocie ese proxy al recurso `Gateway` (el log histórico
decía `attempted to access unauthorized certificates`), pero **no está probado**.

Verificar antes de llevarlo a soporte:

```bash
oc -n istio-ingress-cp logs deploy/istiod-ingress-gw | grep -i 'gw-hostnet\|unauthorized\|sync' | tail -40
istioctl --context=paas-arqlab proxy-status | grep gw-hostnet
oc get authpolicy -A -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,ENF:.status.conditions[?(@.type=="Enforced")].status'
oc get gateway -A -o custom-columns='NS:.metadata.namespace,NOMBRE:.metadata.name,CLASE:.spec.gatewayClassName'
```

Si el corte es limpio por GatewayClass, es un caso de soporte con Red Hat — y uno que **excede a
esta PoC**: hoy nada publicado por `gw-hostnet` tiene TLS propio ni política de autorización.

## Por qué el Gateway propio sí funciona

Los dos bloqueos son específicos del gateway desplegado a mano. Sobre `openshift-default` —donde
el deployment lo crea el controller de Istio— hay evidencia de que ambas cosas funcionan en este
mismo cluster:

| | `gw-hostnet` (ingress-hostnet) | `egress-gw` (openshift-default) |
|---|---|---|
| Secret por SDS | `warming` (nunca llega) | funciona |
| `AuthPolicy` | `Enforced: False` | `Enforced: True` (medido) |

Y `destino-ocp/` ya usó este patrón contra `paas-dev1-lowmz`, así que no es terreno nuevo.

## Las tres vueltas, para que se entienda el zigzag

| # | Decisión | Fundamento | Qué la invalidó |
|---|---|---|---|
| 1 | Gateway propio `openshift-default` | esquivar el SDS del runbook §7.2 | el listener 443 pasó a `ResolvedRefs=True` |
| 2 | Reusar `gw-hostnet` | menos piezas, camino real de producción | `ResolvedRefs=True` no probaba nada; el cert seguía en `warming`, y encima no enforcea |
| 3 | **Gateway propio** (actual) | dos bloqueos medidos, ninguno resoluble acá | — |

La vuelta 2 se tomó leyendo una condition en vez de medir el efecto. El repo ya advertía que esa
condition no alcanza (`ocp-destino/10-gateway-ingress-hostnet.yaml`).

## Lo que NO resuelve esto

El workaround del runbook §7.3 —terminar TLS en el F5 y dejar `gw-hostnet` en HTTP:80— resuelve el
bloqueo 1 pero **no el 2**. Para esta PoC no alcanza.
