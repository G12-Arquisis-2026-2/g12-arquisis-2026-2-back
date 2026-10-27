# 1. Especificación de la Entrega (Spec)
Entrega: martes 3 de noviembre de 2026.

Objetivo General: Evolucionar el nodo de Tokyo-3 (TK3) desde la negociación con la Central hacia un mercado entre ciudades (protocolo v3). El nodo publica ofertas, compra y vende energía directamente con otras ciudades mediante swaps custodiados por la wallet de la Central, y opera de forma autónoma ciclo a ciclo, tolerando una wallet lenta que a veces falla. La interfaz gráfica permite observar el mercado, administrar la estrategia sin redeploy y auditar cada ciclo.

Qué cambia respecto de la E1:
- La wallet (REST) pasa a ser la fuente de verdad de créditos (CR) y energía (KWH). El Ledger local deja de tener autoridad y pasa a ser apoyo a la decisión, reconciliado contra GET /balance.
- Se retiran negotiation-proposal, give, take, el transfer de pago y demand-statement (la Central responde TYPE_RETIRED).
- Se agregan los mensajes offer, offer-updated, offer-withdrawn, bid, bid-accepted, bid-rejected, los eventos de la wallet (swap-*), trade-recorded, imbalance-settlement y market-closed.
- El nodo consume dos colas: city.TK3.q (mensajes dirigidos: Central, otras ciudades y eventos de la wallet) y market.TK3 (feed público del mercado).
- Las reglas de recepción de la E1 (envelope, user_id, ACK/NACK) aplican también a los mensajes de otras ciudades.
- El ciclo dura 20 minutos: 10 de mercado y 5 de cierre para el negotiation-report.

Arquitectura de Componentes: Se mantiene la arquitectura de la E1 en contenedores, con un consumidor nuevo y dos módulos nuevos en el backend:

Connector city (RabbitMQ): Script en Ruby (Bunny) que consume city.TK3.q con passive: true. Ahora también recibe bids y respuestas de otras ciudades, y los eventos de la wallet. Valida envelope y user_id contra cityId (NACK IDENTITY_MISMATCH si no corresponde) y reenvía al backend vía HTTP POST.
Connector market (nuevo): Consumidor de market.TK3 (exchange topic market). Mantiene el libro de ofertas vigente y detecta market-closed. Publica las ofertas propias solo con routing key market.offer.TK3. Los mensajes del feed no se responden con ACK.
Backend (Ruby on Rails): API RESTful que centraliza la lógica de negocio.
- Cliente de la wallet: Escrituras (POST /swaps, accept, cancel) con Idempotency-Key persistida antes de enviar y reutilizada en cada reintento ante 502, 503, 504, 429 y timeouts. Verificación del swapToken (JWT ES256) contra el JWKS antes de aceptar.

- Ledger: Aplica cada evento de la wallet una sola vez y en cualquier orden, apareado por data.idpk. Al cierre de cada ciclo reconcilia contra GET /balance y registra el delta.

- Auditoría: La tabla audit_logs se extiende a duplicados, descartes y NACK de mensajes de otras ciudades.

- Gestión de Ciclos: La tabla cycles guarda el status-statement extendido (sellable, buybackPrice, imbalancePrice, minBid e instantes del mercado), el imbalance-settlement y el negotiation-report.
Estrategia (Jobs): Workers que ejecutan la política de mercado leída desde configuración en base de datos. Como vendedor: publica y mantiene la oferta, acepta bids en serie por oferta y traduce rechazos de la wallet a bid-rejected. Como comprador: calcula el precio efectivo (precio más transporte según la distance-table vigente), envía bids, verifica el token y acepta swaps. Registra por ciclo la estrategia y el span usados (experimento RF06).
Frontend: Aplicación React con build estático en S3 + CloudFront. Vistas de historial de ciclos (RF01), mercado en vivo (RF02), administración del mercado (RF04), auditoría (RF05) y experimento de span (RF06).

Reglas que no se negocian:
- La Idempotency-Key se guarda antes de la primera llamada y se reutiliza en cada reintento. Una llave nueva es una operación nueva.
- Los eventos de la wallet son la verdad, no el código HTTP.
- Nunca se aceptan dos bids contra la misma cantidad.
- Los instantes del ciclo vienen del status-statement, no del reloj del servidor.
- Ningún secreto (.env, .pem, API key de la wallet) entra al repositorio.
- El commit de cada ADR (AD4, AD5, AD6) precede a los commits que lo implementan.

2. Plan de Milestones (Hoja de Ruta)
Para organizar el desarrollo de la Entrega 2, el equipo dividió el trabajo en 5 hitos. Cada hito termina en una condición de salida que el grupo revisa antes de avanzar.

Milestone 1: Fundaciones
Objetivo: Dejar escritas las decisiones de arquitectura y cerrar el primer swap dentro del periodo de puntaje.
Condición de salida: ADRs de AD4, AD5 y AD6 en el repositorio y al menos un swap liquidado (G04).

Tareas:
- ADRs de AD4, AD5 y AD6, commiteados antes de su implementación.

- Consumidor de market.TK3 y publicación de ofertas.

- Envío y recepción de bids entre ciudades.

