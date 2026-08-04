# Runbook — Gateway Istio en hostNetwork como ingress (Kuadrant / RHCL)

**Objetivo:** desplegar un segundo gateway Istio (Gateway API) que bindee 80/443 directamente
en nodos infra dedicados, eliminando el salto por HAProxy, y usable como target de policies de
Red Hat Connectivity Link (Kuadrant).

**Validado en:** `paas-arqlab` — OCP 4.20, OVN-Kubernetes, IPI vSphere, OSSM 3.4.0, RHCL 1.3, agosto 2026.

---

## 1. Por qué no alcanza la GatewayClass `openshift-default`

La implementación de Gateway API que trae OCP (`openshift-default`, controller
`openshift.io/gateway-controller/v1`) corre sobre un istiod gestionado por el `cluster-ingress-operator`
en `openshift-ingress`. No es customizable:

| Flag en `istiod-openshift-gateway` | Consecuencia |
|---|---|
| `PILOT_ENABLE_GATEWAY_API_DEPLOYMENT_CONTROLLER=true` | El Deployment lo genera istiod, con podTemplate fijo (sin `nodeSelector`, sin `hostNetwork`) |
| `ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT=false` | No se puede desplegar el pod del gateway a mano |
| `PILOT_ENABLE_GATEWAY_API_COPY_LABELS_ANNOTATIONS=false` | Ni siquiera se propagan labels/annotations del `Gateway` al pod |

El único knob disponible es la annotation `networking.istio.io/service-type`
(ClusterIP / NodePort / LoadBalancer).

> **Alternativa de menor riesgo:** si sólo se busca eliminar el salto HAProxy y no se necesita
> la IP de origen real del cliente, `networking.istio.io/service-type: NodePort` + F5 apuntando
> al nodePort logra lo mismo sin nada de lo que sigue. Con OVN-K el hostPort/NodePort hace SNAT
> y se pierde el client IP; `hostNetwork` lo preserva.

### Hallazgo colateral de plataforma

`Istio/openshift-gateway` quedó en `ReconcileError`:

```
version "v1.26.2" is end-of-life and cannot be installed; use a supported version
```

El `servicemeshoperator3` se actualizó a 3.4.0 (que ya no acepta v1.26.2) mientras el
`cluster-ingress-operator` sigue pidiendo esa versión. El istiod sigue corriendo, pero el CR
**no reconcilia**: no recibe upgrades ni parches. Escalar a Plataforma; es independiente de este PoC.

---

## 2. Prerequisitos

### 2.1 Nodos dedicados

```bash
oc label node <infra-3> <infra-4> <infra-5> ingress=kuadrant
oc label node <infra-0> <infra-1> <infra-2> ingress=haproxy
```

### 2.2 Sacar HAProxy de los nodos de Kuadrant

El `router-default` corre en `hostNetwork` (endpointPublishingStrategy `HostNetwork`) y por defecto
tiene `nodePlacement.nodeSelector: {node-role.kubernetes.io/infra: ""}`, o sea puede caer en
cualquier infra y tomar 80/443.

```bash
oc -n openshift-ingress-operator patch ingresscontroller default --type=merge \
  -p '{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":"","ingress":"haproxy"}}}}}'
```

El merge patch reemplaza sólo `nodeSelector` y preserva las `tolerations`. Con
`endpointPublishingStrategy: HostNetwork` hace falta **un nodo por réplica** (3 réplicas → ≥3 nodos
con `ingress=haproxy`).

Verificar puertos libres desde el bastión (no requiere `oc debug`):

```bash
oc get nodes -l ingress=kuadrant -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address --no-headers \
| while read n ip; do echo "== $n ($ip)"; for p in 80 443 1936 15021; do nc -z -w2 $ip $p && echo "  $p OCUPADO" || echo "  $p libre"; done; done
```

### 2.3 Kuadrant

Basta con crear el namespace: el operador de RHCL reconcilia por namespace y despliega
Authorino + Limitador solo.

