# Pedido: actualizar la clave pública pineada en el cluster EKS

**Para:** quien administra el cluster EKS de la PoC (ns `echoserver`).
**De:** Plataforma — PoC de egreso `paas-arqlab` → EKS.
**Fecha:** 2026-08-05.

## Qué hace falta

Reemplazar el contenido del ConfigMap **`jwks-egress-origen`** del namespace **`echoserver`**
por el archivo adjunto `jwks.json`, y forzar que Authorino lo vuelva a leer.

Es una **clave pública** (JWKS). No es material sensible: se puede mandar por cualquier canal.

```bash
kubectl -n echoserver create configmap jwks-egress-origen \
  --from-file=jwks.json=./jwks.json --dry-run=client -o yaml | kubectl apply -f -

# Authorino cachea el JWKS; recrear la AuthPolicy fuerza el refetch
kubectl -n echoserver delete authpolicy server2-ingress-jwt
kubectl -n echoserver apply -f <el manifiesto de la AuthPolicy>

# y confirmar que quedó lista antes de mandar tráfico
kubectl -n echoserver get authpolicy server2-ingress-jwt \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status} {.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
```

## Por qué

Durante la PoC se regeneró varias veces el par de claves de firma del cluster origen. La clave
pública que quedó pineada en EKS corresponde a una versión anterior, así que el destino rechaza
todos los tokens.

**El `kid` no ayuda a detectarlo:** es siempre `egress-echoserver-1`, así que coincide en los dos
lados mientras la firma no valida. El síntoma es un **401 con body vacío** y
`www-authenticate: x-egress-token realm="egress-wristband"`, indistinguible de un request sin
credencial.

Importante: la clave nueva es **RSA / RS256**. Si la que está pineada dice `"kty":"EC"`, además
del material cambia el tipo — el verificador `jwt` de Authorino sólo acepta RS256 y con EC
rechaza el 100 % de los tokens.

## Cómo verificar que quedó bien

Desde el cluster origen, un request con un wristband recién emitido tiene que dar **200** en vez
de 401:

```bash
TOK=$(curl -s -H 'Host: app1.paas-demo.bancogalicia.com.ar' http://10.254.28.68/ \
      | jq -r '.upstream.body.request.headers["x-egress-token"]')

oc -n echoserver exec -i deploy/server -- python3 -c "
import socket, ssl, http.client
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
s=ctx.wrap_socket(socket.create_connection(('172.19.105.169',443),timeout=10),
                  server_hostname='app2.paas-demo.bancogalicia.com.ar')
c=http.client.HTTPSConnection('x',443,context=ctx,timeout=10); c.sock=s
c.request('GET','/',headers={'Host':'server2.echoserver.svc.cluster.local:8080',
                             'x-egress-token':'$TOK'})
print(c.getresponse().status)"
```

Si sigue en 401, el motivo exacto está en los logs de Authorino del destino:

```bash
kubectl -n kuadrant-system logs deploy/authorino --since=10m | grep -i 'cannot validate identity'
```

## Contexto: qué ya está verificado del lado origen

| | |
|---|---|
| Conectividad al NLB desde un pod de `paas-arqlab` | ✅ conecta en 182 ms |
| Resolución de `app2.paas-demo.bancogalicia.com.ar` | ✅ desde el bastión y desde CoreDNS |
| Certificado del destino | ✅ los SAN cubren `app2.paas-demo.bancogalicia.com.ar` |
| Ruteo del destino por Host interno | ✅ sólo `server2.echoserver.svc.cluster.local:8080` da 401; el resto da 404 |
| Emisión del wristband en el origen | ✅ RS256, 5 claims, vida de 300 s |

O sea que **lo único que falta para cerrar el camino de punta a punta es esta clave.**

## Un pendiente aparte, para la misma ventana

El Secret **`destino-ca`** en el namespace `echoserver` del cluster **origen** necesita la cadena
de la CA que emite el certificado del destino: `CA NoProd Intermedia Banco Galicia`. Sin ella, el
`DestinationRule` no puede validar la cadena TLS y hay que dejarlo con `insecureSkipVerify`, que
no es aceptable fuera del laboratorio.
