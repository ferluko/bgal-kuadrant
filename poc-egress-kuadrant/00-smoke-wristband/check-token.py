#!/usr/bin/env python3
"""Decodifica y valida el wristband emitido por Authorino.

Uso:
    ./check-token.py '<jwt>' [ruta/a/jwks.json]

Sin jwks.json sólo decodifica e imprime. Con jwks.json además:
  - compara el `kid` del header contra el del JWKS  <-- el riesgo #1 de la PoC
  - verifica la FIRMA con la clave pública que se le va a copiar al cluster destino

Verificar la firma acá, en el origen, prueba que el JWKS que se pinea en destino
sirve — antes de montar TLS, F5 y el segundo cluster.

Sólo necesita python3 stdlib y el binario `openssl`. Sin pip, sin dependencias.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

# El wristband se firma con RSA/RS256 y no con EC — ver keys/gen-signing-key.sh: el
# verificador `jwt` de Authorino sólo acepta RS256, así que la clave del PoC es RSA.
# Se conserva el soporte de EC para poder validar tokens viejos.
P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
RSA_ALG_ID = bytes.fromhex("300d06092a864886f70d0101010500")   # rsaEncryption, params NULL


def b64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def _der(tag: int, payload: bytes) -> bytes:
    return bytes([tag]) + _der_len(len(payload)) + payload


def _entero(b: bytes) -> bytes:
    b = b.lstrip(b"\x00") or b"\x00"
    if b[0] & 0x80:
        b = b"\x00" + b          # el DER es con signo: 0x00 al frente si el MSB está en 1
    return _der(0x02, b)


def _pem(der: bytes) -> str:
    b = base64.b64encode(der).decode()
    cuerpo = "\n".join(b[i:i + 64] for i in range(0, len(b), 64))
    return f"-----BEGIN PUBLIC KEY-----\n{cuerpo}\n-----END PUBLIC KEY-----\n"


def spki_pem(jwk) -> str:
    """JWK -> PEM de clave pública, sin dependencias externas. RSA (n,e) o EC (x,y)."""
    if jwk.get("kty") == "RSA":
        rsa_pub = _der(0x30, _entero(b64u(jwk["n"])) + _entero(b64u(jwk["e"])))
        bitstring = _der(0x03, b"\x00" + rsa_pub)
        return _pem(_der(0x30, RSA_ALG_ID + bitstring))
    x, y = b64u(jwk["x"]), b64u(jwk["y"])
    return _pem(P256_SPKI_PREFIX + b"\x04" + x.rjust(32, b"\x00") + y.rjust(32, b"\x00"))


def raw_a_der(raw: bytes) -> bytes:
    """Firma JWS ES256 (R||S de 64 bytes) -> SEQUENCE DER que entiende openssl."""
    cuerpo = _entero(raw[:32]) + _entero(raw[32:])
    return _der(0x30, cuerpo)


def verificar_firma(jwk, firmado: bytes, sig: bytes):
    """True/False/None (None = no se pudo ejecutar openssl)."""
    tmp = tempfile.mkdtemp(prefix="wristband-")
    try:
        pub = os.path.join(tmp, "pub.pem")
        der = os.path.join(tmp, "sig.der")
        msg = os.path.join(tmp, "msg.bin")
        with open(pub, "w") as f:
            f.write(spki_pem(jwk))
        with open(der, "wb") as f:
            # RSA: la firma JWS ya es el bloque PKCS#1 crudo. EC: hay que re-encodearla.
            f.write(sig if jwk.get("kty") == "RSA" else raw_a_der(sig))
        with open(msg, "wb") as f:
            f.write(firmado)
        r = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", pub, "-signature", der, msg],
            capture_output=True, text=True,
        )
        if r.returncode == 0 and "Verified OK" in r.stdout:
            return True
        if "Verification Failure" in r.stdout or r.returncode == 1:
            return False
        print(f"[!] openssl no pudo verificar: {(r.stderr or r.stdout).strip()}")
        return None
    except FileNotFoundError:
        print("[!] no encuentro el binario `openssl`: no verifico la firma.")
        return None
    finally:
        for n in ("pub.pem", "sig.der", "msg.bin"):
            try:
                os.unlink(os.path.join(tmp, n))
            except OSError:
                pass
        os.rmdir(tmp)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    token = sys.argv[1].strip()
    parts = token.split(".")
    if len(parts) != 3:
        sys.exit(f"no parece un JWT: {len(parts)} segmento(s)")

    header = json.loads(b64u(parts[0]))
    payload = json.loads(b64u(parts[1]))
    sig = b64u(parts[2])

    print("--- header ---")
    print(json.dumps(header, indent=2))
    print("--- payload ---")
    print(json.dumps(payload, indent=2))

    problemas = []

    # Medido el 2026-08-05 en paas-arqlab (RHCL 1.x): Authorino FIRMA sólo ES* —con RS256 el
    # AuthConfig del egreso ni reconcilia, "invalid signing key algorithm"— y su verificador
    # `jwt` acepta sólo RS256. Es decir: Authorino no puede validar su propio wristband.
    # Por eso acá se aceptan los dos y se avisa qué implica cada uno; ver README §2.
    alg = header.get("alg")
    if alg not in ("ES256", "ES384", "ES512", "RS256"):
        problemas.append(f"alg={alg!r}, se esperaba ES256/ES384/ES512 o RS256")
    elif alg.startswith("ES"):
        print(
            f"\n[!] alg={alg}: correcto para que Authorino FIRME, pero su verificador `jwt`\n"
            "    sólo acepta RS256. El destino tiene que validar con Istio\n"
            "    (RequestAuthentication, JWKS inline) — ver destino/13a y README §2."
        )

    now = int(time.time())
    exp, iat = payload.get("exp"), payload.get("iat")
    if exp is None:
        problemas.append("sin claim exp: el token no expira")
    else:
        print(f"\nexp en {exp - now}s", end="")
        if iat:
            print(f" (tokenDuration ≈ {exp - iat}s)", end="")
        print()
        if exp - now <= 0:
            problemas.append("token ya expirado")

    esperados = {
        "iss": "https://egress.paas-arqlab.bancogalicia.com.ar",
        "aud": "app2.paas-demo.bancogalicia.com.ar",
        "src_cluster": "paas-arqlab",
        "src_namespace": "echoserver",
        "dst_service": "server2",
    }
    for k, v in esperados.items():
        if payload.get(k) != v:
            problemas.append(f"claim {k}={payload.get(k)!r}, se esperaba {v!r}")

    firma_verificada = False
    if len(sys.argv) > 2:
        keys = json.load(open(sys.argv[2]))["keys"]
        kid = header.get("kid")
        print(f"\nkid del token : {kid}")
        print(f"kid del JWKS  : {[k.get('kid') for k in keys]}")

        jwk = next((k for k in keys if k.get("kid") == kid), None)
        if jwk is None:
            problemas.append(
                "el kid del token NO está en el JWKS: el destino rechazaría el token. "
                "Regenerar con ../keys/gen-signing-key.sh <kid-real> o editar "
                "destino/11-jwks-static.yaml"
            )
            if len(keys) == 1:
                jwk = keys[0]
                print("  (verifico igual contra la única clave del JWKS)")

        if jwk:
            ok = verificar_firma(jwk, f"{parts[0]}.{parts[1]}".encode(), sig)
            if ok is True:
                print("\nFIRMA VÁLIDA contra el JWKS público.")
                firma_verificada = True
            elif ok is False:
                problemas.append("FIRMA INVÁLIDA contra el JWKS público")

    print()
    if problemas:
        print("PROBLEMAS:")
        for p in problemas:
            print(f"  - {p}")
        sys.exit(1)
    if firma_verificada:
        print("OK — token bien formado, claims esperados y firma verificada contra el JWKS.")
    else:
        print("OK — token bien formado y claims esperados. FIRMA NO VERIFICADA "
              "(pasar el jwks.json como segundo argumento).")


if __name__ == "__main__":
    main()