```bash
oc create ns kuadrant-system
oc get kuadrant -A            # debe quedar Ready
```

### 2.4 Sysctl de puertos privilegiados

**Este es el paso que más cuesta descubrir.** Ver §5 para el detalle de por qué las capabilities
no sirven. Se aplica con Node Tuning Operator — sin `MachineConfig`, sin MCP dedicado, sin reboot.

```yaml
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: ingress-unprivileged-ports
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: ingress-unprivileged-ports
      data: |
        [main]
        summary=Allow unprivileged bind to low ports on Kuadrant ingress nodes
        include=openshift-node
        [sysctl]
        net.ipv4.ip_unprivileged_port_start=0
  recommend:
    - match:
        - label: ingress
          value: kuadrant
          type: node
      priority: 20
      profile: ingress-unprivileged-ports
```

```bash
oc get profiles.tuned.openshift.io -A     # OJO: nombre completo, "profile" colisiona con compliance.openshift.io
```

**Implicancia de seguridad:** habilita a cualquier proceso unprivileged de esos nodos a bindear
puertos < 1024 en el netns del host. Aceptable en nodos dedicados a ingress — es la misma concesión
que Istio toma dentro de cada pod de gateway — pero debe quedar como decisión registrada.

---

## 3. Control plane dedicado (OSSM 3 / Sail)

No se puede reusar el istiod de `openshift-ingress`. Segundo CR `Istio`, revisión propia,
GatewayClass propia con `controllerName` distinto para que los dos istiod no se peleen.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-ingress-cp
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: ingress-gw
spec:
  namespace: istio-ingress-cp
  version: v1.30.1                 # ver oc explain istio.spec.version — el ENUM del CRD está desactualizado,
  updateStrategy:                  # la lista válida es la del campo DESCRIPTION
    type: InPlace
  values:
    pilot:
      cni:
        enabled: false             # sin esto queda en IstioCNINotFound; un CP sólo-gateways no necesita CNI
      env:
        PILOT_ENABLE_GATEWAY_API: "true"
        PILOT_ENABLE_GATEWAY_API_STATUS: "true"
        PILOT_ENABLE_GATEWAY_API_DEPLOYMENT_CONTROLLER: "false"
        PILOT_ENABLE_GATEWAY_API_GATEWAYCLASS_CONTROLLER: "false"
        PILOT_GATEWAY_API_CONTROLLER_NAME: "istio.io/ingress-hostnet-controller"
        ENABLE_GATEWAY_API_MANUAL_DEPLOYMENT: "true"
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ingress-hostnet
spec:
  controllerName: istio.io/ingress-hostnet-controller
```

Esperar `oc get istio ingress-gw` en `Healthy` antes de seguir.

---

## 4. Gateway + DaemonSet

### 4.1 Namespace, SA, SCC

Namespace propio: no reusar uno atado a otra revisión de Istio.

```bash
oc create ns connlink-ingress
oc label ns connlink-ingress istio.io/rev=ingress-gw
oc create sa gw-hostnet -n connlink-ingress
oc adm policy add-scc-to-user hostnetwork-v2 -z gw-hostnet -n connlink-ingress
```

### 4.2 Gateway y Service

**El nombre del Service es crítico:** Istio lo busca como `<gateway>-<gatewayclass>`. Con otro
nombre el Gateway queda `Programmed=False / AddressNotUsable` y **no se genera el listener de datos**
(istiod deriva el puerto de bind del `targetPort` del Service asociado).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gw-hostnet
  namespace: connlink-ingress
  labels:
    kuadrant.io/gateway: "true"
spec:
  gatewayClassName: ingress-hostnet
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes: { namespaces: { from: All } }
---
apiVersion: v1
kind: Service
metadata:
  name: gw-hostnet-ingress-hostnet     # <gateway>-<gatewayclass>
  namespace: connlink-ingress
  labels:
    istio.io/gateway-name: gw-hostnet
    gateway.networking.k8s.io/gateway-name: gw-hostnet
spec:
  selector:
    gateway.networking.k8s.io/gateway-name: gw-hostnet
  ports:
    - { name: status-port, port: 15021, targetPort: 15021, appProtocol: tcp }
    - { name: http,        port: 80,    targetPort: 80,    appProtocol: http }
```

