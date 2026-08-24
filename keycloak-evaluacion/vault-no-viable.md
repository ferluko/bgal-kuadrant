# Por qué HashiCorp Vault no sirve como emisor de identidad para el flujo OCP↔EKS

**Para**: arquitecto OpenShift
**De**: equipo PoC Kuadrant (EKS↔OCP)
**Fecha**: 2026-08-14
**Contexto**: mismo que [`cognito-no-viable.md`](cognito-no-viable.md) — se evaluó si Vault podía
ocupar el rol de **emisor** (quien firma el token que `bff`/`egress-gw` presenta al cruzar de
cluster), como alternativa a Keycloak. Se revisaron tres mecanismos de Vault, con la documentación
oficial de HashiCorp como fuente — ninguno cubre el flujo `client_credentials` M2M que necesitamos.

## 1. Los tres roles, recordatorio rápido

Igual que con Cognito: hay un **emisor** (firma el token), un **cliente** (lo pide antes de la
llamada real) y un **validador** (chequea la firma en destino). Lo que se evaluó acá es si Vault
puede ocupar el rol de **emisor** — es decir, si puede entregarle a `egress-gw` un JWT/OIDC que el
`AuthPolicy` del cluster destino pueda validar vía `issuerUrl`/JWKS, sin intervención humana.

## 2. Los tres mecanismos de Vault evaluados

### `auth/jwt` — dirección inversa a la que necesitamos

> "Vault VALIDA y ACEPTA tokens emitidos por proveedores externos [...] Si es válido, Vault EMITE
> su propio token de acceso de Vault."
> — [Vault JWT/OIDC Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)

Este método sirve para que Vault **consuma** un JWT ya emitido por otro (Keycloak, Okta, el propio
Kubernetes) y a cambio deje entrar a Vault. Es la dirección opuesta a "Vault emite el token que
otro va a validar". No aplica.

### `identity/oidc` (Vault OIDC Provider) — sí emite, pero no para M2M

> "El Vault OIDC provider actualmente soporta el siguiente flujo de autenticación: *Authorization
> Code Flow*." (No se menciona `client_credentials` en ningún lado de la documentación.)
> — [Vault OIDC Identity Provider](https://developer.hashicorp.com/vault/docs/secrets/identity/oidc-provider)

Esta es la pieza de Vault que sí firma y publica JWKS propio (`jwks_uri` en
`/v1/identity/oidc/provider/default/.well-known/keys`, discovery estándar, múltiples algoritmos
de firma soportados) — en ese sentido es técnicamente un emisor OIDC real. El problema es el
flujo: `Authorization Code Flow` es **interactivo**, pensado para un usuario humano pasando por un
navegador. No hay grant type M2M documentado. `bff`/`egress-gw` no tienen usuario ni navegador.

### `AppRole` — M2M real, pero hacia Vault, no hacia afuera

> "AppRole es un método de autenticación machine-to-machine [...] El resultado de una
> autenticación exitosa es un token nativo de Vault, no un JWT/OIDC externo [...] Es un mecanismo
> de autenticación *hacia* Vault, no para emitir credenciales externas."
> — [Vault AppRole Auth Method](https://developer.hashicorp.com/vault/docs/auth/approle)

`AppRole` (`role_id` + `secret_id`) sí es M2M genuino — no requiere humano ni navegador, pensado
exactamente para "automated workflows (machines and services)". Pero el token que devuelve es un
**token nativo de Vault**, útil para llamar a la API de Vault (leer secretos, usar Transit, etc.),
no un JWT/OIDC que un `AuthPolicy` externo pueda validar.

## 3. Tabla resumen

| Mecanismo | ¿M2M sin humano? | ¿Emite JWT/OIDC validable externamente? |
|---|---|---|
| `auth/jwt` | — (es Vault el que consume, no el que emite) | No — dirección inversa |
| `identity/oidc` | No — requiere Authorization Code Flow interactivo | Sí, pero solo en flujo interactivo |
| `AppRole` | Sí | No — devuelve token Vault nativo, no portable afuera |

**Ninguna combinación de los tres cierra el caso**: o falta el M2M, o falta que el resultado sea un
token estándar consumible por un sistema externo (Kuadrant/Authorino en el otro cluster).

## 4. Conclusión

Vault queda descartado como **emisor** para este caso — no por un límite de conectividad como
Cognito, sino porque el flujo M2M→JWT-externo-validable simplemente no está cubierto por ninguno
de sus mecanismos de auth/identity documentados hoy.

**Esto no descarta a Vault del diseño en general.** Sigue siendo la pieza más sólida para dos
problemas reales de esta PoC, como **infraestructura de apoyo**, no como emisor:

- **Transit Secrets Engine**: firma la clave del wristband sin exponer el material privado (
  `AppRole` para el login M2M + `transit/sign` para firmar) — reemplaza el manejo manual de
  `keys/gen-signing-key.sh` y el `Secret` estático en `kuadrant-system`.
- **PKI Secrets Engine**: como CA interna, hubiera evitado directamente el problema de la cadena de
  certificado rota (root equivocado, SKI/AKI que no cerraban) que consumió gran parte de esta
  sesión.

Detalle completo de la comparación Keycloak/Cognito/Vault y qué reemplaza cada uno de la PoC
actual: ver [`README.md`](README.md) en esta misma carpeta.
