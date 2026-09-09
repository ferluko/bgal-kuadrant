# Defecto de diseño: Authorino no relee el token de sesión de Vault

**Confirmado en dos clusters el 2026-09-09.** No es un incidente puntual: es un defecto del diseño
actual que hace que el egreso se caiga solo, aproximadamente una vez por hora.

## El síntoma

```
HTTP 403   x-ext-auth-reason: no such key: data
```

En los logs de Authorino del **origen**:

```json
"GenericHTTP":{"Endpoint":".../v1/spiffe/role/<rol>/mintjwt",
               "SharedSecret":"hvs.CAESIAzV-…"},
"object":{"errors":["2 errors occurred:\n\t* permission denied\n\t* invalid token\n\n"]}
```

Y en consecuencia el predicado `vault_mint_check` (`has(auth.metadata.vault_mint.data.token)`)
evalúa falso, porque una respuesta de error de Vault no trae la key `data`.

## El mecanismo

`invalid token` —no "empty token"— es el dato que lo define: Authorino **sí** manda un
`X-Vault-Token`, pero uno que Vault ya no reconoce.

```
CronJob            escribe un token nuevo en el Secret cada 30 min
token de Vault     TTL = 1 h
Authorino          resuelve sharedSecretRef y se queda con ESE valor
```

Authorino no vuelve a leer el Secret. Pasada la hora, el token que tiene en memoria vence y
**todo el egreso empieza a devolver 403**, sin que nada haya cambiado en la configuración.

## La evidencia, en dos clusters

| Cluster | Qué se vio |
|---|---|
| `paas-lab` | 403 con `no such key: data`. Un `rollout restart authorino` lo destrabó al instante. |
| `paas-arqlab` | los mismos errores en sus propios logs desde las 03:35 — **su egreso hacia EKS estaba caído** y nadie lo había notado. |

Y la prueba que aísla la causa: el token guardado **en el Secret** mintea correctamente contra
Vault en ese mismo momento. O sea que el Secret está bien y la copia en memoria de Authorino no.

Esto explica retroactivamente por qué en arqlab (2026-09-02) el problema "se resolvió con un
`rollout restart`" y las tandas siguientes dieron 40/40 y 30/30: **todas entraron dentro de la
hora de gracia** que compra un reinicio.

## Por qué importa más de lo que parece

Un reinicio programado cada hora no es una respuesta. El patrón —CronJob que rota una credencial
+ consumidor que no la relee— rompe el objetivo del diseño: que la identidad sea de vida corta y
rotable. Hoy la rotación es justamente lo que lo tira abajo.

## Salidas, en orden de preferencia

1. **Sacar la llamada a Vault del camino del request.** El CronJob mintea el JWT-SVID (no solo el
   token de sesión) y lo deja donde Authorino pueda leerlo por request. Es el diseño ya escrito en
   `poc-egress-kuadrant/origen/vault/PROPUESTA-fix-latencia-mint-ocp.md`, que se había archivado por
   innecesario cuando alcanzó el cache. Resuelve de una **este defecto y el de latencia** (485 ms de
   mint contra 200 ms de `ext_authz`), y elimina a Vault como dependencia en línea del tráfico.
2. **Que el CronJob reinicie Authorino después de rotar.** Funciona, es una línea, y es feo: corta
   conexiones y convierte un reinicio en parte del camino feliz.
3. **Confirmar con Red Hat si `sharedSecretRef` debería reflejar cambios del Secret.** Si es un bug,
   corresponde reportarlo; si es el comportamiento esperado, la opción 1 es la única sana.

## Cómo verificar que quedó arreglado

No alcanza con que ande después de reiniciar. Hay que dejar pasar el vencimiento:

```bash
oc --context=<cluster> -n kuadrant-system rollout restart deployment authorino
# confirmar que anda
curl http://bff-lab.paas-demo.bancogalicia.com.ar/
# ...y volver a probar 70-80 min después, SIN tocar nada
```

Si a los 70-80 min sigue en 200, está resuelto. Si vuelve el 403, no.

## Hallazgo aparte, de seguridad — atender ya

Con `logLevel: debug`, Authorino **escribe el token de Vault en claro** en sus logs:

```json
"SharedSecret":"hvs.CAESIAzV-urVUh0wTINLf_6OQByc62bxh5oWFwvzXHpwig8o…"
```

Es una credencial viva en el stdout de un pod, que en este entorno va a parar al agregador de
logs. Dos acciones:

```bash
# 1. bajar el nivel de log
oc --context=paas-arqlab -n kuadrant-system get authorino authorino -o jsonpath='{.spec.logLevel}{"\n"}'
oc --context=paas-arqlab -n kuadrant-system patch authorino authorino --type=merge -p '{"spec":{"logLevel":"info"}}'

# 2. rotar el token expuesto: correr el Job de login a mano y reiniciar Authorino
oc --context=paas-arqlab -n kuadrant-system create job --from=cronjob/vault-egress-login-ocp relogin-$(date +%s)
oc --context=paas-arqlab -n kuadrant-system rollout restart deployment authorino
```

El `logLevel: debug` se había puesto para diagnosticar el 2026-09-02 y quedó activo.