El Service no transporta tráfico (el tráfico entra por la IP del nodo); existe para el
`status.addresses` del Gateway, para el mapeo de puertos y para el scrape de métricas.
Los `appProtocol` importan: de ahí infiere Istio el tipo de listener.

### 4.3 El problema del `image: auto`

**El webhook de inyección de Istio saltea los pods con `hostNetwork: true`.** No hay flag para
desactivar ese comportamiento. En los logs de istiod se ve como:

```
Process sidecar injection request  path=/inject pod=connlink-ingress/gw-hostnet-*****
Skipping due to policy check       path=/inject pod=connlink-ingress/gw-hostnet-*****
```

Resultado: `image: auto` llega literal al kubelet → `ImagePullBackOff` sobre `docker.io/library/auto`.

**Workaround: renderizar una vez, extraer, pinear.**

1. Aplicar el DaemonSet con `hostNetwork: false` + `dnsPolicy: ClusterFirst` y `image: auto`
   → el webhook lo inyecta normalmente.
2. Extraer el pod renderizado.
3. Transformarlo en un DaemonSet estático con `hostNetwork: true`.

Efecto lateral positivo: el manifiesto final queda pineado y no depende del webhook en cada rollout.

DaemonSet de renderizado (paso 1):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gw-hostnet
  namespace: connlink-ingress
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: gw-hostnet
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway
        prometheus.io/scrape: "true"
        prometheus.io/port: "15020"
        prometheus.io/path: /stats/prometheus
      labels:
        sidecar.istio.io/inject: "true"
        istio.io/gateway-name: gw-hostnet
        gateway.networking.k8s.io/gateway-name: gw-hostnet
    spec:
      serviceAccountName: gw-hostnet
      hostNetwork: false            # <-- para que el webhook inyecte
      dnsPolicy: ClusterFirst
      nodeSelector: { ingress: kuadrant }
      tolerations:
        - { key: node-role.kubernetes.io/infra, operator: Exists }
      terminationGracePeriodSeconds: 60
      containers:
        - name: istio-proxy
          image: auto
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { cpu: "2",  memory: 1Gi }
```

### 4.4 Extracción y transformación

```bash
oc -n connlink-ingress get pod -l gateway.networking.k8s.io/gateway-name=gw-hostnet -o json \
| python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["items"][0], open("/tmp/rendered-pod.json","w"), indent=2)'
```

```python
# mkds.py
import json

pod = json.load(open('/tmp/rendered-pod.json'))
spec, meta = pod['spec'], pod['metadata']

labels = {k: v for k, v in (meta.get('labels') or {}).items()
          if k not in ('controller-revision-hash', 'pod-template-generation')}
annotations = {k: v for k, v in (meta.get('annotations') or {}).items()
               if not k.startswith(('kubectl.kubernetes.io/', 'k8s.ovn.org/',
                                    'k8s.v1.cni.cncf.io/', 'openshift.io/scc',
                                    'seccomp.security.alpha'))}

# campos que inyectan scheduler / kubelet / admission
for k in ('nodeName', 'priority', 'preemptionPolicy', 'serviceAccount',
          'tolerations', 'hostname', 'subdomain'):
    spec.pop(k, None)

# CRITICO: el controlador de DaemonSet pinea cada pod a su nodo con una nodeAffinity
# sobre metadata.name. Si no se saca, el DaemonSet nuevo queda con DESIRED=1.
spec.pop('affinity', None)

# el token de la SA lo remonta el controlador
spec['volumes'] = [v for v in spec.get('volumes', []) if not v['name'].startswith('kube-api-access')]
for c in spec.get('containers', []) + spec.get('initContainers', []):
    c['volumeMounts'] = [m for m in c.get('volumeMounts', []) if not m['name'].startswith('kube-api-access')]

