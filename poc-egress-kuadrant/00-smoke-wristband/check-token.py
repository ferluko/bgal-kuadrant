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

# SubjectPublicKeyInfo DER de una clave EC P-256, hasta el bit string del punto.
P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")


def b64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def spki_pem(x: bytes, y: bytes) -> str:
    """JWK (x, y) -> PEM de clave pública, sin dependencias."""
    der = P256_SPKI_PREFIX + b"\x04" + x.rjust(32, b"\x00") + y.rjust(32, b"\x00")
    b = base64.b64encode(der).decode()
    cuerpo = "\n".join(b[i:i + 64] for i in range(0, len(b), 64))
    return f"-----BEGIN PUBLIC KEY-----\n{cuerpo}\n-----END PUBLIC KEY-----\n"


def raw_a_der(raw: bytes) -> bytes:
    """Firma JWS ES256 (R||S de 64 bytes) -> SEQUENCE DER que entiende openssl."""
    def entero(b):
        b = b.lstrip(b"\x00") or b"\x00"
        if b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b

    cuerpo = entero(raw[:32]) + entero(raw[32:])
    return b"\x30" + bytes([len(cuerpo)]) + cuerpo


def verificar_firma(jwk, firmado: bytes, sig: bytes):
    """True/False/None (None = no se pudo ejecutar openssl)."""
    tmp = tempfile.mkdtemp(prefix="wristband-")
    try:
        pub = os.path.join(tmp, "pub.pem")
        der = os.path.join(tmp, "sig.der")
        msg = os.path.join(tmp, "msg.bin")
        with open(pub, "w") as f:
            f.write(spki_pem(b64u(jwk["x"]), b64u(jwk["y"])))
        with open(der, "wb") as f:
            f.write(raw_a_der(sig))
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

    if header.get("alg") != "ES256":
        problemas.append(f"alg={header.get('alg')!r}, se esperaba 'ES256'")

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
