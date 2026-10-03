# E1

## ADR1: Topología del consumo y resiliencia al broker

### Contexto
El sistema debe consumir mensajes desde RabbitMQ (broker de la central). Se exige que la caída del broker no bote la API del sistema, que exista reconexión automática ante cortes, y que no se pierdan mensajes en tránsito.

### Alternativas consideradas
1. **Monolito en un solo proceso Ruby:** Un solo servidor (ej. Rails/Sinatra) que expone la API HTTP y a la vez levanta un hilo interno para mantener la conexión a RabbitMQ.
2. **Event-Driven Architecture (Worker Desacoplado):** Separar el backend en dos procesos/contenedores distintos: una API web para responder consultas al frontend y un script "Worker" en Ruby (usando la gema Bunny) dedicado exclusivamente a escuchar eventos del broker.

### Decisión
Se opta por la Alternativa 2 (Worker Desacoplado) bajo el estilo de Arquitectura Orientada a Eventos (EDA) con topología de Broker.

### Justificación (Mecanismos de resiliencia)
* **Protección de la API (Desacoplamiento):** Al tener el consumidor como un contenedor Docker independiente, si la conexión TCP con RabbitMQ falla y el proceso de Ruby arroja una excepción fatal, solo se cae el Worker. La API permanece intacta y sigue respondiendo a las peticiones del frontend leyendo desde la base de datos compartida.
* **Reconexión Automática (Self-healing):** El código del Worker en Ruby utilizará bloques `begin/rescue` para atrapar errores de red de la gema Bunny. Ante un error irrecuperable de conexión, el script ejecutará un `exit(1)`. Esto delega la responsabilidad a Docker, que mediante la política `restart: always` revivirá el contenedor en segundos, forzando una conexión limpia.
* **Cero pérdida de mensajes (Idempotencia y ACKs):** El Worker operará con confirmación manual (manual ACK). Solo se enviará el ACK a RabbitMQ después de que el mensaje haya sido procesado, validado y guardado exitosamente. Si el Worker muere a mitad del procesamiento, RabbitMQ no recibirá el ACK y encolará el mensaje nuevamente para cuando el Worker reviva.

### Consecuencias
* **Positivas:** Alta resiliencia ante fallos externos, escalabilidad independiente, y cumplimiento estricto del aislamiento requerido.
* **Negativas:** Mayor complejidad operativa al desplegar múltiples contenedores (API + Worker + DB) en EC2 mediante Docker Compose.


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


