# E1

## ADR1: Topología del consumo y resiliencia al broker

### Contexto

El sistema debe consumir mensajes desde RabbitMQ (broker de la central) y responderle a la central con un mensaje `ack` o `nack` por cada uno. Se exige que la caída del broker no bote la API del sistema, que exista reconexión automática ante cortes, y que no se pierdan mensajes ya recibidos.

### Alternativas consideradas

1. **Monolito en un solo proceso Ruby:** Un solo servidor (ej. Rails/Sinatra) que expone la API HTTP y a la vez levanta un hilo interno para mantener la conexión a RabbitMQ.
2. **Event-Driven Architecture (Worker Desacoplado):** Separar el backend en dos procesos/contenedores distintos: una API web (`master`) para responder consultas al frontend y un script "Worker" en Ruby (contenedor `connector`, usando la gema Bunny) dedicado exclusivamente a hablar con el broker: consume los mensajes, los valida, le responde a la central y entrega los válidos a la API mediante HTTP POST.

### Decisión

Se opta por la Alternativa 2 (Worker Desacoplado) bajo el estilo de Arquitectura Orientada a Eventos (EDA) con topología de Broker.

### Justificación (Mecanismos de resiliencia)

- **Protección de la API (Desacoplamiento):** Al tener el consumidor como un contenedor Docker independiente, si la conexión con RabbitMQ falla, solo se ve afectado el Worker. La API permanece intacta y sigue respondiendo a las peticiones del frontend leyendo desde la base de datos.
- **Reconexión Automática (Self-healing):** El código del Worker utiliza bloques `begin/rescue` para atrapar errores de red de la gema Bunny: ante un corte, espera unos segundos y vuelve a conectarse sin terminar el proceso. Ante un error irrecuperable, el script ejecuta un `exit(1)`. Esto delega la responsabilidad a Docker, que mediante la política `restart: always` revive el contenedor en segundos, forzando una conexión limpia.
- **Cero pérdida de mensajes (Idempotencia y ACKs):** El Worker opera con confirmación manual ante el broker (manual ACK de AMQP). Solo confirma un mensaje después de que la API respondió que lo guardó, y recién ahí publica también el mensaje `ack` hacia la central. Si el Worker muere a mitad del procesamiento, RabbitMQ no recibe la confirmación y entrega el mensaje nuevamente cuando el Worker revive. Esa reentrega puede repetir un mensaje, por lo que la API lo identifica por su `idpk` y no lo aplica dos veces (ver ADR2).
- **Mensajes inválidos:** Un mensaje que no se puede parsear o que no trae `msgId` se registra y se descarta; uno malformado se responde con `nack`. En ambos casos se confirma ante el broker, para que no vuelva a la cola indefinidamente ni bloquee los mensajes siguientes.

### Consecuencias

- **Positivas:** Alta resiliencia ante fallos externos, escalabilidad independiente, y cumplimiento estricto del aislamiento requerido.
- **Negativas:** Mayor complejidad operativa al desplegar múltiples contenedores (API + Worker + DB) en EC2 mediante Docker Compose. Además, un mismo mensaje puede llegar más de una vez a la API, por lo que el sistema depende de la idempotencia por `idpk` (ADR2).


## ADR2: Persistencia del Ledger y modelo de datos

### Contexto
Se debe almacenar el estado financiero y energético de la ciudad de forma segura. El estado del ledger de cualquier ciclo pasado debe ser auditable, reconstruible, explicable y que los mensajes duplicados no alteren los saldos dos veces.

### Alternativas consideradas
1. **Modelo de Snapshot:** Mantener una tabla con el saldo actual y sobreescribir valores de energia y saldo acorde vayan llegando.
2. **Modelo Event logs:** Almacenar un registro de cada transacción individual usando una base de datos relacional (PostgreSQL) y no sobreescribir nada.

### Decisión
Se opta por la opción 2, Event Logs en base de datos relacional.

### Justificación
1. **Construcción de datos:** : Al guardar las transacciones como eventos inmutables, el balance final de un ciclo no es un número sobrescrito, sino el resultado de sumar matemáticamente todas las entradas y salidas de ese ciclo. Esto cumple la propiedad exigida de poder explicar con exactitud cómo se llegó a cualquier estado pasado.
2. **Control estricto con ID:** Las bases de datos SQL permiten establecer la columna idpk con una restricción de unicidad (UNIQUE CONSTRAINT). Si el broker reenvía un mensaje (reintento) o hay un problema de concurrencia, la base de datos rechazará automáticamente la el idpk duplicado, evitando el doble gasto y sirviendo de base para la tabla de auditoría y control.

### Consecuencias

* **Positivas:** Trazabilidad absoluta, protección nativa contra transacciones duplicadas a nivel de motor de datos, y cumplimiento estricto de corrección de arquitectura.
* **Negativas:** Mayor complejidad en las consultas de lectura, ya que el backend deberá ejecutar operaciones matemáticas cada vez que necesite conocer el balance actual para validar si existe capacidad de venta.


## ADR3: Manejo de timeouts de negociación

### Contexto
Las propuestas voluntarias (negotiation-proposal) exigen recibir confirmación y transferencia en menos de 30 segundos. Tras este plazo, el sistema debe reintentar con el mismo idpk asegurando que una respuesta tardía no impacte el ledger dos veces.

### Alternativas consideradas
1. **Espera síncrona (sleep 30):** Bloquear el proceso emisor 30 segundos y reintentar si no hay respuesta.
2. **Scheduler asíncrono con máquina de estados en BD:** Registrar ofertas en estado PENDING y usar un worker asíncrono para reintentar con el mismo idpk las vencidas.

### Decisión
Se opta por la Alternativa 2 (Scheduler asíncrono con máquina de estados).

### Justificación
1. **Sin bloqueos:** Mantiene libre a la API y al consumidor de eventos sin congelar hilos de ejecución.
2. **Garantía de idempotencia:** La restricción UNIQUE sobre idpk en la base de datos (ADR2) descarta cobros o abonos duplicados si la respuesta llega desfasada.
3. **Resiliencia ante reinicios:** Si el servicio cae durante la espera, la BD preserva el estado para reanudar reintentos al revivir el contenedor.

### Consecuencias
* **Positivas:** Evita el doble gasto en el ledger, maximiza el rendimiento asíncrono y tolera caídas.
* **Negativas:** Añade la complejidad de gestionar tareas programadas (schedulers) en segundo plano.
