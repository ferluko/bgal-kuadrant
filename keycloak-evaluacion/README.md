# Keycloak — opciones de instalación, modelo de gestión, y qué reemplaza de la PoC

Documento de evaluación, compañero de [`keycloak-sin-null.svg`](keycloak-sin-null.svg) y
[`keycloak-con-null.svg`](keycloak-con-null.svg). No es una decisión tomada, es la base para
evaluar internamente.

## 1. Opciones de instalación

| Modelo | Qué implica | Cuándo tiene sentido |
|---|---|---|
| **Contenedor suelto** (`quay.io/keycloak/keycloak`) | Corrés vos el proceso, DB externa aparte, sin HA de fábrica. | PoC/dev rápido, no producción. |
| **Keycloak Operator en Kubernetes** | Forma oficial recomendada para producción en K8s. CRDs propios: `Keycloak` (instancia, réplicas, TLS, DB) y `KeycloakRealmImport` (carga declarativa de un realm). | El camino natural acá — ya gestionan todo (EKS, Istio, Kuadrant) como recursos Kubernetes/Terraform, y ya tienen el patrón de Operator para el resto de la plataforma (`platform-gateway.tf`). |
| **Bare metal / VM** | Igual de soportado, menos relevante dado cómo ya operan. | Solo si hay un mandato específico de no usar K8s para esto. |

**HA real**: Keycloak replica sesiones/cache entre nodos vía Infinispan (JGroups), y necesita una
base de datos externa persistente para realms/clients/usuarios — Postgres es la más recomendada
(también soporta MySQL/MariaDB, Oracle, MSSQL). No es opcional para producción con más de una
réplica.

**No existe un "Keycloak-as-a-Service" oficial** del propio proyecto (a diferencia de Auth0/Okta,
que son SaaS por diseño). Es fundamentalmente self-hosted.

### Soporte enterprise

**Red Hat build of Keycloak (RHBK)** — distribución soportada y certificada de Red Hat, con SLA y
compromiso de parcheo de CVEs. Antes se llamaba **Red Hat Single Sign-On (RH-SSO)**; mismo
producto, rebranding para alinearse con el nombre de la comunidad. Dado que ya tienen OpenShift y
probablemente el mismo paraguas de contrato con Red Hat, es el camino de soporte más directo —
misma relación comercial que ya tienen, no un vendor nuevo.

