# DESCARTADO — Gateway `openshift-default` propio + Route passthrough

Este directorio tenía, hasta el 2026-09-09, un `Gateway` con `gatewayClassName: openshift-default`
y una `Route` de OpenShift en `passthrough` para publicarlo. **Se descartaron.** Queda esta nota
para que nadie los reintroduzca sin saber por qué se fueron.

## Por qué existían

El `gw-hostnet` (ns `connlink-ingress`, class `ingress-hostnet`, DaemonSet hostNetwork detrás de
F5) tenía **solo listener HTTP:80**. El 443 estaba bloqueado por el problema de SDS del
`runbook-gw-istio-hostnetwork.md` §7.2: Envoy pedía el certificado y istiod respondía
`cross namespace secret reference requires ReferenceGrant`, aunque Gateway y Secret estaban en el
mismo namespace. Sin TLS en el destino, el `DestinationRule` del origen no podía originar TLS.

El Gateway `openshift-default` esquivaba eso, y de paso era el "experimento de control" que el
propio runbook listaba como pendiente.

## Por qué se descartaron

**El bloqueo está resuelto.** Estado del gateway al 2026-09-09:

```yaml
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      certificateRefs: [{kind: Secret, name: shard1-paas-demo}]
      mode: Terminate
# status.listeners[https]:
#   Accepted=True  Programmed=True  ResolvedRefs=True  attachedRoutes=3
# status.conditions[Programmed]: "assigned to service(s) …:443 and …:80"
```

`ResolvedRefs=True` en el listener significa que el `certificateRefs` resolvió. La transición del
`Programmed` del Gateway es del 2026-09-03.

Con el 443 andando, el Gateway propio pasa a ser peor en todo:

| | Reusar `gw-hostnet` | Gateway propio + Route |
|---|---|---|
| Piezas nuevas | 1 (una HTTPRoute) | 4 (Gateway, Service, Route, Secret wildcard) |
| Certificado | el que ya está publicado | uno nuevo a conseguir y mantener |
| Camino de red | el REAL de la plataforma (F5 → hostNetwork) | uno paralelo, solo de PoC |
| Representatividad | mide lo que va a existir en producción | mide otra cosa |

Un camino paralelo que no es el de producción también vuelve la PoC menos concluyente: lo que
mida ahí no dice nada del ingreso real.

## Lo que se pierde, y por qué no importa tanto

Se pierde el experimento de control del §7.2. No importa: **el hallazgo que motivaba ese control
ya se resolvió por otra vía**, y el otro hallazgo que se le quería atribuir (claims que no
rechazan) resultó no tener nada que ver — el Envoy del `gw-hostnet` SÍ tiene los filtros de
Kuadrant (63 `authorino`, 7 `ext_authz`, 149 `kuadrant` en su `config_dump`). Ver
`14-diagnostico-claims.md`.

## Cuándo reabrir esto

Un solo caso: si el certificado del listener (`shard1-paas-demo`) **no cubre** el FQDN que la PoC
necesita anunciar por SNI y no se puede reemitir con ese SAN. Ahí hay dos salidas, y el Gateway
propio es la segunda:

1. Anunciar por SNI un nombre que el certificado SÍ cubra (ver `origen-paas-lab/04`) — preferida,
   cero infraestructura nueva.
2. Recién entonces, un Gateway propio con su certificado.
