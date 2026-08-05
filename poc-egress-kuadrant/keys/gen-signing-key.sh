#!/usr/bin/env bash
# Genera el material de clave de la PoC:
#   - out/key.pem        clave privada RSA 2048 (queda SOLO en el cluster origen)
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
# POR QUÉ RSA Y NO EC — medido en paas-arqlab (2026-08-05), RHCL 1.x:
#   El emisor de wristband de Authorino firma ES256 sin problemas, pero su propio
#   verificador `jwt` (go-oidc) está fijado a RS256 y NO hay campo en la AuthPolicy
#   para declarar otros algoritmos. Con una clave EC, el destino rechaza el 100% de
#   los tokens y el log dice:
#
#     cannot validate identity ... reason:
#       "oidc: malformed jwt: unexpected signature algorithm \"ES256\"; expected [\"RS256\"]"
#
#   El síntoma en el cliente es un 401 indistinguible de "falta el token", y el
#   AuthConfig queda Ready=True, así que nada señala al algoritmo. Es una asimetría
#   dentro del mismo producto: firma EC, valida sólo RSA.
#
#   Cambiar a RSA conserva TODO el modelo de confianza de §2 del README — asimétrico,
#   privada sólo en el origen, público pineado en el destino. Sólo cambia el algoritmo.
#   Si algún día el verificador acepta EC, volver a ES256 es cambiar este script y el
#   `algorithm:` de los AuthPolicy; nada más del diseño depende de eso.
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

openssl genrsa -out "$OUT/key.pem" 2048 2>/dev/null

# El JWK RSA necesita el módulo (n) y el exponente (e) en base64url. Se leen del propio
# PEM con openssl para no depender de librerías de criptografía en el bastión.
openssl rsa -in "$OUT/key.pem" -noout -modulus 2>/dev/null | sed 's/^Modulus=//' > "$OUT/modulus.hex"
openssl rsa -in "$OUT/key.pem" -noout -text 2>/dev/null | grep -A1 -i 'publicExponent' | head -1 \
  | sed -E 's/.*\(0x([0-9a-fA-F]+)\).*/\1/' > "$OUT/exponent.hex"

python3 - "$OUT" "$KID" <<'PY'
import base64, json, sys
out, kid = sys.argv[1], sys.argv[2]
b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")

n_hex = open(f"{out}/modulus.hex").read().strip()
e_hex = open(f"{out}/exponent.hex").read().strip() or "10001"
if len(e_hex) % 2:
    e_hex = "0" + e_hex

n = bytes.fromhex(n_hex)
n = n.lstrip(b"\x00") or b"\x00"        # el JWK no lleva el byte de signo del DER
e = bytes.fromhex(e_hex).lstrip(b"\x00") or b"\x01"

jwk = {
    "kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid,
    "n": b64u(n), "e": b64u(e),
}
json.dump({"keys": [jwk]}, open(f"{out}/jwks.json", "w"), indent=2)
print(f"  JWK RSA: n={len(n)*8} bits, e=0x{e.hex()}")
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

rm -f "$OUT/modulus.hex" "$OUT/exponent.hex"

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