⚠️ **Sin confirmar: soporte de RHBK en EKS específicamente.** No tengo visibilidad de la matriz de
soporte actual, y hay un precedente dentro de este mismo repo que invita a la cautela: el ADR de
Kuadrant/RHCL documenta que **RHCL recién tiene soporte en EKS a partir de 2027** — mientras tanto
usan Kuadrant upstream en EKS sin SLA de CVE de Red Hat. No asumir que RHBK tiene la misma cobertura
en EKS que en OpenShift sin confirmarlo con el account team/TAM de Red Hat o el
[Red Hat Ecosystem Catalog](https://catalog.redhat.com).

## 2. Modelo de gestión — UI vs. API

Las dos vías son completamente equivalentes en capacidades; la Admin Console (UI) es, por dentro,
un cliente más de la Admin REST API.

| Vía | Para qué sirve | Automatizable |
|---|---|---|
| **Admin Console (UI)** | Exploración, debug, configuración puntual/manual, onboarding de un admin nuevo. | No — es para humanos. |
| **Admin REST API** (`/admin/realms/{realm}/...`) | Crear/borrar realms, clients, roles, mappers de claims. Bien documentada, es lo que cualquier automatización externa (Null, un Operator, un pipeline) llamaría. | Sí — es el punto de integración real (ver `keycloak-con-null.svg`, pasos 2a). |
| **Terraform provider** (`keycloak/terraform-provider-keycloak`) | Gestión declarativa de realms/clients/mappers como código. | Sí — y es el que más encaja con cómo ya manejan todo lo demás en este repo (`main.tf`, `terraform apply`, el mismo flujo que usamos para el addon `vpc-cni` esta sesión). Vale la pena evaluarlo antes que llamar la REST API a mano desde un script custom. |

**Recomendación de gestión**: si el alta de clients va a ser un flujo continuo (cada suscripción
nueva), la Admin REST API (o el provider de Terraform, si el volumen de altas encaja con un flujo
de PR/apply) es el camino — la UI queda para soporte/debug, no como mecanismo primario.

## 3. Qué reemplaza de la PoC que ya armamos

Mapeo directo contra lo que construimos en `poc-egress-kuadrant/` y `poc-ingress-kuadrant/` esta
sesión:

| Pieza actual de la PoC | Qué es hoy | Con Keycloak |
|---|---|---|
| `keys/gen-signing-key.sh` | Genera a mano el par RSA (PKCS#1, porque Authorino no acepta PKCS#8 — nos costó descubrirlo) | Desaparece. Keycloak genera y rota sus propias claves de firma por realm, sin intervención. |
| `Secret egress-eks-1` / `egress-echoserver-1` en `kuadrant-system` | Clave privada compartida de plataforma — cualquiera con permiso de crear `AuthPolicy` ahí podría, en teoría, pedir que le firmen con esa clave | Desaparece como riesgo. Cada consumidor tiene su propio `client_id`/secret en Keycloak; no hay clave de firma compartida entre consumidores. |
| `destino/11-jwks-static.yaml` (`ConfigMap` + `httpd`) | JWKS pineado a mano, copiado por chat/archivo entre clusters | Desaparece. Keycloak publica `jwks_uri` vía OIDC discovery (`/.well-known/openid-configuration`) — Authorino lo resuelve solo con `issuerUrl`. |
| Rotación de clave (la vivimos en vivo, EC→RSA) | Regenerar, pegar el JSON a mano, **borrar y recrear el `AuthPolicy`** para forzar refetch (si no, cachea 300s) | Desaparece el paso manual. La validación OIDC estándar de Authorino maneja el cambio de `kid` sin necesidad de recrear nada. |
| `AuthPolicy...wristband` (`response.success.headers` con `wristband:`) | Authorino firma el JWT él mismo, con `customClaims` hardcodeados como string (`src_cluster: "devops-cilium-1-35"`, etc.) | Cambia de rol: ya no firma nada. Keycloak emite el token (`client_credentials` grant); el `AuthPolicy` de origen desaparece o se reduce a solo pasar el `Authorization: Bearer` que ya trae la app. |
| `patternMatching` en el `AuthPolicy` de destino (`auth.identity.src_cluster == "..."`) | Compara contra un claim que **cualquiera podría haber declarado** al firmar — no hay nada criptográfico atándolo a quién es realmente el llamador (el problema real, documentado como OQ-11 en el README de `poc-egress-kuadrant`) | Se reemplaza por `auth.identity.azp == "<client_id>"` — el `client_id` que validó **es** la credencial que se autenticó contra Keycloak, no un string libre. Cierra OQ-11 de raíz. |
| `keys/out/jwks.json` pegado a mano en el `ConfigMap` del otro cluster | Copy-paste manual de material público entre clusters, cada vez que rota | Desaparece — cada cluster solo necesita la URL del realm de Keycloak (`issuerUrl`), no un archivo que sincronizar. |

### Lo que NO cambia

- El punto de enforcement sigue siendo Kuadrant/Authorino — `AuthPolicy` sobre el `HTTPRoute`, mismo lugar donde vive hoy.
- El patrón de intercepción por `selector` del `Service` (el cutover) no tiene nada que ver con esto — sigue igual.
- `RateLimitPolicy` no cambia — sigue contando por claim, solo que ahora el claim viene de un IdP real en vez de ser declarado.
- Sigue faltando la automatización de creación de `HTTPRoute`/`AuthPolicy` por consumidor nuevo — **eso es lo que resuelve Null**, no Keycloak (ver los dos diagramas).

## 4. Preguntas abiertas para cerrar antes de avanzar

1. ¿Soporte de RHBK en EKS? (sin confirmar, ver §1)
2. ¿Null soporta llamar APIs externas + aplicar manifiestos K8s de forma nativa, o hace falta un servicio intermedio? (sin confirmar, ver `keycloak-con-null.svg`)
3. ¿Provider de Terraform de Keycloak vs. Admin REST API directa — cuál encaja mejor con el volumen de altas esperado?
4. ¿Dónde vive el realm — un Keycloak por cluster (EKS y OCP cada uno con el suyo) o uno compartido? Esto no lo evaluamos todavía y cambia bastante el diseño de confianza entre clusters.
