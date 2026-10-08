# ADR1: Topología del consumo y resiliencia al broker

## Contexto

El sistema debe consumir mensajes desde RabbitMQ (broker de la central) y responderle a la central con un mensaje `ack` o `nack` por cada uno. Se exige que la caída del broker no bote la API del sistema, que exista reconexión automática ante cortes, y que no se pierdan mensajes ya recibidos.

## Alternativas consideradas

1. **Monolito en un solo proceso Ruby:** Un solo servidor (ej. Rails/Sinatra) que expone la API HTTP y a la vez levanta un hilo interno para mantener la conexión a RabbitMQ.
2. **Event-Driven Architecture (Worker Desacoplado):** Separar el backend en dos procesos/contenedores distintos: una API web (`master`) para responder consultas al frontend y un script "Worker" en Ruby (contenedor `connector`, usando la gema Bunny) dedicado exclusivamente a hablar con el broker: consume los mensajes, los valida, le responde a la central y entrega los válidos a la API mediante HTTP POST.

## Decisión

Se opta por la Alternativa 2 (Worker Desacoplado) bajo el estilo de Arquitectura Orientada a Eventos (EDA) con topología de Broker.

## Justificación (Mecanismos de resiliencia)

- **Protección de la API (Desacoplamiento):** Al tener el consumidor como un contenedor Docker independiente, si la conexión con RabbitMQ falla, solo se ve afectado el Worker. La API permanece intacta y sigue respondiendo a las peticiones del frontend leyendo desde la base de datos.
- **Reconexión Automática (Self-healing):** El código del Worker utiliza bloques `begin/rescue` para atrapar errores de red de la gema Bunny: ante un corte, espera unos segundos y vuelve a conectarse sin terminar el proceso. Ante un error irrecuperable, el script ejecuta un `exit(1)`. Esto delega la responsabilidad a Docker, que mediante la política `restart: always` revive el contenedor en segundos, forzando una conexión limpia.
- **Cero pérdida de mensajes (Idempotencia y ACKs):** El Worker opera con confirmación manual ante el broker (manual ACK de AMQP). Solo confirma un mensaje después de que la API respondió que lo guardó, y recién ahí publica también el mensaje `ack` hacia la central. Si el Worker muere a mitad del procesamiento, RabbitMQ no recibe la confirmación y entrega el mensaje nuevamente cuando el Worker revive. Esa reentrega puede repetir un mensaje, por lo que la API lo identifica por su `idpk` y no lo aplica dos veces (ver ADR2).
- **Mensajes inválidos:** Un mensaje que no se puede parsear o que no trae `msgId` se registra y se descarta; uno malformado se responde con `nack`. En ambos casos se confirma ante el broker, para que no vuelva a la cola indefinidamente ni bloquee los mensajes siguientes.

## Consecuencias

- **Positivas:** Alta resiliencia ante fallos externos, escalabilidad independiente, y cumplimiento estricto del aislamiento requerido.
- **Negativas:** Mayor complejidad operativa al desplegar múltiples contenedores (API + Worker + DB) en EC2 mediante Docker Compose. Además, un mismo mensaje puede llegar más de una vez a la API, por lo que el sistema depende de la idempotencia por `idpk` (ADR2).

## Análisis Postmortem

### Modificaciones y Adaptaciones durante Implementación
1. **Reconexión con la recuperación automática de Bunny:** El ADR describía bloques begin/rescue propios. En la práctica eso quedó solo para la conexión inicial (reintento cada 5 s). Tras un corte, reconecta y vuelve a suscribirse la recuperación automática de la gema, con heartbeat de 10 s para detectar cortes silenciosos.
2. **Vigilancia y exit(1):** Se agregó una revisión cada 5 s. Si el canal queda cerrado o pasan más de 120 s sin conexión, el proceso termina y Docker lo levanta. La política usada es `restart: unless-stopped`, no `always` como decía el ADR.
3. **El connector también publica (outbox):** El ADR lo describía solo como consumidor. Para que la API nunca abra una conexión al broker, los mensajes propios (negotiation-report, propuestas, transfer) se guardan en la tabla outbox_messages y el connector los publica con la propiedad user_id.
4. **Reintentos con tope:** El diseño original reintentaba sin límite. Se acotó para que un mensaje no bloquee la cola: si la API responde un error 5xx para ese mensaje, tras 4 intentos se registra y se saca de la cola. Si la API está caída (sin respuesta, 502, 503 o 504) o falla la publicación del ack, se espera sin límite y no cuenta como intento.
5. **Validación en dos niveles:** El connector valida el envelope y el contenido básico; la API puede además rechazar con 422, y el connector lo traduce en un nack.
6. **Interruptor ENABLE_PUBLISHER:** Se agregó para poder desplegar sin publicar hacia la central. Apagado, tampoco salen los ack ni los nack, por lo que en producción debe estar en true.
7. **Verificación del certificado:** Bunny no verifica el certificado del broker cuando recibe una URL, así que se dejó verify_peer: true explícito.

### Evaluación de Resultados
1. **La caída del broker no bota la API:** [Exitoso / Parcial]. [Completar con lo observado en la prueba de corte: la API siguió respondiendo y el connector reconectó en X segundos.]
2. **Reconexión automática:** [Exitoso / Parcial]. [Completar: se vio en los logs "Se perdió la conexión" y "Conexión recuperada", sin intervención manual.]
3. **No se pierden mensajes ya recibidos:** Parcial. Se cumple ante caídas del connector, del broker y de la API, porque el mensaje solo se confirma al broker después de guardado. No se cumple en un caso: si la API responde 500 de forma repetida para un mensaje, se descarta tras 4 intentos. Fue una decisión consciente para no bloquear la cola. [Confirmar si la base de datos caída ya responde 503; si no, ese caso también termina en descarte.]
4. **Mensajes inválidos sin caída del servicio:** [Exitoso / Parcial]. [Completar con la prueba de mensaje malformado y sin msgId: nack o descarte, registro en auditoría, connector sano.]

### Qué haríamos distinto
- Definir desde el inicio el contrato entre el connector y la API (códigos de respuesta), que fue la fuente de la mayoría de los ajustes.
- Guardar la cuenta de reintentos fuera de la memoria del proceso: hoy se pierde si el connector se reinicia.
- Enviar a una cola aparte los mensajes que se descartan por reintentos, en vez de eliminarlos.