# incompatible con hostNetwork: el kubelet rechaza sysctls net.* en pods hostNetwork.
# El equivalente lo provee el Tuned del paso 2.4.
spec.get('securityContext', {}).pop('sysctls', None)

spec['hostNetwork'] = True
spec['dnsPolicy'] = 'ClusterFirstWithHostNet'      # sin esto no resuelve Authorino/Limitador
spec['nodeSelector'] = {'ingress': 'kuadrant'}
spec['tolerations'] = [{'key': 'node-role.kubernetes.io/infra', 'operator': 'Exists'}]

for c in spec['containers']:
    if c['name'] == 'istio-proxy':
        c.setdefault('securityContext', {})['capabilities'] = {'drop': ['ALL']}

json.dump({
    'apiVersion': 'apps/v1', 'kind': 'DaemonSet',
    'metadata': {'name': 'gw-hostnet', 'namespace': 'connlink-ingress'},
    'spec': {
        'selector': {'matchLabels': {'gateway.networking.k8s.io/gateway-name': 'gw-hostnet'}},
        'template': {'metadata': {'labels': labels, 'annotations': annotations}, 'spec': spec},
    },
}, open('/tmp/gw-hostnet-static.json', 'w'), indent=2)
```

```bash
python3 mkds.py
oc -n connlink-ingress delete ds gw-hostnet     # el selector es inmutable, no sirve apply encima
oc apply -f /tmp/gw-hostnet-static.json
```

---

## 5. Por qué `NET_BIND_SERVICE` no funciona

Intento natural y fallido: agregar la capability al container.

```
error envoy ... listener '0.0.0.0_80' failed to bind or apply socket options:
      cannot bind '0.0.0.0:80': Permission denied
warn  delta ADS:LDS: ACK ERROR ... Error adding/updating listener(s) 0.0.0.0_80
```

Para que un proceso non-root use la capability, tiene que llegarle al set **ambient** (para
sobrevivir al `execve`) o venir de una **file capability** del binario. CRI-O no puebla el set
ambient, y la imagen `istio-proxyv2-rhel9` no tiene file capabilities.

**Cómo lo resuelve HAProxy en el mismo cluster** (referencia útil, pero no transferible):
SCC `hostnetwork` (v1), `allowPrivilegeEscalation: true`, non-root, **sin** agregar la capability
— la imagen del router trae `cap_net_bind_service=ep` sobre el binario, y sin `no_new_privs`
el `execve` la levanta desde el bounding set.

Las dos SCC candidatas son mutuamente excluyentes para lo que haría falta:

| | `hostnetwork` | `hostnetwork-v2` |
|---|---|---|
| `allowedCapabilities` | `<nil>` — no se puede agregar NET_BIND_SERVICE | `[NET_BIND_SERVICE]` ✓ |
| `allowPrivilegeEscalation` | `true` ✓ | `false` — prohibido |

**La respuesta correcta es el sysctl** (§2.4). Es además lo que Istio hace de fábrica: el gateway
autodesplegado (`gw-one`) trae `net.ipv4.ip_unprivileged_port_start: "0"` como sysctl de pod.
Con `hostNetwork` el netns es el del host, así que el mismo ajuste se mueve al nodo.

Con el sysctl aplicado, el `securityContext` queda en el mínimo:
`allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`, SCC `hostnetwork-v2`.

---

## 6. Verificación

```bash
oc get istio ingress-gw
oc -n connlink-ingress get pods -o wide        # IP == IP del nodo, no del pod CIDR
oc -n connlink-ingress get pod -o jsonpath='{range .items[*]}{.metadata.name}{" scc="}{.metadata.annotations.openshift\.io/scc}{" hostNet="}{.spec.hostNetwork}{"\n"}{end}'
oc get gateway -n connlink-ingress gw-hostnet -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
oc -n connlink-ingress exec ds/gw-hostnet -c istio-proxy -- cat /proc/sys/net/ipv4/ip_unprivileged_port_start
oc -n connlink-ingress exec ds/gw-hostnet -c istio-proxy -- pilot-agent request GET listeners
oc -n istio-ingress-cp logs deploy/istiod-ingress-gw --tail=50 | grep -i 'ACK ERROR' || echo "sin errores de LDS"
```

Estado esperado: `Healthy`; un pod por nodo con la IP del nodo y `scc=hostnetwork-v2`;
`Accepted=True` + `Programmed=True`; sysctl en `0`; listener `0.0.0.0_80::0.0.0.0:80`; sin `ACK ERROR`.

> La imagen del proxy **no trae `curl`**. Para el config dump usar
> `pilot-agent request GET config_dump`, no `curl localhost:15000`.

### 6.1 Smoke test con un HTTPRoute — VALIDADO

El route vive en el namespace de la app, el Gateway en `connlink-ingress`. Eso lo habilita el
`allowedRoutes: {namespaces: {from: All}}` del listener; **no hace falta `ReferenceGrant`** para
route→Gateway (ese sólo se necesita para `backendRefs` cruzando namespaces y para `certificateRefs`).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo
  namespace: echoserver
spec:
  parentRefs:
    - name: gw-hostnet
      namespace: connlink-ingress
  hostnames:
    - app1.paas-demo.bancogalicia.com.ar
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: server
          port: 8080
```

