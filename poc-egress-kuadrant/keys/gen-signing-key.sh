#!/usr/bin/env bash
# Genera el material de clave de la PoC:
#   - out/key.pem        clave privada EC P-256 (queda SOLO en el cluster origen)
#   - out/secret.yaml    Secret egress-echoserver-1 para el ns echoserver (ORIGEN)
#   - out/jwks.json      JWKS con la clave PÚBLICA (se pinea en el cluster DESTINO)
#
# Por qué un par de claves y no un secreto compartido HMAC:
#   Authorino no firma ni valida HS256 (el wristband soporta ES256/ES384/ES512 y
#   RS*). El modelo de confianza es el mismo que pediste — clave preacordada,
#   sin IdP, sin dependencia de red entre clusters — pero al destino sólo se le
#   copia la clave PÚBLICA: si el cluster destino se ve comprometido, nadie
#   puede falsificar tokens de salida.
#
# DÓNDE VA EL SECRET — verificado en paas-arqlab (2026-08):
#   Kuadrant traduce cada AuthPolicy a un AuthConfig en `kuadrant-system`, sin
#   importar el namespace del AuthPolicy. Authorino resuelve `signingKeyRefs`
#   contra el namespace del AUTHCONFIG. Con el Secret en el ns de la app, el
#   AuthConfig no reconcilia:
#       Reconciler error ... error: Secret "egress-echoserver-1" not found
#       outgoing authorization response ... NOT_FOUND "Service not found"
#   Es el mismo motivo por el que el Secret de API key del smoke test de la guía
#   de instalación de RHCL vive en `kuadrant-system`.
#
# Uso:  ./gen-signing-key.sh [kid] [namespace]
set -euo pipefail

KID="${1:-egress-echoserver-1}"
NS="${2:-kuadrant-system}"
OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"
umask 077

openssl ecparam -name prime256v1 -genkey -noout -out "$OUT/key.pem"
openssl ec -in "$OUT/key.pem" -pubout -outform DER -out "$OUT/pub.der" 2>/dev/null

python3 - "$OUT" "$KID" <<'PY'
import base64, json, sys
out, kid = sys.argv[1], sys.argv[2]
der = open(f"{out}/pub.der", "rb").read()
point = der[-65:]                      # SubjectPublicKeyInfo P-256: ultimos 65 bytes
assert point[0] == 0x04, "punto EC no comprimido esperado"
b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
jwk = {
    "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
    "x": b64u(point[1:33]), "y": b64u(point[33:65]),
}
json.dump({"keys": [jwk]}, open(f"{out}/jwks.json", "w"), indent=2)
PY

# Secret para el cluster ORIGEN. Authorino espera la entrada "key.pem".
#
# Se arma a mano en vez de con `oc create --dry-run=client` porque ese comando NO
# emite metadata.namespace: el YAML resultante se aplicaría al namespace actual
# del contexto, que es justamente el error que se quiere evitar acá.
python3 - "$OUT" "$KID" "$NS" <<'PY'
import base64, sys
out, kid, ns = sys.argv[1:4]
clave = base64.b64encode(open(f"{out}/key.pem", "rb").read()).decode()
open(f"{out}/secret.yaml", "w").write(
    "apiVersion: v1\n"
    "kind: Secret\n"
    "type: Opaque\n"
    "metadata:\n"
    f"  name: {kid}\n"
    f"  namespace: {ns}\n"
    "data:\n"
    f"  key.pem: {clave}\n"
)
PY

rm -f "$OUT/pub.der"

cat <<EOF

Generado en $OUT:
  key.pem      -> NO commitear. Aplicar sólo en el cluster ORIGEN.
  secret.yaml  -> oc apply -f $OUT/secret.yaml            (cluster ORIGEN, ns $NS)
  jwks.json    -> pegar dentro de destino/11-jwks-static.yaml (cluster DESTINO)

kid usado: $KID
namespace:  $NS  (donde Authorino resuelve signingKeyRefs)

IMPORTANTE — validar el kid real del token:
  Authorino define el "kid" del header JWT a partir del Secret de firma. Si el
  kid del token no coincide con el del JWKS, la validación en destino falla.
  Tras el primer request end-to-end, leer el token reflejado por el echo server
  y comparar:
    echo '<x-egress-token>' | cut -d. -f1 | base64 -d 2>/dev/null; echo
  Si difiere, regenerar el JWKS con ese kid:  ./gen-signing-key.sh <kid-real>
  (o editar a mano el campo "kid" en el ConfigMap del destino).
EOF
