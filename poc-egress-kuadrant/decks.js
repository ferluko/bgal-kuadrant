const pptxgen = require("pptxgenjs");

const C = {
  dark: "21295C", deep: "065A82", teal: "1C7293", mint: "02C39A",
  amber: "D98324", red: "B03A2E", light: "F2F6F9", white: "FFFFFF",
  gray: "5A6B7B", line: "D6E0E8",
};
const H = "Cambria", B = "Calibri";
const W = 13.333, HT = 7.5, M = 0.7;

/* ---------- helpers ---------- */
function tituloOscuro(s, kicker, titulo, sub) {
  s.background = { color: C.dark };
  s.addText(kicker, { x: M, y: 2.1, w: 11, h: 0.35, fontSize: 14, color: C.mint, fontFace: B, charSpacing: 2, bold: true, margin: 0 });
  s.addText(titulo, { x: M, y: 2.55, w: 11.4, h: 1.7, fontSize: 42, color: C.white, fontFace: H, bold: true, margin: 0, lineSpacing: 46 });
  s.addText(sub, { x: M, y: 4.45, w: 10.5, h: 0.9, fontSize: 16, color: "BFD3E6", fontFace: B, margin: 0, lineSpacing: 24 });
  s.addShape("ellipse", { x: 11.1, y: 5.5, w: 1.6, h: 1.6, fill: { color: C.teal, transparency: 55 }, line: { color: C.teal, width: 0 } });
  s.addShape("ellipse", { x: 11.9, y: 6.1, w: 1.0, h: 1.0, fill: { color: C.mint, transparency: 30 }, line: { color: C.mint, width: 0 } });
}

function encabezado(s, titulo, bajada) {
  s.background = { color: C.white };
  s.addText(titulo, { x: M, y: 0.5, w: 11.9, h: 0.7, fontSize: 34, color: C.dark, fontFace: H, bold: true, margin: 0 });
  if (bajada) s.addText(bajada, { x: M, y: 1.2, w: 11.9, h: 0.45, fontSize: 15, color: C.gray, fontFace: B, italic: true, margin: 0 });
}

