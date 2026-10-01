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