Sin `sectionName`, engancha en todos los listeners compatibles.

```bash
oc -n echoserver get httproute echo -o jsonpath='{range .status.parents[*]}{.parentRef.name}{": "}{range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
oc -n connlink-ingress get gateway gw-hostnet -o jsonpath='{range .status.listeners[*]}{.name}{" attachedRoutes="}{.attachedRoutes}{"\n"}{end}'
for ip in 10.254.28.68 10.254.28.62 10.254.28.63; do echo -n "$ip -> "; curl -sS -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://$ip/ -o /dev/null -w '%{http_code}\n' --max-time 5; done
```

Los tres nodos deben responder (es un DaemonSet). Interpretación: **404** = el route no enganchó
(revisar `attachedRoutes`); **503** = enganchó pero el Service no tiene endpoints listos.

---

## 7. TLS en 443 — funcional a medias, con un bloqueo abierto

### 7.1 Lo que sí funciona

Tres piezas, y la del Service es la que se olvida:

```bash
# 1. Secret TLS en el MISMO namespace que el Gateway
oc -n connlink-ingress create secret tls shard1-paas-demo \
  --cert=shard1.paas-demo.bancogalicia.com.ar.crt --key=shard1.paas-demo.bancogalicia.com.ar.key

# 2. Puerto 443 en el Service (si falta, no hay listener — mismo mecanismo que el 80, ver §4.2)
oc -n connlink-ingress patch svc gw-hostnet-ingress-hostnet --type=json \
  -p '[{"op":"add","path":"/spec/ports/-","value":{"name":"https","port":443,"targetPort":443,"protocol":"TCP","appProtocol":"https"}}]'

# 3. Listener HTTPS
oc -n connlink-ingress patch gateway gw-hostnet --type=json \
  -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"https","port":443,"protocol":"HTTPS","tls":{"mode":"Terminate","certificateRefs":[{"kind":"Secret","name":"shard1-paas-demo"}]},"allowedRoutes":{"namespaces":{"from":"All"}}}}]'
```

Resultado: ambos listeners `Accepted=True` / `Programmed=True` / `ResolvedRefs=True`, y Envoy bindea
`0.0.0.0_443`.

**Sobre el `hostname` del listener:** verificar los SAN del certificado ANTES de setearlo. Un
`hostname: "*.shard1.paas-demo..."` no matchea `shard1.paas-demo...` (el wildcard cubre subdominios,
no el dominio en sí) ni los `appN.paas-demo...` de otro nivel. Sin filter chain que matchee el SNI,
Envoy resetea la conexión (`write:errno=104`, `no peer certificate available`). Con un cert multi-SAN
lo práctico es **omitir `hostname`** y dejar el matching a los `HTTPRoute`. Un cert por FQDN requiere
un listener por hostname.

