# PoC — Egreso seguro con Kuadrant/RHCL: EKS → OCP (sentido inverso)

Mirror de [`../poc-egress-kuadrant/`](../poc-egress-kuadrant/) con los roles invertidos:
acá **EKS es el cluster origen** (el que consume) y **OCP es el cluster destino** (el que
publica el backend). Mismo patrón de wristband JWT + intercepción por selector de Service,
aplicado en la otra dirección.

Diagrama: [`../poc-egress-kuadrant/request-path-diagram-eks-to-ocp.svg`](../poc-egress-kuadrant/request-path-diagram-eks-to-ocp.svg).

## 1. Qué cambia respecto del sentido OCP→EKS

| | OCP→EKS (`poc-egress-kuadrant`) | EKS→OCP (acá) |
|---|---|---|
| Cluster origen | OCP (`paas-arqlab`) | EKS (`devops-cilium-1-35`) |
| Cluster destino | EKS | OCP |
| `Gateway egress-gw` (origen) | `class openshift-default`, Service forzado a `ClusterIP` (no hay LB nativo en IPI vSphere) | `class istio`, Service forzado a `ClusterIP` (acá SÍ habría LB real si no se fuerza) |
| Clave privada de firma (`kuadrant-system`) | En OCP | En **EKS** |
| `Gateway` de ingreso (destino) | `class istio`, NLB internal, Envoy termina TLS — sin gotchas | `gw-hostnet` / `class ingress-hostnet`, DaemonSet hostNetwork en nodos infra dedicados (ver `../runbook-gw-istio-hostnetwork.md`) — **con un bloqueo de plataforma abierto en la entrega del cert por SDS (runbook §7.2)** |
| Validación JWT (destino) | Kuadrant upstream 1.4.2 (schema sin `customHeader.prefix`) | RHCL 1.3 (schema CON `customHeader.prefix` — **no son el mismo YAML**, ya lo confirmamos empíricamente una vez) |
| NetworkPolicy en origen | Necesita `ipBlock` extra: su propio ingress es hostNetwork y ve IP de nodo | No hace falta: el ingress de EKS preserva IP real (NLB target-type=ip) |

## 2. Orden de aplicación

**Etapa A — preparación, cero impacto** (igual que el otro sentido, ver
`poc-egress-kuadrant/README.md` §6 para el detalle de cada paso, acá solo el orden):

```bash
# Generar el par de claves EN EKS (la privada nunca sale de ahí)
../poc-egress-kuadrant/keys/gen-signing-key.sh egress-eks-1 kuadrant-system RS256
kubectl --context=devops-cilium-1-35 -n kuadrant-system apply -f ../poc-egress-kuadrant/keys/out/secret.yaml

# Destino (OCP) — requiere el runbook completo (namespace/SA/SCC, DaemonSet
# hostNetwork, sysctl, publicación F5) ANTES de estos manifiestos declarativos:
oc apply -f ocp-destino/10-gateway-ingress-hostnet.yaml   # solo la parte declarativa — leer el runbook
# pegar el JWKS generado arriba (n/e) en:
oc apply -f ocp-destino/11-jwks-static.yaml
oc apply -f ocp-destino/12-httproute-backend.yaml
oc apply -f ocp-destino/13-authpolicy-jwt-rhcl.yaml
oc apply -f ocp-destino/14-ratelimitpolicy.yaml            # opcional

# Origen (EKS), sin tocar todavía el Service backend
kubectl --context=devops-cilium-1-35 apply -f eks-origen/01-gateway-egress.yaml
kubectl --context=devops-cilium-1-35 apply -f eks-origen/02-serviceentry-destino.yaml
kubectl --context=devops-cilium-1-35 apply -f eks-origen/03-httproute-egress.yaml
kubectl --context=devops-cilium-1-35 apply -f eks-origen/04-destinationrule-tls.yaml
kubectl --context=devops-cilium-1-35 apply -f eks-origen/05-authpolicy-wristband.yaml
kubectl --context=devops-cilium-1-35 apply -f eks-origen/06-service-backend-local.yaml
kubectl --context=devops-cilium-1-35 apply -f eks-origen/07-networkpolicy.yaml
```

**Etapa B — cutover** (aplicar último, ver `eks-origen/09-cutover-service-selector.yaml`).

## 3. Placeholders a reemplazar

| Placeholder | Dónde | Valor real |
|---|---|---|
| `<destination-fqdn-ocp>` | `eks-origen/02`, `03`, `04`, `05` | FQDN público/corporativo de `gw-hostnet` — pendiente de definir |
| `<source-cluster-eks>` | `eks-origen/05`, `ocp-destino/13` | Nombre del cluster EKS (p.ej. `devops-cilium-1-35`) |
| `n` del JWKS | `ocp-destino/11-jwks-static.yaml` | Salida de `gen-signing-key.sh` corrido en EKS |

## 4. Pendientes conocidos, heredados de investigación previa — no repetir el trabajo

1. **Cadena de CA para `eks-origen/04-destinationrule-tls.yaml` (`credentialName: destino-ca`).**
   Mismo pendiente que quedó abierto del lado EKS: el certificado root correcto de esta
   jerarquía interna del banco tiene que tener Subject Key Identifier
   `9B:E7:80:85:7F:57:2F:38:49:B1:BE:7C:9D:93:39:14:D0:B2:BC:7E` (`CN=Root CA Banco Galicia`).
   Verificar por AKI/SKI con `openssl verify`/`openssl x509 -text`, **no por nombre** — ya nos
   pasaron un cert con nombre plausible que no cerraba criptográficamente.
2. **Bloqueo de SDS en `gw-hostnet` (runbook §7.2) — verificar antes de asumir.** El listener
   443 pasó a `ResolvedRefs=True` (2026-09-03), pero eso **no prueba** que el cert llegó al
   proxy: el único indicador confiable es `dynamic_active_secrets` en el `config_dump` (comando
   en el runbook §7.2). Si sigue en `warming`, aplica el workaround de F5 del runbook §7.3.
3. **Bug de escaping en `RateLimitPolicy.counters`** — confirmado en Kuadrant 1.4.2 (EKS),
   no confirmado todavía en RHCL 1.3 (OCP). Verificar antes de asumir que hace falta el
   mismo workaround (dos `counters` simples en vez de uno concatenado).
4. **Connection pool en el `DestinationRule`** — el bloque es obligatorio (ver hallazgo
   medido en `poc-egress-kuadrant/origen/04-destinationrule-tls.yaml`, 2026-08-06: sin él,
   503 sistemáticos bajo concurrencia con RTT real). Los valores exactos (`idleTimeout: 300s`)
   estaban calibrados contra el idle timeout fijo de la NLB de AWS — **verificar el idle
   timeout real del lado F5/OCP** antes de asumir que el mismo número aplica.
