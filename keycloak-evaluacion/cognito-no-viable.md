# Por qué Cognito no es viable como emisor de identidad para el flujo OCP↔EKS

**Para**: arquitecto OpenShift
**De**: equipo PoC Kuadrant (EKS↔OCP)
**Fecha**: 2026-08-14
**Contexto**: evaluando reemplazar el wristband JWT casero (Authorino firmando con clave propia) por
un IdP real, para el `client_credentials` M2M entre `bff`/`egress-gw` y el backend del otro cluster.
Se evaluaron Keycloak y Amazon Cognito. Cognito queda descartado por un motivo de conectividad
concreto, no por preferencia de producto.

## 1. El hallazgo técnico

Cognito user pools sumó soporte de AWS PrivateLink en noviembre 2025. Pero el anuncio oficial de
AWS es explícito sobre el alcance:

> El soporte cubre operaciones de gestión del user pool y flujos de sign-in para usuarios locales.
> **El flujo de código de autorización OAuth 2.0, el flujo de `client credentials`, y el sign-in
> federado vía SAML/OIDC no están soportados a través de VPC endpoints por el momento.**

`client_credentials` es exactamente el flujo que necesitamos para autenticación M2M (no hay
usuario humano de por medio, es un servicio autenticándose contra otro). **Ese flujo específico
está fuera del alcance de PrivateLink**, hoy y sin fecha de cambio anunciada.

Fuentes:
- [Amazon Cognito user pools now supports private connectivity with AWS PrivateLink](https://aws.amazon.com/about-aws/whats-new/2025/11/amazon-cognito-user-pools-private-connectivity-aws-privatelink) (AWS, nov. 2025)
- [Amazon Cognito identity pools now support private connectivity with AWS PrivateLink](https://aws.amazon.com/about-aws/whats-new/2025/12/amazon-cognito-identity-pools-private-connectivity-aws-privatelink) (AWS, dic. 2025)

## 2. Por qué esto es decisivo — no es un detalle menor

En cualquier flujo `client_credentials`, hay tres roles: **emisor** (firma el token), **cliente**
(el que pide el token antes de hacer su llamada real) y **validador** (el que recibe el request y
chequea la firma). El validador solo necesita la clave pública del emisor, descargada una vez y
cacheada — liviano, sin fricción de red relevante. El **cliente**, en cambio, necesita alcanzar el
endpoint de token del emisor **en cada ciclo de renovación**.

En el flujo que ya está corriendo en producción hoy (`poc-egress-kuadrant`, OCP→EKS), **el cliente
que pediría el token es OCP** (`egress-gw` en el cluster origen firma/pediría el token antes de
salir hacia EKS). Si el emisor fuera Cognito:

- OCP necesitaría alcanzar `https://<domain>.auth.<region>.amazoncognito.com/oauth2/token` — un
  endpoint público de AWS.
- PrivateLink no cubre esa llamada (punto 1).
- La única vía que queda es salida real a internet desde el cluster on-prem hacia el endpoint
  regional público de Cognito — o una excepción de red específica para ese rango.

Esto no es hipotético: es el mismo tipo de restricción de conectividad que ya identificamos como
riesgo abierto en la PoC original (`poc-egress-kuadrant/origen/02-serviceentry-destino.yaml`,
sección de proxy corporativo) — cualquier salida a internet desde on-prem pasa por controles que
hoy no están habilitados para este caso de uso, y habilitarlos es un cambio de política de red, no
de configuración de la app.

## 3. Por qué no alcanza con "abrir una excepción de salida a internet"

Aunque se consiguiera esa excepción de red:

- Es una superficie de exposición nueva que hoy no existe — todo lo demás de esta integración
  (NLB internal, TLS con el cert del banco en vez de ACM, sin exponer nada por fuera del cluster)
  se diseñó explícitamente para **no** depender de tráfico saliente a endpoints públicos.
- Ata la disponibilidad de la autenticación M2M a la disponibilidad de un servicio público de AWS
  fuera del control de la plataforma on-prem — un cambio de postura de riesgo que amerita su
  propia revisión, no algo para decidir como efecto colateral de elegir un IdP.
- Si en el futuro la dirección se invierte (EKS pidiendo tokens para hablar con OCP), el problema
  desaparece solo, porque ahí el cliente sería EKS (que ya tiene salida estándar a endpoints de
  AWS) — pero **hoy, con el flujo que está en producción, el cliente es OCP**, y ese es el caso
  que hay que resolver.

## 4. Conclusión

Cognito queda descartado como emisor mientras OCP sea quien pida los tokens — no por límites de
producto en general, sino porque el flujo `client_credentials` específicamente no tiene camino
privado hoy. La recomendación es **Keycloak**, autohospedado (en OCP, en EKS, o en un tercer lugar
de plataforma alcanzable simétricamente desde ambos), que no tiene esta restricción porque no
depende de un endpoint público de ningún proveedor cloud.

Detalle de despliegue, gestión y qué reemplaza exactamente de la PoC actual: ver
[`README.md`](README.md) en esta misma carpeta.
