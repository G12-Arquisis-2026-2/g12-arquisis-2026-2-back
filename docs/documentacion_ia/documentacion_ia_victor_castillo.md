# Declaración de uso de IA — Víctor Castillo
> - **Modelo:**
Claude Opus 5.5 (chat) y Claude Code (terminal)
> - **Plataforma:**
Claude (app de chat): conversación de planificación y revisión. 
Claude Code (terminal): programación agéntica sobre el repo del backend.

> - **Cómo se usó:**
Usé el chat de Claude como tutor: para entender el enunciado y el material del curso, decidir el orden de trabajo. También revisó y me ayudo a entender los informes que devolvía Claude Code y me ayudó a redactar parte del adr1, commits y descripciones de PR.

Claude Code escribió me ayudo a escribir código de mi parte: el connector (validación, ack/nack, reintentos, reconexión), el publicador con outbox y especialmente los tests para comprobar que todo funcionara. También lo usé para revisar código (prompts de solo lectura), para probar el connector en local contra un RabbitMQ de prueba y para realizar par de fixes al final de la entrega.

Yo decidí qué se hacía en cada paso, corrí los prompts, revisé los informes y los diffs antes de cada commit, y abrí los PR. Los cambios pasaron por revisión de compañeros.

> - **Archivos/partes afectadas:**
/connector
app/services/rabbit_m_q_publisher.rb, app/models/outbox_message.rb, app/controllers/outbox_controller.rb, db/migrate/20261007000001_create_outbox_messages.rb