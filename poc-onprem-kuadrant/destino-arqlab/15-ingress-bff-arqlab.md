# El ingreso al `bff` de arqlab — diagnóstico

Estado del recurso al 2026-09-09:

```yaml
# HTTPRoute bff-ingress, ns poc-egress-kuadrant
spec:
  hostnames: [bff-arqlab.paas-demo.bancogalicia.com.ar]   # generation 2
  parentRefs: [{name: gw-hostnet, namespace: connlink-ingress}]   # sin sectionName
# status: "Route was valid, bound to 2 parents"  Accepted=True  ResolvedRefs=True
```

El `last-applied-configuration` muestra que el hostname original era
`bff.paas-demo.bancogalicia.com.ar` y se cambió a `bff-arqlab.paas-demo…`.

Del lado de Gateway API **no hay nada roto**: la route está `Accepted`, con refs resueltas, y
attacheada a los dos listeners (80 y 443) porque no declara `sectionName`. Si el ingreso no
funciona, el problema está afuera de la HTTPRoute. Dos candidatos, en orden, ambos verificables
en un comando:

## 1. El certificado no cubre el nombre (el más probable)

El listener https termina TLS con `shard1-paas-demo`, creado (runbook §7.1) desde
`shard1.paas-demo.bancogalicia.com.ar.crt`. Si ese cert es de **un solo nombre**, cualquier
cliente que pida `bff-arqlab.paas-demo.bancogalicia.com.ar` por HTTPS recibe un cert que no lo
cubre y corta el handshake — sin que nada del lado del cluster se vea mal.

```bash
oc --context=paas-arqlab -n connlink-ingress get secret shard1-paas-demo \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -ext subjectAltName -dates
```

- SAN trae `*.paas-demo.bancogalicia.com.ar` → el cert no es el problema, pasar al punto 2.
- SAN trae solo `shard1.paas-demo…` → **es esto**. Tres salidas:
  1. Reemitir el cert con `bff-arqlab.paas-demo…` en los SAN (o directamente el wildcard).
  2. Renombrar el hostname de la HTTPRoute a uno que el cert sí cubra.
  3. Un segundo listener con su propio cert y su `hostname` — el runbook §7.1 avisa: un cert por
     FQDN requiere un listener por hostname.

El runbook ya documenta esta trampa, incluido que un wildcard `*.shard1.paas-demo…` **no** cubre
`shard1.paas-demo…` (el wildcard cubre subdominios, no el dominio en sí).

## 2. El nombre no resuelve, o no resuelve al F5 correcto

```bash
host bff-arqlab.paas-demo.bancogalicia.com.ar
# comparar con:
host shard1.paas-demo.bancogalicia.com.ar     # -> 10.254.124.36
```

Si `bff-arqlab` no existe o apunta a otro lado, el registro DNS es lo que falta. Se crea on-prem
en el momento, apuntando al mismo destino que `shard1.paas-demo`.

## Comprobación de punta a punta

Aísla las dos capas: primero sin TLS por el listener 80 (la route está attacheada ahí también),
después con TLS.

```bash
IP=$(host shard1.paas-demo.bancogalicia.com.ar | awk '/has address/{print $NF}')

# a) sin TLS — si esto responde, la HTTPRoute y el backend están bien
curl -sS -o /dev/null -w 'http80=%{http_code}\n' \
  -H 'Host: bff-arqlab.paas-demo.bancogalicia.com.ar' "http://$IP/"

# b) con TLS, sin validar — si esto responde, el problema es SOLO el nombre del cert
curl -skS -o /dev/null -w 'https_insecure=%{http_code}\n' \
  --resolve "bff-arqlab.paas-demo.bancogalicia.com.ar:443:$IP" \
  "https://bff-arqlab.paas-demo.bancogalicia.com.ar/"

# c) qué cert presenta realmente para ese SNI
openssl s_client -connect "$IP:443" \
  -servername bff-arqlab.paas-demo.bancogalicia.com.ar </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

`a` OK + `b` OK + `c` mostrando otro nombre ⇒ es el punto 1, y alcanza con arreglar el cert.
