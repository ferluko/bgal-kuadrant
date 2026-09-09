# Cerrar el hallazgo: por qué `claims-esperados` no rechaza en el destino OCP

## El hallazgo, tal como quedó

Confirmado en vivo el 2026-09-02 (`vault-emisor-spiffe.md` §2quater): se cambió temporalmente
el `template` del `spiffe/role` en Vault a un `sub` no autorizado (`.../poc/impostor`), dejando
todo lo demás igual, y el token resultante **llegó al pod real de OCP con 200 OK**, con el `sub`
impostor decodificado del header recibido — no inferido. La `AuthPolicy` mostraba
`Enforced: True`.

Conclusión que quedó escrita: el bloque `authorization.claims-esperados` no tiene efecto real.
Causa: sin aislar.

## Hipótesis principal — poda silenciosa del campo `predicate`

Los CRDs de Kubernetes usan *structural schemas*: **un campo que el schema no declara se
descarta en silencio al aplicar**. El API server no falla, no advierte, y `oc apply` devuelve
`configured`. El recurso queda guardado sin ese campo.

Si el CRD `authpolicies.kuadrant.io` instalado en arqlab no declara
`patternMatching.patterns[].predicate` (por ejemplo porque esa versión espera el trío
`selector`/`operator`/`value`), entonces:

- los tres patrones se guardan **vacíos**,
- una lista de patrones vacíos no rechaza nada,
- y `Enforced: True` es honesto: Kuadrant está enforceando exactamente lo que quedó guardado,
  que es nada.

Esto explica los tres síntomas a la vez —el impostor pasando, el `Enforced: True`, y la
ausencia total de errores en los logs del operador— cosa que ninguna hipótesis de "error de
sintaxis CEL" explica bien (un CEL roto normalmente sí loguea).

**Hay evidencia indirecta a favor**: el preflight del 2026-09-09 encontró que el CRD de
paas-lab **no tiene** `credentials.customHeader.prefix`, mientras que los manifiestos de la PoC
lo usaban. Es exactamente la misma clase de deriva de schema, en la misma familia de CRDs.

## Cómo probarlo — un comando, sin tocar nada

```bash
oc --context=<arqlab> -n poc-ingress-kuadrant get authpolicy backend-ingress-vault-spiffe \
  -o jsonpath='{.spec.rules.authorization}' | python3 -m json.tool
```

Comparar con el YAML que se aplicó:

- **Los `predicate` NO están** → hipótesis confirmada. Es poda de schema. Fin del misterio.
- **Los `predicate` SÍ están, con el texto correcto** → hipótesis descartada, seguir abajo.

Confirmar además qué acepta el CRD realmente:

```bash
oc --context=<arqlab> explain authpolicy.spec.rules.authorization.patternMatching.patterns --recursive
```

## Si los predicados sí sobrevivieron

Segundo candidato, por orden de probabilidad:

1. **`aud` como lista vs string.** El claim real llega como `["app3..."]`. Si Authorino lo
   aplana a string, `in` sobre un string hace *substring match* en CEL — y
   `"app3.paas-demo..." in "app3.paas-demo..."` da `true` siempre, incluso para el token
   equivocado si un valor es prefijo del otro. Probar cambiando ese predicado a `==` y ver si
   el comportamiento cambia. **Este quedó marcado como SIN VERIFICAR desde el 2026-09-02.**
2. **El bloque no se está evaluando porque la identidad no resolvió.** Si `auth.identity` es
   nulo, según cómo Authorino trate el error el patrón puede evaluar a "no falso". Se distingue
   pidiendo el `x-forwarded-src-*` de vuelta: si la policy puede leer un claim y devolverlo en
   un header, la identidad resolvió.
3. **Dos AuthPolicy compitiendo por el mismo `targetRef`.** Kuadrant marca una como
   *overridden*. Si la que gana es la vieja (wristband), estás mirando el status de la que no
   se aplica. `oc get authpolicy -n poc-ingress-kuadrant` y mirar TODAS.

## La prueba negativa, bien hecha

Lo que **no** sirve: mandar un `x-egress-token` basura desde el cliente. Authorino en el origen
**sobreescribe** cualquier valor que mande el cliente (confirmado en vivo), así que el token
que cruza es siempre el bueno.

Lo que **no** sirve tampoco: pegarle al hostname externo con `Host` a mano por el puerto 80.
Eso golpea un listener distinto del que usa el tráfico real (443) y puede estar bypaseando la
policy en vez de probarla — así se invalidó la primera prueba negativa.

Lo que **sí** funcionó, y es lo que hay que repetir: cambiar temporalmente el `template` del
`spiffe/role` en Vault a un `sub` no autorizado, dejando el resto igual. Así el token que sale
por el camino real es genuinamente inválido según las reglas, sin tocar nada de Kubernetes.

```bash
# 1. Guardar el template actual
curl -sS "$V/spiffe/role/egress-gw-paas-lab" -H "$H" -H "X-Vault-Token: $T" | python3 -m json.tool

# 2. Cambiarlo a un sub no autorizado (requiere token con permiso de escritura en spiffe/role,
#    NO el de la policy mint-only)
curl -sS -X POST "$V/spiffe/role/egress-gw-paas-lab" -H "$H" -H "X-Vault-Token: $T" \
  -d '{"template": "{\"sub\": \"spiffe://poc-egress.bancogalicia.com.ar/paas-lab/impostor\"}", "ttl": "300"}'

# 3. Esperar a que venza el cache de Authorino (ttl 250s) o reiniciarlo, si no seguís usando
#    el token viejo y la prueba no prueba nada:
oc --context=<paas-lab> -n kuadrant-system rollout restart deployment authorino

# 4. Tráfico real desde el bff. ESPERADO: 403. Si da 200, el hallazgo se reproduce.
# 5. REVERTIR INMEDIATAMENTE el template y confirmar con tráfico que el sub volvió al bueno.
```

El paso 3 es el que faltó considerar la primera vez: con el cache puesto, un cambio en Vault
tarda hasta 250 s en verse. Sin reiniciar, se prueba con el token viejo y el resultado engaña.

## Por qué conviene cerrarlo ahora y no después

paas-lab entra como tercer cluster. Si `claims-esperados` no evalúa, entonces **cualquier
workload que consiga un token de Vault entra a cualquier destino** — el `sub` deja de ser un
control y pasa a ser decoración. Con dos clusters era un hallazgo; con tres es el argumento
central de la PoC (identidad por workload) quedando sin sustento demostrable.