function filaIcono(s, y, n, titulo, cuerpo, color) {
  s.addShape("ellipse", { x: M, y: y, w: 0.62, h: 0.62, fill: { color: color }, line: { color: color, width: 0 } });
  s.addText(n, { x: M, y: y, w: 0.62, h: 0.62, fontSize: 20, color: C.white, fontFace: H, bold: true, align: "center", valign: "middle", margin: 0 });
  s.addText(titulo, { x: M + 0.95, y: y - 0.03, w: 11, h: 0.35, fontSize: 19, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText(cuerpo, { x: M + 0.95, y: y + 0.33, w: 11.2, h: 0.75, fontSize: 14.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 20 });
}

function tarjeta(s, x, y, w, h, fill) {
  s.addShape("roundRect", { x, y, w, h, rectRadius: 0.08, fill: { color: fill || C.light }, line: { color: C.line, width: 1 },
    shadow: { type: "outer", color: "8899AA", blur: 8, offset: 2, angle: 90, opacity: 0.18 } });
}

function stat(s, x, y, w, numero, etiqueta, color) {
  s.addText(numero, { x, y, w, h: 0.95, fontSize: 54, color: color, fontFace: H, bold: true, align: "center", margin: 0 });
  s.addText(etiqueta, { x, y: y + 0.95, w, h: 0.7, fontSize: 13, color: C.gray, fontFace: B, align: "center", margin: 0, lineSpacing: 17 });
}

function pie(s, txt) {
  s.addText(txt, { x: M, y: HT - 0.62, w: 11.9, h: 0.3, fontSize: 11, color: "6E7F8D", fontFace: B, margin: 0 });
}

/* =====================================================================
   DECK TÉCNICO
   ===================================================================== */
function tecnico() {
  const p = new pptxgen();
  p.layout = "LAYOUT_WIDE";
  p.author = "Plataforma";
  p.title = "PoC egreso Kuadrant — técnica";

  // 1 — portada
  let s = p.addSlide();
  tituloOscuro(s, "POC · PAAS-ARQLAB · AGOSTO 2026",
    "Egreso seguro entre clusters\ncon Kuadrant / RHCL",
    "Mover un servicio a otro cluster sin tocar a quien lo consume,\ncon el salto autenticado y la migración reversible.");
  s.addText("37 chequeos automatizados · todos en verde", { x: M, y: 5.6, w: 7, h: 0.4, fontSize: 14, color: C.mint, fontFace: B, bold: true, margin: 0 });
  s.addNotes("PoC cerrada el 2026-08-05 en paas-arqlab. Lo que sigue es el diseño, lo que se probó y los hallazgos que cambian decisiones ya tomadas.");

  // 2 — el problema
  s = p.addSlide();
  encabezado(s, "El problema", "server consume server2 por su nombre de Service. Queremos mover server2 a EKS.");
  filaIcono(s, 2.0, "1", "Sin tocar el código ni la URL del consumidor",
    "Mismo host, misma IP, mismo puerto, mismo protocolo. La app no se entera de la migración.", C.deep);
  filaIcono(s, 3.35, "2", "Con el salto entre clusters autenticado",
    "Sin IdP y sin dependencia de red permanente entre los dos lados: clave preacordada, asimétrica.", C.teal);
  filaIcono(s, 4.7, "3", "Migración progresiva y reversible",
    "Nada de big-bang con ventana. Rollback en segundos, en cualquier punto del camino.", C.mint);
  tarjeta(s, M, 6.05, 11.9, 0.75, C.light);
  s.addText("La restricción que ordena todo el diseño: el consumidor no se modifica. Todo lo demás se acomoda a eso.",
    { x: M + 0.3, y: 6.15, w: 11.3, h: 0.55, fontSize: 14.5, color: C.dark, fontFace: B, bold: true, valign: "middle", margin: 0 });

  // 3 — la idea
  s = p.addSlide();
  encabezado(s, "La idea: tres piezas, ninguna nueva", null);
  const piezas = [
    ["Interceptar\npor selector", "Al Service server2 se le cambia el selector: sus endpoints pasan a ser los pods de un gateway de egreso.\n\nMisma ClusterIP, mismo nombre. No se recrea nada.", C.deep],
    ["Firmar\nen la salida", "El gateway emite un JWT de 300 s firmado con una clave que vive sólo en el origen, y lo inyecta en un header.\n\nAl destino sólo va la clave pública.", C.teal],
    ["Repartir\npor peso", "Con el Service ya interceptado, el reparto local/remoto se controla desde el HTTPRoute.\n\nEl Service no se vuelve a tocar.", C.mint],
  ];
  piezas.forEach((pz, i) => {
    const x = M + i * 4.05;
    tarjeta(s, x, 1.95, 3.75, 4.3, C.white);
    s.addShape("ellipse", { x: x + 0.3, y: 2.25, w: 0.5, h: 0.5, fill: { color: pz[2] }, line: { color: pz[2], width: 0 } });
    s.addText(String(i + 1), { x: x + 0.3, y: 2.25, w: 0.5, h: 0.5, fontSize: 17, color: C.white, fontFace: H, bold: true, align: "center", valign: "middle", margin: 0 });
    s.addText(pz[0], { x: x + 0.3, y: 2.95, w: 3.15, h: 0.9, fontSize: 21, color: C.dark, fontFace: H, bold: true, margin: 0, lineSpacing: 25 });
    s.addText(pz[1], { x: x + 0.3, y: 3.95, w: 3.15, h: 2.1, fontSize: 13.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 19, valign: "top" });
  });
  s.addText("El rollback del cutover es el mismo patch al revés: aproximadamente un segundo, sin arranque en frío.",
    { x: M, y: 6.5, w: 11.9, h: 0.4, fontSize: 14, color: C.deep, fontFace: B, bold: true, margin: 0 });

  // 4 — arquitectura
  s = p.addSlide();
  encabezado(s, "El camino de un request", "El consumidor sigue llamando al mismo nombre de Service.");
  const caja = (x, y, w, h, txt, fill, fg) => {
    s.addShape("roundRect", { x, y, w, h, rectRadius: 0.1, fill: { color: fill }, line: { color: fill, width: 0 } });
    s.addText(txt, { x: x + 0.08, y, w: w - 0.16, h, fontSize: 13, color: fg || C.white, fontFace: B, bold: true, align: "center", valign: "middle", margin: 0 });
  };
  const flecha = (x, y, w) => s.addShape("line", { x, y, w, h: 0, line: { color: C.gray, width: 2, endArrowType: "triangle" } });

  caja(M, 2.3, 1.5, 0.75, "cliente", C.gray);
  flecha(M + 1.55, 2.68, 0.5);
  caja(M + 2.1, 2.3, 1.7, 0.75, "Envoy\ningress", C.deep);
  flecha(M + 3.85, 2.68, 0.5);
  caja(M + 4.4, 2.3, 1.5, 0.75, "server", C.deep);
  flecha(M + 5.95, 2.68, 0.5);
  caja(M + 6.5, 2.15, 2.1, 1.05, "Service server2\nselector cambiado", C.amber);
  s.addShape("line", { x: M + 7.55, y: 3.25, w: 0, h: 0.55, line: { color: C.gray, width: 2, endArrowType: "triangle" } });
  caja(M + 6.2, 3.85, 2.7, 0.9, "Gateway de egreso\nfirma el JWT", C.teal);

  s.addShape("line", { x: M + 6.6, y: 4.8, w: -1.6, h: 0.75, line: { color: C.gray, width: 2, endArrowType: "triangle" } });
  s.addShape("line", { x: M + 8.55, y: 4.85, w: 0.8, h: 0.68, line: { color: C.gray, width: 2, endArrowType: "triangle" } });
  caja(M + 3.9, 5.55, 2.2, 0.8, "server2 local", C.gray);
  caja(M + 9.4, 5.55, 2.5, 0.8, "destino: valida firma y claims", C.mint, C.dark);
  s.addText("peso", { x: M + 4.9, y: 5.0, w: 0.9, h: 0.3, fontSize: 11, color: C.gray, fontFace: B, italic: true, align: "center", margin: 0 });
  s.addText("peso, con TLS", { x: M + 6.9, y: 5.22, w: 1.6, h: 0.3, fontSize: 11, color: C.gray, fontFace: B, italic: true, align: "right", margin: 0 });
  pie(s, "El Host interno viaja sin reescribir; el SNI hacia el destino lo fija el DestinationRule.");

  // 5 — resultados
  s = p.addSlide();
  s.background = { color: C.light };
  s.addText("Qué quedó demostrado", { x: M, y: 0.5, w: 11.9, h: 0.7, fontSize: 34, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText("Batería run-escenarios.sh, última corrida del 2026-08-05.", { x: M, y: 1.2, w: 11.9, h: 0.4, fontSize: 15, color: C.gray, fontFace: B, italic: true, margin: 0 });
  const filas = [
    ["E0", "Entorno", "el punto de partida es el que la PoC asume, incluido el assert anti-loop"],
    ["E1", "Camino local", "el tráfico atraviesa el Envoy, el Host no se reescribe, el token se emite con sus 5 claims"],
    ["E2", "Destino", "valida la firma contra el JWKS pineado; rechaza sin token, con firma alterada y con basura"],
    ["E3", "Canary", "el tráfico marcado va al destino y el destino lo autoriza; el resto ni se entera"],
    ["E4", "Pesos", "reparto 75/25 sobre un backendRef kind: Hostname → 71/29 medido, cero errores"],
  ];
  filas.forEach((f, i) => {
    const y = 1.85 + i * 0.83;
    tarjeta(s, M, y, 11.9, 0.72, C.white);
    s.addText(f[0], { x: M + 0.25, y, w: 0.7, h: 0.72, fontSize: 17, color: C.teal, fontFace: H, bold: true, valign: "middle", margin: 0 });
    s.addText(f[1], { x: M + 1.0, y, w: 2.0, h: 0.72, fontSize: 15, color: C.dark, fontFace: B, bold: true, valign: "middle", margin: 0 });
    s.addText(f[2], { x: M + 3.05, y, w: 8.0, h: 0.72, fontSize: 13.5, color: C.gray, fontFace: B, valign: "middle", margin: 0 });
    s.addText("OK", { x: M + 11.0, y, w: 0.65, h: 0.72, fontSize: 14, color: C.mint, fontFace: B, bold: true, align: "right", valign: "middle", margin: 0 });
  });
  pie(s, "37 chequeos. El único que falló resultó ser un defecto del propio test — ver hallazgo H13.");

  // 6 — números
  s = p.addSlide();
  encabezado(s, "Los números", "Latencia del salto interno, medida desde el bastión.");
  stat(s, M, 2.1, 3.5, "10,4 ms", "directo\nsin intercepción", C.gray);
  stat(s, M + 4.2, 2.1, 3.5, "12 ms", "con el Envoy\nde egreso en el medio", C.teal);
  stat(s, M + 8.4, 2.1, 3.5, "21 ms", "con Authorino\nfirmando cada request", C.deep);
  tarjeta(s, M, 4.5, 5.75, 2.3, C.white);
  s.addText("La ClusterIP nunca cambió", { x: M + 0.35, y: 4.75, w: 5.05, h: 0.4, fontSize: 18, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText("172.30.169.54 antes y después del cutover. Los pods de server2 nunca se detuvieron: la migración no tiene ventana.",
    { x: M + 0.35, y: 5.2, w: 5.05, h: 1.3, fontSize: 14, color: C.gray, fontFace: B, margin: 0, lineSpacing: 19 });
  tarjeta(s, M + 6.15, 4.5, 5.75, 2.3, C.white);
  s.addText("La señal que no miente", { x: M + 6.5, y: 4.75, w: 5.05, h: 0.4, fontSize: 18, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText("La IP de origen que ve el backend pasa de la del pod consumidor a la del gateway. Es la prueba directa de que la intercepción tomó efecto, sin instrumentar nada.",
    { x: M + 6.5, y: 5.2, w: 5.05, h: 1.4, fontSize: 14, color: C.gray, fontFace: B, margin: 0, lineSpacing: 19 });
  s.addNotes("El delta de latencia es sobre tráfico interno. Con el destino real hay que sumar RTT inter-cluster y handshake TLS.");

  // 7 — hallazgo principal
  s = p.addSlide();
  s.background = { color: C.dark };
  s.addText("HALLAZGO H9", { x: M, y: 0.7, w: 6, h: 0.35, fontSize: 13, color: C.amber, fontFace: B, bold: true, charSpacing: 2, margin: 0 });
  s.addText("Authorino no valida su propio wristband\ncon la configuración obvia", { x: M, y: 1.15, w: 11.9, h: 1.3, fontSize: 31, color: C.white, fontFace: H, bold: true, margin: 0, lineSpacing: 38 });
  tarjeta(s, M, 2.75, 5.75, 1.7, "2E3872");
  s.addText("El verificador acepta sólo RS256", { x: M + 0.3, y: 2.95, w: 5.15, h: 0.4, fontSize: 16, color: C.white, fontFace: H, bold: true, margin: 0 });
  s.addText("Con el diseño original en EC, el destino rechaza el 100 % de los tokens.", { x: M + 0.3, y: 3.4, w: 5.15, h: 0.85, fontSize: 14, color: "C6D4E8", fontFace: B, margin: 0, lineSpacing: 19 });
  tarjeta(s, M + 6.15, 2.75, 5.75, 1.7, "2E3872");
  s.addText("El firmador lee la clave sólo en PKCS#1", { x: M + 6.45, y: 2.95, w: 5.15, h: 0.4, fontSize: 16, color: C.white, fontFace: H, bold: true, margin: 0 });
  s.addText("Que es el formato que openssl no emite por default desde la versión 3.", { x: M + 6.45, y: 3.4, w: 5.15, h: 0.85, fontSize: 14, color: "C6D4E8", fontFace: B, margin: 0, lineSpacing: 19 });
  s.addShape("roundRect", { x: M, y: 4.75, w: 11.9, h: 1.05, rectRadius: 0.08, fill: { color: C.amber }, line: { color: C.amber, width: 0 } });
  s.addText("La única combinación que cierra el lazo firma y validación es RSA 2048 en PKCS#1.",
    { x: M + 0.35, y: 4.75, w: 11.2, h: 1.05, fontSize: 17, color: "2A1A05", fontFace: H, bold: true, valign: "middle", margin: 0 });
  s.addText("Aplica igual al destino real: EKS validando con Kuadrant habría fallado exactamente así, y el síntoma habría aparecido recién con los dos clusters montados y la red abierta. La Opción B del ADR es viable, pero no como está documentada hoy.",
    { x: M, y: 6.0, w: 11.9, h: 0.9, fontSize: 14, color: "BFD3E6", fontFace: B, margin: 0, lineSpacing: 19 });

  // 8 — otros hallazgos
  s = p.addSlide();
  encabezado(s, "Dos hallazgos más que cambian decisiones", null);
  tarjeta(s, M, 1.9, 11.9, 1.95, C.white);
  s.addShape("ellipse", { x: M + 0.35, y: 2.25, w: 0.55, h: 0.55, fill: { color: C.red }, line: { color: C.red, width: 0 } });
  s.addText("!", { x: M + 0.35, y: 2.25, w: 0.55, h: 0.55, fontSize: 20, color: C.white, fontFace: H, bold: true, align: "center", valign: "middle", margin: 0 });
  s.addText("La política de egreso es un punto único de falla del camino de la app", { x: M + 1.15, y: 2.15, w: 10.4, h: 0.45, fontSize: 19, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText("Una clave que Authorino no puede parsear deja su configuración sin reconciliar, la autorización externa falla cerrado y el consumidor deja de responder — aunque el destino no tenga nada que ver. Por eso el cutover va en dos pasos: primero el selector, después la política.",
    { x: M + 1.15, y: 2.65, w: 10.4, h: 1.1, fontSize: 14.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 20 });
  tarjeta(s, M, 4.05, 11.9, 1.75, C.white);
  s.addShape("ellipse", { x: M + 0.35, y: 4.4, w: 0.55, h: 0.55, fill: { color: C.teal }, line: { color: C.teal, width: 0 } });
  s.addText("i", { x: M + 0.35, y: 4.4, w: 0.55, h: 0.55, fontSize: 20, color: C.white, fontFace: H, bold: true, align: "center", valign: "middle", margin: 0 });
  s.addText("x-request-id no sirve para correlacionar entre clusters", { x: M + 1.15, y: 4.3, w: 10.4, h: 0.45, fontSize: 19, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText("El gateway de egreso lo regenera. Un log del origen y uno del destino no se van a poder unir por ese id. Se resuelve con traceparent o con un EnvoyFilter — y conviene decidirlo antes de que existan dos clusters.",
    { x: M + 1.15, y: 4.8, w: 10.4, h: 0.9, fontSize: 14.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 20 });
  s.addShape("roundRect", { x: M, y: 6.0, w: 11.9, h: 0.85, rectRadius: 0.08, fill: { color: C.dark }, line: { color: C.dark, width: 0 } });
  s.addText("Todos los problemas daban verde en algún lado. Ningún objeto en rojo, ningún error visible.",
    { x: M + 0.35, y: 6.0, w: 11.2, h: 0.85, fontSize: 15, color: C.white, fontFace: B, bold: true, valign: "middle", margin: 0 });

  // 9 — qué no se probó
  s = p.addSlide();
  encabezado(s, "Qué NO se probó", "Verde significa que la mecánica funciona. No significa nada de esto.");
  const nop = [
    ["Red real hacia el destino", "No hay camino a la VPC: el DNS resuelve y no hay proxy, pero el puerto 443 da timeout desde el pod y desde el bastión. Es un pedido a redes."],
    ["RTT y skew de reloj", "El token nace y muere bajo el mismo reloj. El modo de falla del vencimiento entre clusters queda intacto."],
    ["Capacidad", "Ninguna prueba de carga. El gateway pasa a estar en el camino crítico de la aplicación."],
    ["Clientes con pool de conexiones", "El cliente de prueba abre una conexión por request, así que el cutover se ve instantáneo. Un cliente real con pool persistente va a tener una cola que esto no muestra."],
  ];
  nop.forEach((n, i) => {
    const x = M + (i % 2) * 6.15, y = 2.0 + Math.floor(i / 2) * 2.25;
    tarjeta(s, x, y, 5.75, 2.0, C.white);
    s.addText(n[0], { x: x + 0.3, y: y + 0.22, w: 5.15, h: 0.45, fontSize: 17, color: C.dark, fontFace: H, bold: true, margin: 0 });
    s.addText(n[1], { x: x + 0.3, y: y + 0.72, w: 5.15, h: 1.1, fontSize: 13.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 19 });
  });
  pie(s, "El destino se validó con un stand-in local que conserva el FQDN real y sólo le fija los endpoints.");

  // 10 — qué falta
  s = p.addSlide();
  encabezado(s, "Qué falta para producción", "Por orden de peso.");
  const falta = [
    ["Identidad real del llamador", "Hoy el gateway autentica como anónimo y el control es la NetworkPolicy. Lo correcto es mTLS de la malla, con el principal en el token y el destino autorizando por él."],
    ["Multi-tenancy de la clave de firma", "Kuadrant obliga a que viva en un namespace de plataforma, no del equipo de la app. Limitación abierta: sin resolverla, el patrón no es multi-tenant."],
    ["Red hacia el destino", "Bloqueante para cualquier prueba real. Habilitar el puerto 443 desde la subred de workers, o fijar una IP de egreso."],
    ["Rotación de clave y observabilidad", "Un identificador de audiencia por destino, rotación sin ventana, y métricas por backend — que además son el criterio para avanzar de fase."],
  ];
  falta.forEach((f, i) => {
    const y = 1.95 + i * 1.22;
    s.addShape("ellipse", { x: M, y: y + 0.05, w: 0.55, h: 0.55, fill: { color: [C.red, C.amber, C.amber, C.teal][i] }, line: { width: 0, color: C.white } });
    s.addText(String(i + 1), { x: M, y: y + 0.05, w: 0.55, h: 0.55, fontSize: 18, color: C.white, fontFace: H, bold: true, align: "center", valign: "middle", margin: 0 });
    s.addText(f[0], { x: M + 0.85, y: y, w: 11.1, h: 0.4, fontSize: 18, color: C.dark, fontFace: H, bold: true, margin: 0 });
    s.addText(f[1], { x: M + 0.85, y: y + 0.42, w: 11.1, h: 0.7, fontSize: 14, color: C.gray, fontFace: B, margin: 0, lineSpacing: 19, valign: "top" });
  });

  // 11 — cierre
  s = p.addSlide();
  tituloOscuro(s, "PRÓXIMOS PASOS", "Lo que sigue",
    "1 · Pedido a redes para abrir el camino a la VPC\n2 · Enmendar el ADR con el hallazgo de algoritmos\n3 · Definir la correlación de trazas antes de tener dos clusters\n4 · Resolver la identidad del llamador y la clave multi-tenant");
  s.addText("Detalle: README.md · RESUMEN.md · HALLAZGOS.md", { x: M, y: 6.5, w: 8, h: 0.4, fontSize: 13, color: C.mint, fontFace: B, margin: 0 });

  return p.writeFile({ fileName: "poc-egreso-kuadrant-tecnica-2026-08.pptx" });
}

/* =====================================================================
   DECK GERENCIAL
   ===================================================================== */
function gerencial() {
  const p = new pptxgen();
  p.layout = "LAYOUT_WIDE";
  p.author = "Plataforma";
  p.title = "PoC egreso Kuadrant — gerencial";

  // 1 — portada
  let s = p.addSlide();
  tituloOscuro(s, "PRUEBA DE CONCEPTO · AGOSTO 2026",
    "Mover servicios entre clusters\nsin tocar las aplicaciones",
    "Resultado de la prueba de concepto, riesgos identificados\ny qué hace falta para llevarlo a producción.");
  s.addNotes("Duración sugerida: 10 minutos. El mensaje central es que la mecánica quedó demostrada y que el bloqueante es de red, no de diseño.");

  // 2 — el problema de negocio
  s = p.addSlide();
  encabezado(s, "El problema", null);
  tarjeta(s, M, 1.9, 5.75, 2.5, C.white);
  s.addText("Hoy", { x: M + 0.35, y: 2.15, w: 5.05, h: 0.4, fontSize: 20, color: C.red, fontFace: H, bold: true, margin: 0 });
  s.addText("Mover un servicio a otro cluster obliga a coordinar con cada aplicación que lo consume: cambio de configuración, despliegue y ventana de indisponibilidad.\n\nEso multiplica el costo de cada migración por la cantidad de consumidores.",
    { x: M + 0.35, y: 2.6, w: 5.05, h: 1.7, fontSize: 14.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 20 });
  tarjeta(s, M + 6.15, 1.9, 5.75, 2.5, C.white);
  s.addText("Con esta solución", { x: M + 6.5, y: 2.15, w: 5.05, h: 0.4, fontSize: 20, color: C.mint, fontFace: H, bold: true, margin: 0 });
  s.addText("El consumidor sigue llamando exactamente igual. La plataforma redirige el tráfico por debajo, de a poco, y puede volver atrás en segundos.\n\nLa migración deja de necesitar coordinación con las aplicaciones.",
    { x: M + 6.5, y: 2.6, w: 5.05, h: 1.7, fontSize: 14.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 20 });
  s.addShape("roundRect", { x: M, y: 4.75, w: 11.9, h: 1.55, rectRadius: 0.1, fill: { color: C.dark }, line: { color: C.dark, width: 0 } });
  s.addText("Y el tráfico entre clusters queda autenticado", { x: M + 0.4, y: 4.95, w: 11.1, h: 0.4, fontSize: 20, color: C.white, fontFace: H, bold: true, margin: 0 });
  s.addText("Cada llamada que sale hacia el otro cluster lleva una credencial de corta vida, firmada acá y verificada allá. Nadie que no pase por la plataforma puede consumir el servicio migrado.",
    { x: M + 0.4, y: 5.42, w: 11.1, h: 0.75, fontSize: 14.5, color: "BFD3E6", fontFace: B, margin: 0, lineSpacing: 20 });

  // 3 — qué quedó demostrado
  s = p.addSlide();
  s.background = { color: C.light };
  s.addText("Qué quedó demostrado", { x: M, y: 0.5, w: 11.9, h: 0.7, fontSize: 34, color: C.dark, fontFace: H, bold: true, margin: 0 });
  s.addText("Prueba ejecutada de punta a punta en el cluster de laboratorio.", { x: M, y: 1.2, w: 11.9, h: 0.4, fontSize: 15, color: C.gray, fontFace: B, italic: true, margin: 0 });
  stat(s, M, 1.95, 3.7, "37 / 37", "verificaciones\nautomatizadas en verde", C.mint);
  stat(s, M + 4.1, 1.95, 3.7, "0 seg", "de indisponibilidad\nen el cambio y en la vuelta atrás", C.deep);
  stat(s, M + 8.2, 1.95, 3.7, "+11 ms", "de latencia agregada\nsobre tráfico interno", C.teal);
  const dem = [
    "El consumidor no se modificó: mismo nombre, misma dirección, mismo puerto.",
    "El tráfico se puede repartir de a poco entre el servicio viejo y el nuevo, y volver atrás en cualquier momento.",
    "El destino verifica la credencial y rechaza todo lo que no venga firmado por la plataforma.",
  ];
  dem.forEach((d, i) => {
    const y = 4.15 + i * 0.85;
    tarjeta(s, M, y, 11.9, 0.72, C.white);
    s.addShape("ellipse", { x: M + 0.3, y: y + 0.16, w: 0.4, h: 0.4, fill: { color: C.mint }, line: { width: 0, color: C.mint } });
    s.addText(d, { x: M + 0.95, y, w: 10.7, h: 0.72, fontSize: 14.5, color: C.dark, fontFace: B, valign: "middle", margin: 0 });
  });

  // 4 — riesgos
  s = p.addSlide();
  encabezado(s, "Riesgos identificados", "Ninguno bloquea el diseño; todos tienen dueño y camino de resolución.");
  const riesgos = [
    ["ALTO", "El producto no valida su propia credencial con la configuración recomendada", "Se resolvió cambiando el algoritmo de firma. Obliga a enmendar la decisión de arquitectura ya aprobada, porque el mismo problema aparecería en el cluster destino.", C.red],
    ["ALTO", "La política de seguridad es un punto único de falla", "Un error de configuración en ella deja sin servicio a la aplicación, aunque el destino esté sano. Se mitiga separando el cambio en dos pasos independientes.", C.red],
    ["MEDIO", "No se puede seguir una transacción entre los dos clusters", "El identificador de request se regenera en el salto. Hay que definir el mecanismo de trazas antes de tener el segundo cluster en producción.", C.amber],
    ["MEDIO", "La clave de firma la custodia la plataforma, no el equipo dueño de la aplicación", "Limitación del producto. Sin resolverla, el patrón sirve para un consumidor puntual pero no se puede ofrecer como servicio a varios equipos.", C.amber],
  ];
  riesgos.forEach((r, i) => {
    const y = 1.95 + i * 1.2;
    s.addShape("roundRect", { x: M, y: y + 0.08, w: 0.95, h: 0.42, rectRadius: 0.06, fill: { color: r[3] }, line: { width: 0, color: r[3] } });
    s.addText(r[0], { x: M, y: y + 0.08, w: 0.95, h: 0.42, fontSize: 11, color: C.white, fontFace: B, bold: true, align: "center", valign: "middle", margin: 0 });
    s.addText(r[1], { x: M + 1.2, y: y, w: 10.7, h: 0.42, fontSize: 16.5, color: C.dark, fontFace: H, bold: true, margin: 0 });
    s.addText(r[2], { x: M + 1.2, y: y + 0.45, w: 10.7, h: 0.7, fontSize: 13.5, color: C.gray, fontFace: B, margin: 0, lineSpacing: 18, valign: "top" });
  });

  // 5 — bloqueante
  s = p.addSlide();
  s.background = { color: C.dark };
  s.addText("EL ÚNICO BLOQUEANTE", { x: M, y: 1.35, w: 8, h: 0.4, fontSize: 13, color: C.amber, fontFace: B, bold: true, charSpacing: 2, margin: 0 });
  s.addText("No hay camino de red\nhacia el cluster destino", { x: M, y: 1.8, w: 11.9, h: 1.5, fontSize: 38, color: C.white, fontFace: H, bold: true, margin: 0, lineSpacing: 44 });
  s.addText("El nombre resuelve y no hay proxy en el medio, pero las conexiones al cluster de AWS no llegan — ni desde los servidores ni desde el bastión. Es un pedido de habilitación a la red corporativa, no un problema de la plataforma.",
    { x: M, y: 3.55, w: 11.0, h: 1.0, fontSize: 16, color: "BFD3E6", fontFace: B, margin: 0, lineSpacing: 23 });
  tarjeta(s, M, 4.85, 11.9, 1.5, "2E3872");
  s.addText("Mientras tanto, la prueba se completó contra un destino simulado dentro del mismo cluster.", { x: M + 0.35, y: 5.05, w: 11.2, h: 0.4, fontSize: 16, color: C.white, fontFace: H, bold: true, margin: 0 });
  s.addText("Eso permitió validar todo salvo la latencia entre clusters y la diferencia de reloj entre ellos. Ambas quedan pendientes de la habilitación de red.",
    { x: M + 0.35, y: 5.5, w: 11.2, h: 0.7, fontSize: 14, color: "BFD3E6", fontFace: B, margin: 0, lineSpacing: 19 });

  // 6 — recomendación
  s = p.addSlide();
  encabezado(s, "Recomendación", null);
  const rec = [
    ["Continuar", "El diseño se sostiene: la mecánica está probada y los problemas encontrados tienen solución conocida.", C.mint],
    ["Pedir la habilitación de red", "Es el único bloqueante para completar la prueba con el cluster real. Sin eso no se puede medir latencia ni programar la migración.", C.deep],
    ["Enmendar la decisión de arquitectura", "El hallazgo sobre el algoritmo de firma afecta a la opción ya aprobada. Corregirlo ahora evita descubrirlo con los dos clusters montados.", C.amber],
    ["No ofrecerlo como servicio todavía", "Falta resolver la identidad del consumidor y el aislamiento de la clave entre equipos. Para un primer caso puntual, sirve como está.", C.red],
  ];
  rec.forEach((r, i) => {
    const y = 1.9 + i * 1.25;
    tarjeta(s, M, y, 11.9, 1.05, C.white);
    s.addShape("ellipse", { x: M + 0.3, y: y + 0.28, w: 0.5, h: 0.5, fill: { color: r[2] }, line: { width: 0, color: r[2] } });
    s.addText(String(i + 1), { x: M + 0.3, y: y + 0.28, w: 0.5, h: 0.5, fontSize: 16, color: C.white, fontFace: H, bold: true, align: "center", valign: "middle", margin: 0 });
    s.addText(r[0], { x: M + 1.0, y: y, w: 3.4, h: 1.05, fontSize: 18, color: C.dark, fontFace: H, bold: true, valign: "middle", margin: 0 });
    s.addText(r[1], { x: M + 4.5, y: y + 0.1, w: 7.1, h: 0.85, fontSize: 13.5, color: C.gray, fontFace: B, valign: "middle", margin: 0, lineSpacing: 18 });
  });

  return p.writeFile({ fileName: "poc-egreso-kuadrant-gerencial-2026-08.pptx" });
}

tecnico().then(f => { console.log("OK", f); return gerencial(); }).then(f => console.log("OK", f));
