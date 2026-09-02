# Incidente: `412 - required index state not present` en operaciones LIST/POST — `admin/spiffe`

**RESUELTO SOLO — 2026-09-02, ~15:10 UTC.** Después de ~20 min y de probar `auth/kubernetes`
(enable + role + LIST, los tres `200`/`204` sin problema — sirvió para descartar que fuera un
índice roto a nivel de todo el namespace), se reintentaron `LIST /spiffe/role` y `POST
/auth/jwt/role/authorino-egress` sin cambiar nada, y ambos dieron OK (`200` y `204`). El `Role`
`authorino-egress` quedó creado y confirmado (`GET`/`LIST` ambos `200`, con los campos esperados).
No se pudo confirmar la causa raíz — parece un blip transitorio del backend de Vault/HCP más largo
que el anterior (~20 min vs ~10s), no algo que requiriera acción de nuestro lado ni de Seginf. No
hace falta escalar; queda documentado como antecedente por si vuelve a pasar.

**Fecha**: 2026-09-02, ~14:50 UTC. **Namespace afectado**: `admin/spiffe`, mismo Vault de siempre
(`vault-cluster-noprod-private-vault-16d614b5.bc6ede80.z1.hashicorp.cloud:8200`).

## Resumen

Al crear el `Role` `authorino-egress` en el mount `auth/jwt` (paso siguiente del plan en
[`authpolicy-vault-spiffe-ejemplo.yaml`](authpolicy-vault-spiffe-ejemplo.yaml), pedido pendiente
punto 2), el `POST /v1/auth/jwt/role/authorino-egress` devolvió:

```
HTTP 412
{"errors":["required index state not present"]}
```

Ya lo habíamos visto una vez antes (en `POST /auth/jwt/config`) y se resolvió solo con un
reintento a los ~10s — se asumió transitorio. Esta vez **no se resolvió con reintento**, y al
investigar se confirmó que **no es específico del Role nuevo**: afecta también a `LIST
/v1/spiffe/role`, el mount que ya está funcionando en producción de pruebas desde el 2026-08-28
(login, mint, discovery y JWKS confirmados end-to-end).

## Evidencia (mismo AppRole de siempre, namespace `admin/spiffe`)

| Llamada | Resultado |
|---|---|
| `GET /auth/jwt/config` | `200` — config correcta, `oidc_discovery_url` guardada bien |
| `GET /sys/auth` | `200` — `jwt/` listado correctamente como mount |
| `LIST /auth/jwt/role` | `412 - required index state not present` |
| `LIST /spiffe/role` | `412 - required index state not present` **(mount que ya funcionaba)** |
| `POST /auth/jwt/role/authorino-egress` | `412 - required index state not present` |
| `GET /auth/jwt/role/authorino-egress` (después del POST) | `404` — confirma que el Role NO quedó creado, el POST realmente falló |

## Interpretación

Los `GET` puntuales (leer un objeto por nombre) funcionan bien. Lo que falla consistentemente es
cualquier operación que toca el **índice** — `LIST` de una colección, y aparentemente también
`POST`/creación de un objeto nuevo (que necesita actualizar el índice de esa colección). Como esto
ya afecta a `spiffe/role`, que veníamos usando sin problemas, parece un problema de
infraestructura del lado de Vault/HCP en este momento, no de la configuración que estamos
armando nosotros.

## Pendiente

- Confirmar con Seginf si es un incidente conocido del lado de HCP para este cluster/namespace.
- Una vez resuelto, reintentar sin cambios el `POST /auth/jwt/role/authorino-egress` documentado
  en el punto 2 del "PEDIDO PENDIENTE PARA SEGINF" de
  [`authpolicy-vault-spiffe-ejemplo.yaml`](authpolicy-vault-spiffe-ejemplo.yaml).