- Cliente HTTP de la wallet con Idempotency-Key y reintentos.

- Primer swap contra MET.

- Spec y milestones, API key de la wallet como secreto en el servidor, worker nuevo en docker-compose y revisión de budget alerts.

- Ambiente local en Ubuntu con RabbitMQ propio, para no consumir de la cola de producción.

Milestone 2: Arreglos de la entrega anterior y ciclo de Mercado Autónomo
Objetivo: Que el nodo venda y compre solo, sin intervención manual.
Condición de salida: Tres ciclos seguidos operando de forma autónoma.

Tareas:
- Arreglar aspectos pendientes de la E1.

- Validación de user_id en mensajes de otras ciudades y manejo de bids duplicados por idpk.

- Aplicación idempotente de eventos de la wallet y verificación del swapToken.

- Reconciliación con GET /balance al cierre de cada ciclo.

- Rol vendedor con aceptación serializada por oferta (AD4).

- Rol comprador por precio efectivo con transporte.

- Estrategia como configuración, aplicada en el ciclo siguiente sin redeploy (AD6).

- Vistas de mercado en vivo (RF02) y administración (RF04).

- Rutas nuevas en API Gateway con authorizer y CORS, e instrumentación en New Relic del feed y de la wallet.

Milestone 3: Robustez y Anomalías
Objetivo: Preparar el sistema para las anomalías inducidas de la demo.
Condición de salida: Las 7 anomalías de la lista probadas al menos una vez.

Tareas:
- Reconexión automática al broker (anomalía 5).

- Duplicados de bids y de swap-settled (anomalía 1) y mensajes con user_id ajeno o malformados (anomalía 2).

- Timeouts de escrituras ya procesadas (anomalía 4) y cancelación de retenciones colgadas.

- Contrapartes que no cumplen (anomalía 3) y rutas deshabilitadas a mitad de mercado (anomalía 6).

- Experimento de span con al menos 3 valores en ciclos distintos.

- Historial de ciclos (RF01) y vistas de auditoría (RF05) y experimento (RF06).

- Dashboard de APM e infraestructura para la anomalía 7, con medición de la latencia de la wallet.

Milestone 4: Documentación y Ensayo
Objetivo: Completar la documentación evaluada y ensayar la demo.
Condición de salida: Todos los documentos en /docs y un ensayo completo de demo.

Tareas:
- Post-mortems de AD1, AD2 y AD3.

- Contract tests en CI contra los schemas v3.0.1 del curso, y OpenAPI actualizado.

- Informe del experimento de span (RDOC05).

- Diagrama UML de componentes, pasos de monitoreo y README de ejecución local (RDOC03).

- AI logs de todos los integrantes.

- Ensayo de demo con anomalías elegidas al azar.

Milestone 5: Entrega
Objetivo: Entregar con todos los requisitos esenciales verificados.

Tareas:
- Congelamiento del código.

- Verificación de que el dashboard coincide con GET /balance.

- Build final del frontend en S3 con la URL de producción de la API.

- Verificación uno por uno de los gates G01 a G09 y deploy final.

3. Roles
Víctor Castillo, Mensajería RabbitMQ y Mensajes entre Ciudades: Extiende el connector para consumir las dos colas (city.TK3.q y market.TK3) y publicar en el exchange market con su routing key propia. Responsable de validar user_id en mensajes de otras ciudades, del manejo de duplicados y NACK de pares, del límite de 60 operaciones de mercado por minuto y de la reconexión automática al broker. Implementa los contract tests en CI. Documenta el post-mortem de AD1.

Maximiliano Weldt, Wallet, Ledger y Consistencia: Implementa el cliente de la wallet con Idempotency-Key y reintentos, la aplicación idempotente de los eventos swap-* en cualquier orden y la verificación del swapToken contra el JWKS. Reconcilia el Ledger con GET /balance al cierre de cada ciclo. Documenta el ADR de AD5 y el post-mortem de AD2.

Thomas Herrmann, Estrategia de Mercado: Implementa los roles de vendedor y comprador, la aceptación de bids serializada por oferta y la estrategia como configuración. Corre el experimento de span y escribe su informe. Documenta los ADRs de AD4 y AD6 y el post-mortem de AD3.

Camila Gómez, Frontend y Endpoints de Consulta: Construye las vistas de historial de ciclos (RF01), mercado en vivo (RF02), administración del mercado (RF04), auditoría (RF05) y experimento de span (RF06). Coordina con el backend los endpoints necesarios y actualiza el OpenAPI en el repositorio de contratos.

Sofía Guerrero, Infraestructura, Autenticación y Monitoreo: Mantiene el despliegue en AWS (EC2 + ECR, S3 + CloudFront, API Gateway con Auth0) e incorpora el consumidor de mercado al docker-compose de producción. Gestiona la API key de la wallet como secreto, revisa las budget alerts e instrumenta en New Relic el feed de mercado y las llamadas a la wallet. Configuró el ambiente local con RabbitMQ propio. Escribe la spec y los milestones, el diagrama UML, los pasos de monitoreo y el README local, y coordina los AI logs y el ensayo de la demo. Apoya el flujo comprador si la estrategia se atrasa.
