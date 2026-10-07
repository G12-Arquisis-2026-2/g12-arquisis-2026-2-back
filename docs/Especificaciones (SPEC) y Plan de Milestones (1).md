## 1. Especificación de la Entrega (Spec)

Objetivo General: Implementar el nodo inteligente para la ciudad Tokyo-3, capaz de comunicarse de forma asíncrona con el servidor Central, procesar eventos financieros mediante un Ledger, orquestar ciclos de negociación de energía, y exponer una interfaz gráfica para la visualización del estado del sistema.

Arquitectura de Componentes: El sistema opera bajo una arquitectura orientada a servicios (SOA) en contenedores, dividida en 4:

- 1. Connector (RabbitMQ): Script independiente en Ruby (Bunny) que mantiene conexión TLS/AMQPS con el broker. Valida el protocolo v2 y reenvía los payloads limpios vía HTTP POST al backend, retornando ACKs o NACKs a la Central según la respuesta HTTP.

- 2. Backend (Ruby on Rails): API RESTful que centraliza la lógica de negocio y exposición de datos.

- \- Ledger Inmutable: Basado en el patrón Event Log (PostgreSQL). Las transacciones de energía y presupuesto se insertan como registros inmutables, calculando el balance final mediante agregación (SUM) y evadiendo cuellos de botella por concurrencia.

- \- Auditoría: Tabla audit_logs que registra mensajes descartados, NACKs y bloqueos por duplicidad de idpk.

- \- Gestión de Ciclos: Tabla cycles para almacenar los status-statement y el estado final reportado.

- 3. Orquestador (Jobs): Workers asíncronos que manejan la lógica de negociación, propuestas y timeouts de 30s interactuando con los balances del Ledger para evitar sobrepasar la capacidad de generación máxima.

- 4. Frontend: Aplicación cliente (React/Vue) conectada al Backend vía HTTP GET para renderizar el historial de auditoría, las distancias y los balances del ciclo.

## 2. Plan de Milestones (Hoja de Ruta)

Para organizar el desarrollo de la Entrega 1, el equipo dividió el trabajo en 4 hitos de integración:

## Milestone 1: Fundamentos y Persistencia Base

Objetivo: Levantar los esqueletos de las aplicaciones y estructurar la base de datos.

## Tareas:

- \- Creación del repositorio y esquema inicial en Ruby on Rails y PostgreSQL.

- \- Implementación del patrón de Ledger con migraciones para las tablas transactions, cycles, distance_tables y audit_logs.

- \- Configuración de índices únicos (idpk y cycle_id) a nivel de motor de base de datos.

- \- Inicialización del proyecto Frontend y configuración base del worker de RabbitMQ.

## Milestone 2: Comunicación y Procesamiento de Eventos (Protocolo v2)

Objetivo: Lograr que los mensajes viajen desde la Central hasta la base de datos de manera limpia.


Tareas:

- \- Configuración de conexión AMQPS hacia city.TK3 en RabbitMQ respetando la regla de passive: true.

- \- Implementación del contrato interno: POST /events y POST /events/rejected.

- \- Desarrollo del LedgerProcessorService para asimilar eventos de transferencia y demanda.

- \- Refactorización del controlador para extraer atributos de la versión 2 del protocolo (data, msgId, timestamp, cycleId).

## Milestone 3: Orquestación, Auditoría y Resiliencia (Casos Borde)

Objetivo: Implementar lógica de negociación, timeouts y protección contra anomalías.

## Tareas:

- \- Resolución de Anomalía 1 (Duplicados): Manejo de excepciones de unicidad (RecordNotUnique) con guardado automático en Auditoría sin romper la transacción.

- \- Implementación del cálculo de balances dinámicos (Transaction.current_balance_for(cycle_id)) para consulta del Orquestador.

- \- Desarrollo de los Jobs de negociación (propuestas) y reportes con timeout de 30 segundos.

- \- Habilitación de CORS y creación de endpoints de lectura (GET /api/v1/...) para el Frontend.

## Milestone 4: Integración, Frontend y Despliegue en la Nube

Objetivo: Unificar el sistema, conectar las interfaces y desplegar en AWS.

## Tareas:

- \- Conexión del Frontend a los endpoints de la API para mostrar paneles de auditoría, distancias y estado del ciclo.

- \- Creación y optimización del Dockerfile del Backend.

- \- Armado del docker-compose.prod.yml consolidando la BD, el Connector y la API.

- \- Despliegue final en la instancia AWS EC2, probando la conexión remota con RabbitMQ y verificando logs en producción.

## 3. Roles

Víctor Castillo, Mensajería RabbitMQ y Gateway de Entrada: Implementó el consumidor de la cola city.{cityId} y el publicador hacia el exchange. Responsable de validar el envelope v2 completo, gestionar el envío de ACK/NACK (manejando errores 422, 400 y 403) y programar los descartes silenciosos. Configuró la inyección del user_id en el protocolo AMQP. Documentó el ADR1

Maximiliano Weldt, Ledger, Persistencia y Auditoría: Diseñó el modelo de base de datos reconstruible mediante un event log. Implementó la persistencia de los eventos transfer, demand-statement (con su convención de signos) y distance-table. Creó la tabla de auditoría para registrar duplicados de idpk, NACKs y descartes. Documentó el ADR2.

Thomas Herrmann, Orquestación de Ciclos y Negociación: Desarrolló los workers que controlan la ventana de 20 minutos. Programó el cálculo de precios (take/give), la validación de capacidad vendible y los límites de precio. Implementó el flujo completo de negociación con timeouts de 30 segundos, lógica de reintentos conservando el idpk y el envío automático del negotiation-report. Documentó el ADR3.

Camila Gómez — Frontend y Endpoints de Consulta: Desarrolló la aplicación cliente independiente en React/Vue. Construyó las 4 vistas requeridas: historial de ciclos, conectividad, negociaciones voluntarias y auditoría. Coordinó con el backend la exposición de los controladores REST necesarios para estas vistas.

Sofía Guerrero — Infraestructura, Autenticación y Monitoreo: Desplegó la infraestructura en AWS: Frontend en S3+CloudFront y Backend en EC2+ECR usando docker-compose. Configuró el API Gateway, CORS y la autenticación con Auth0/Cognito. Integró New Relic para el monitoreo de la aplicación y definió el contrato OpenAPI desde el día 1. También apoyo en las tareas de los demás integrantes.
