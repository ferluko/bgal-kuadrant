#!/usr/bin/env bash
# Certificados del destino SIMULADO.
#
# Genera una CA propia y un certificado de servidor para el MISMO FQDN que usaría el
# cluster destino real, `app2.paas-demo.bancogalicia.com.ar`. Eso es lo que permite que
# `origen/04-destinationrule-tls.yaml` se aplique verbatim: su `sni` apunta a ese FQDN y
# su `credentialName: destino-ca` a la CA que se genera acá.
#
# Emite DOS Secrets, en namespaces distintos y por motivos distintos:
#   1. `app2-sim-tls` (kubernetes.io/tls) en el ns del destino simulado -> lo consume el
#      listener HTTPS del Gateway (02) por `certificateRefs`.
#   2. `destino-ca` en el ns donde corren los pods del GATEWAY DE EGRESO (`echoserver`)
#      -> lo consume el DestinationRule para validar la cadena. Istio lee el material de
#      CA del ns del data plane, no del ns donde vive el DestinationRule.
#
# El Secret de CA se crea con `ca.crt` y `cacert`: distintas versiones de Istio buscan una
# u otra clave para `credentialName` en un DestinationRule con `mode: SIMPLE`. Poner las
# dos cuesta nada y evita un diagnóstico de una hora.
#
# NO usar para producción: es una CA de laboratorio, sin custodia de la clave privada.
set -euo pipefail

FQDN="${FQDN:-app2.paas-demo.bancogalicia.com.ar}"
NS_SIM="${NS_SIM:-echoserver-eks-sim}"
NS_GW="${NS_GW:-echoserver}"
OUT="${OUT:-$(dirname "$0")/out}"
DAYS="${DAYS:-90}"

mkdir -p "$OUT"
cd "$OUT"

echo ">>> CA de laboratorio"
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -keyout ca.key -out ca.crt \
  -subj "/CN=PoC Egreso — CA destino simulado/O=Banco Galicia" 2>/dev/null

echo ">>> certificado de servidor para $FQDN"
openssl req -newkey rsa:2048 -nodes \
  -keyout server.key -out server.csr \
  -subj "/CN=$FQDN" 2>/dev/null

# El SAN es obligatorio: Envoy valida el nombre contra el SAN, no contra el CN. Sin esto
# el handshake falla con "Certificate verification failed" aunque la cadena esté bien.
cat > san.cnf <<EOF
subjectAltName = DNS:$FQDN
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS" -extfile san.cnf 2>/dev/null

echo ">>> Secrets"
oc create namespace "$NS_SIM" --dry-run=client -o yaml | oc apply -f - >/dev/null

oc -n "$NS_SIM" create secret tls app2-sim-tls \
  --cert=server.crt --key=server.key \
  --dry-run=client -o yaml | oc apply -f -

oc -n "$NS_GW" create secret generic destino-ca \
  --from-file=ca.crt=ca.crt --from-file=cacert=ca.crt \
  --dry-run=client -o yaml | oc apply -f -

chmod 600 ca.key server.key

cat <<EOF

Listo.

  CA           : $OUT/ca.crt
  Servidor     : $OUT/server.crt   (SAN: $FQDN)
  Secret TLS   : $NS_SIM/app2-sim-tls        -> listener del Gateway simulado (02)
  Secret CA    : $NS_GW/destino-ca           -> DestinationRule (origen/04)

Verificar el SAN antes de seguir — si falta, el handshake falla y el sintoma es un 503
generico en el gateway de egreso:

  openssl x509 -in $OUT/server.crt -noout -text | grep -A1 'Subject Alternative Name'

EOF