```bash
openssl x509 -in <cert>.crt -noout -subject -ext subjectAltName -dates
```

### 7.2 El bloqueo: el certificado no llega por SDS

Envoy pide el secret pero nunca lo recibe:

```
SDS pedido: kubernetes-gateway://connlink-ingress/shard1-paas-demo
activos:    ['default', 'ROOTCA']
warming:    ['kubernetes-gateway://connlink-ingress/shard1-paas-demo']
```

Y en istiod, en loop:

```
warn ads proxy gw-hostnet-xxxxx.connlink-ingress attempted to access unauthorized certificates
         shard1-paas-demo: cross namespace secret reference requires ReferenceGrant
```

**El mensaje no cuadra con el estado real:** Gateway y Secret están los dos en `connlink-ingress` y
el nombre SDS que pide Envoy trae el namespace correcto.

Descartado empíricamente:

| Hipótesis | Resultado |
|---|---|
| SNI / `hostname` del listener | Descartado — falla también con `hostname` vacío |
| Secret en otro namespace | Descartado — `oc get secret -A` lo ubica en `connlink-ingress` |
| `namespace` explícito en `certificateRefs` | Sin efecto (y conviene omitirlo) |
| `ReferenceGrant` same-namespace | Sin efecto — sigue en `warming` |
| RBAC per-gateway sobre Secrets | No aplica — `gw-one` (autodesplegado) tampoco tiene Role |
| Flag de istiod faltante | Descartado — el diff de env vs el istiod de OCP sólo muestra las diferencias intencionales |

Pendiente de probar:

1. `oc -n istio-ingress-cp rollout restart deploy istiod-ingress-gw` — la verificación de
   `certificateRefs` se hace en la traducción, no en cada push; descarta caché vieja.
2. **Experimento de control:** un `Gateway` con `gatewayClassName: openshift-default` en el mismo
   namespace y con el mismo Secret. Si el autodesplegado sí recibe el cert, el problema es el camino
   de despliegue manual (istiod no asocia las `VerifiedCertificateReferences` a un proxy que no creó
   el deployment controller) → caso de soporte con Red Hat. Si tampoco, es un hallazgo de plataforma
   que afecta también a `openshift-default`.

Diagnóstico:

```bash
oc -n connlink-ingress exec ds/gw-hostnet -c istio-proxy -- pilot-agent request GET config_dump | python3 -c '
import json,sys
d=json.load(sys.stdin)
for c in d["configs"]:
    t=c.get("@type","")
    if "ListenersConfigDump" in t:
        for l in c.get("dynamic_listeners",[]):
            if "443" not in l.get("name",""): continue
            for fc in l.get("active_state",{}).get("listener",{}).get("filter_chains",[]):
                sds=fc.get("transport_socket",{}).get("typed_config",{}).get("common_tls_context",{}).get("tls_certificate_sds_secret_configs",[])
                print("SDS pedido:", [s.get("name") for s in sds])
    if "SecretsConfigDump" in t:
        print("activos:", [s.get("name") for s in c.get("dynamic_active_secrets",[])])
        print("warming:", [s.get("name") for s in c.get("dynamic_warming_secrets",[])])
'
oc -n istio-ingress-cp logs deploy/istiod-ingress-gw --tail=200 | grep -i unauthorized | tail -5
echo | openssl s_client -connect <IP-nodo>:443 -servername <FQDN> 2>&1 | head -12
```

> **`ResolvedRefs=True` no prueba que el certificado haya llegado al proxy.** Se calcula contra lo
> que istiod puede leer; la autorización del `certificateRefs` se evalúa recién al pushear por SDS.
> El único indicador confiable es `dynamic_active_secrets` en el config dump del proxy.

### 7.3 Workaround mientras tanto

