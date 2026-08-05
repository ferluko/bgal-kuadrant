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
# POR QUÉ RSA EN PKCS#1 Y NO EC — medido en paas-arqlab (2026-08-05), RHCL 1.x.
#   Hay DOS restricciones, y hay que cumplir las dos a la vez:
#
#   1. El verificador `jwt` de Authorino (go-oidc) está fijado a RS256 y no hay campo en
#      la AuthPolicy para declarar otros algoritmos. Con una clave EC el destino rechaza
#      el 100% de los tokens, y sólo se ve con el log en debug:
#        cannot validate identity ... reason:
#          "oidc: malformed jwt: unexpected signature algorithm \"ES256\"; expected [\"RS256\"]"
#      El síntoma en el cliente es un 401 indistinguible de "falta el token", con el
#      AuthConfig en Ready=True y el kid coincidiendo. Nada señala al algoritmo.
#
#   2. El FIRMADOR acepta RS256 (está en el enum del CRD) pero sólo parsea la clave en
#      formato legacy: SEC1 para EC, PKCS#1 para RSA. Con una clave RSA en PKCS#8 falla
#      con "invalid signing key algorithm" — mensaje engañoso, porque el algoritmo es
#      válido; lo que no puede es leer la clave. Y esa falla es peor que la anterior:
#      deja el AuthConfig del EGRESO sin reconciliar, o sea que tumba el camino de la
#      app entera, no sólo la validación en destino.
#
#   Conclusión: RSA 2048 en PKCS#1. Es la única combinación que cierra el lazo
#   firma -> validación. `openssl genrsa` emite PKCS#8 desde OpenSSL 3.x, así que este
#   script fuerza el formato y lo verifica.
#
#   El modelo de confianza de §2 del README no cambia: sigue siendo asimétrico, con la
#   privada sólo en el origen y el público pineado en el destino.
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
# Uso:  ./gen-signing-key.sh [kid] [namespace] [RS256|ES256]
#
# El default es RS256, que es la ÚNICA combinación que cierra el lazo firma -> validación.
# ES256 queda disponible sólo para reproducir el problema: firma bien y el destino lo
# rechaza. Ver el bloque de arriba y README §2.
set -euo pipefail

KID="${1:-egress-echoserver-1}"
NS="${2:-kuadrant-system}"
ALG="${3:-RS256}"
OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"
umask 077

case "$ALG" in
  ES256)
    # SEC1 (`BEGIN EC PRIVATE KEY`) — es el formato con el que Authorino firma OK.
    openssl ecparam -name prime256v1 -genkey -noout -out "$OUT/key.pem"
    openssl ec -in "$OUT/key.pem" -pubout -outform DER -out "$OUT/pub.der" 2>/dev/null
    python3 - "$OUT" "$KID" <<'PY'
import base64, json, sys
out, kid = sys.argv[1], sys.argv[2]
der = open(f"{out}/pub.der", "rb").read()
point = der[-65:]                      # SubjectPublicKeyInfo P-256: últimos 65 bytes
assert point[0] == 0x04, "punto EC no comprimido esperado"
b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
jwk = {"kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
       "x": b64u(point[1:33]), "y": b64u(point[33:65])}
json.dump({"keys": [jwk]}, open(f"{out}/jwks.json", "w"), indent=2)
print("  JWK EC P-256 / ES256")
PY
    rm -f "$OUT/pub.der"
    ;;
  RS256)
    # PKCS#1 (`BEGIN RSA PRIVATE KEY`), NO PKCS#8 — medido en paas-arqlab (2026-08-05).
    #
    # El enum del CRD acepta RS256 para `signingKeyRefs`, pero con una clave en PKCS#8
    # Authorino falla al reconciliar con "invalid signing key algorithm" y deja el AuthConfig
    # del EGRESO caído — o sea que tumba el camino de la app, no sólo la validación en
    # destino. El indicio es que la clave EC que sí funciona sale en SEC1
    # (`BEGIN EC PRIVATE KEY`): Authorino usa los parsers legacy por tipo, no PKCS#8.
    #
    # `openssl genrsa` emite PKCS#8 desde OpenSSL 3.x, así que hay que forzar el formato.
    openssl genrsa -out "$OUT/key.pem" 2048 2>/dev/null
    if ! head -1 "$OUT/key.pem" | grep -q 'BEGIN RSA PRIVATE KEY'; then
      openssl rsa -in "$OUT/key.pem" -traditional -out "$OUT/key.pkcs1.pem" 2>/dev/null \
        && mv "$OUT/key.pkcs1.pem" "$OUT/key.pem"
    fi
    if head -1 "$OUT/key.pem" | grep -q 'BEGIN RSA PRIVATE KEY'; then
      echo "  formato: PKCS#1 (BEGIN RSA PRIVATE KEY) — el que Authorino parsea"
    else
      echo "  AVISO: la clave quedó en $(head -1 "$OUT/key.pem"); Authorino puede rechazarla."
      echo "         este openssl no soporta -traditional; convertir a mano a PKCS#1."
    fi
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
n = bytes.fromhex(n_hex).lstrip(b"\x00") or b"\x00"   # el JWK no lleva el byte de signo del DER
e = bytes.fromhex(e_hex).lstrip(b"\x00") or b"\x01"
jwk = {"kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid, "n": b64u(n), "e": b64u(e)}
json.dump({"keys": [jwk]}, open(f"{out}/jwks.json", "w"), indent=2)
print(f"  JWK RSA: n={len(n)*8} bits, e=0x{e.hex()}")
PY
    rm -f "$OUT/modulus.hex" "$OUT/exponent.hex"
    ;;
  *) echo "algoritmo no soportado: $ALG (usar ES256 o RS256)"; exit 2 ;;
esac

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
