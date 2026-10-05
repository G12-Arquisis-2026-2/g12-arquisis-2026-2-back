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