Terminar TLS en el F5 y dejar el gateway en HTTP: VIP 443 con el certificado en el F5, pool members
a `<IPs de nodo>:80`. Es coherente con cómo se publica el resto de la plataforma y no bloquea el PoC
— las `AuthPolicy` y `RateLimitPolicy` de Kuadrant operan sobre el `Gateway` y los `HTTPRoute`, no
sobre la terminación TLS.

---

## 8. Publicación por F5

Pools con los tres nodos de ingress como members, puertos 80 y 443:

```
Pool-apps.<entorno>-80   -> 10.254.28.62:80,  .63:80,  .68:80
Pool-apps.<entorno>-443  -> 10.254.28.62:443, .63:443, .68:443
```

El Ingress VIP de IPI vSphere (`keepalived` en `openshift-vsphere-infra`) sigue atado a HAProxy:
su health check local verifica que haya un pod router en el nodo, así que no va a flotar hacia
los nodos de Kuadrant. Este gateway se publica por F5 apuntando a las IPs de nodo, no por el VIP.

**`DNSPolicy` de Kuadrant no aplica acá:** lee las addresses del `Gateway`, que con `hostNetwork`
no son de tipo LoadBalancer. El naming va por F5 / DNS corporativo.

---

## 9. Gotchas — resumen

| Síntoma | Causa | Fix |
|---|---|---|
| `ImagePullBackOff` sobre `docker.io/library/auto` | El inyector saltea pods `hostNetwork` | Renderizar con `hostNetwork: false` y extraer (§4.3) |
| `Programmed=False / AddressNotUsable` y sin listener de datos | Service mal nombrado | `<gateway>-<gatewayclass>` (§4.2) |
| Listener nuevo (443) no aparece en Envoy | Falta el puerto en el Service | Agregar el port con su `appProtocol` (§7.1) |
| `DESIRED=1` en el DaemonSet con N nodos elegibles | `nodeAffinity` a `metadata.name` heredada del pod extraído | `spec.pop('affinity')` (§4.4) |
| `cannot bind '0.0.0.0:80': Permission denied` | Capability sin ambient ni file caps | Sysctl vía `Tuned` (§2.4, §5) |
| `IstioCNINotFound` en el CR `Istio` | Perfil openshift asume CNI | `values.pilot.cni.enabled: false` (§3) |
| `version ... is end-of-life` | ENUM del CRD desactualizado vs validación real | Usar la lista del `DESCRIPTION` de `oc explain istio.spec.version` |
| TLS resetea, `no peer certificate available` | `hostname` del listener no matchea ningún SAN | Verificar SAN y omitir `hostname` (§7.1) |
| Cert en `warming`, `cross namespace secret reference requires ReferenceGrant` con todo en el mismo ns | **Abierto** — ver §7.2 | Workaround: terminar TLS en F5 (§7.3) |
| `oc get profile` vuelve vacío | Colisión con `profiles.compliance.openshift.io` | `oc get profiles.tuned.openshift.io` |
| `oc debug node` falla al crear el pod | Admission (ACM policies / compliance) | Usar el propio pod hostNetwork, o `nc` desde el bastión |
| `curl: executable file not found` dentro del proxy | La imagen del proxy no trae `curl` | `pilot-agent request GET <path>` |

---

## 10. Estado del PoC

| Pieza | Estado |
|---|---|
| Control plane dedicado (`ingress-gw`, v1.30.1) | ✅ `Healthy` |
| DaemonSet hostNetwork en infra-3/4/5, SCC `hostnetwork-v2` | ✅ 3/3, IP de nodo |
| Gateway `Accepted` + `Programmed` | ✅ |
| Listener 80 bindeado y sirviendo | ✅ |
| `HTTPRoute` cross-namespace → backend | ✅ validado contra `echoserver/server:8080` |
| Pool F5 :80 con los 3 nodos | ✅ verde |
| Listener 443 bindeado | ✅ |
| Entrega del certificado por SDS | ❌ bloqueado — §7.2 |
| `AuthPolicy` / `RateLimitPolicy` de Kuadrant | ⏳ pendiente |
