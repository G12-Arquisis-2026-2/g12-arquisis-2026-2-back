# 1. Especificación de la Entrega
Entrega: martes 1 de diciembre de 2026 (meta interna: lunes 30 de noviembre).

### Objetivo General:
Llevar el nodo de Tokyo-3 (TK3) a un estado en que otro equipo podría operarlo, sin cambiar la mecánica del mercado. El ciclo de vida de cada swap pasa a ser una saga orquestada y legible en AWS Step Functions; los mensajes que nacen de un cambio de estado dejan de depender de que nada falle entre la base de datos y el broker; el monitoreo avisa de las fallas propias del sistema; y la infraestructura queda escrita como código y revisada en seguridad. Todo se cambia con el nodo en operación, sin perder ciclos.

### Qué cambia respecto de la E2:
- El protocolo v3 no cambia: mensajes, eventos, endpoints de la wallet, códigos de error, límites y el ciclo de 20 minutos son los de la E2.
- El ciclo de vida de un swap, como vendedor y como comprador, se ejecuta en máquinas de estados Standard de AWS Step Functions con tareas Lambda.
- Los mensajes que nacen de un cambio de estado local (negotiation-report, mensajes de la oferta e inicio de las sagas) salen por un outbox.
- El monitoreo incluye cinco alertas sobre los modos de falla del nodo, con un runbook.
- El panel de administración tiene un feed en tiempo real por SSE.
- La infraestructura se describe con IaC (Terraform o CDK) y pasa por Prowler.
- Las medidas de los escenarios de calidad (AD7 y AD8) son numéricas y se muestran desde nuestra propia telemetría.

### Arquitectura de Componentes:
Se mantiene la arquitectura de la E2 en contenedores sobre EC2 (ahora t3.small), y se agregan piezas serverless y de operación:

Connector (EC2): Script en Ruby (Bunny) que sigue consumiendo city.TK3.q y market.TK3 con las reglas de recepción de siempre. Aplica los eventos de la wallet al Ledger una sola vez (AD5) y reanuda la saga que esperaba ese evento llamando a SendTaskSuccess o SendTaskFailure con el task token guardado.
Máquinas de estados (Step Functions, tipo Standard): Una para el vendedor (Reservar, Proponer, Avisar, EsperarCierre, Reconciliar, Cancelar, Compensar, Liquidado) y otra para el comprador (Verificar, RevisarPlazo, Aceptar, Reconciliar, Rechazado, Liquidado). Una ejecución por operación, nombrada con el idpk del mensaje que la inicia. Todo estado que espera lleva timeout.
Tareas Lambda: Llaman a la wallet por HTTP con la misma Idempotency-Key en cada reintento y publican al broker. Distinguen 202, 200, 429, 502/503/504, 422 IDEMPOTENCY_MISMATCH y 401/404 en su política de Retry y Catch.
Almacenamiento de task tokens: Tabla con TTL, guardada bajo data.idpk (swap-proposed, swap-rejected) o swapId (swap-settled, swap-cancelled, swap-expired). El token se guarda antes de llamar a la wallet.
Backend (Ruby on Rails):
- Outbox: Tabla outbox_messages escrita en la misma transacción que el cambio de estado, y un relay que publica cada fila con su idpk original y la marca como enviada.

- Feed SSE: Endpoint autenticado que emite mensajes del mercado, eventos de la wallet, transiciones de las sagas y alertas disparadas, con reanudación por Last-Event-ID.

Monitoreo (New Relic): Cinco alertas (wallet lenta, consumidor detenido o atrasado, ledger desviado, saga atascada o fallando, outbox con atraso), cada una con condición, umbral, tiempo de detección objetivo y canal. Logs correlacionables por cycleId, swapId e idpk. Métricas de Step Functions y Lambda vía la integración con CloudWatch.
Infraestructura como código: Lo nuevo (máquinas de estados, Lambdas, roles con permisos mínimos y almacenamiento de tokens) se despliega desde código. Lo existente (API Gateway, EC2, S3, CloudFront) queda descrito y recreable en una cuenta limpia.
Frontend: Aplicación React con build estático en S3 + CloudFront. Se agrega la vista del feed en tiempo real al panel de administración.

### Reglas que no se negocian:
- El commit de cada ADR (AD7 y AD8) precede a los commits que lo implementan.
- El task token se guarda antes de llamar a la wallet.
- Todo estado que espera un evento tiene timeout.
- La Idempotency-Key se guarda antes de la primera llamada y se reutiliza en cada reintento.
- Ningún secreto (.env, .pem, API key de la wallet) entra al repositorio ni a una imagen de Docker. El .dockerignore excluye .env* salvo .env.example.
- En producción se usa siempre docker-compose.prod.yml. El docker-compose.yml es solo para desarrollo.
- Los cambios en producción se aplican fuera de la ventana del negotiation-report (T+10 a T+15 del ciclo).
- La saga y el outbox entran detrás de feature flags, probados un ciclo a la vez y con vuelta atrás.

# 2. Plan de Milestones
Para organizar el desarrollo de la Entrega 3, el equipo dividió el trabajo en 5 hitos. Cada hito termina en una condición de salida que el grupo revisa antes de avanzar.

### Milestone 1: Fundaciones y estabilización (viernes 27)
Objetivo: Dejar escritas las decisiones de arquitectura y el nodo estable para trabajar encima.
Condición de salida: ADRs de AD7 y AD8 en el repositorio, nodo reportando ciclo a ciclo y base de IaC desplegada.

Tareas:
- ADRs de AD7 y AD8, commiteados antes de su implementación.

- Spec y milestones de la entrega.

- Recuperación del connector caído desde el 26/11, instancia en t3.small, política de restart y límite de logs en el compose de producción.

- Reporte inicial de Prowler.

- Base de IaC: almacenamiento de task tokens, secreto de la API key de la wallet y roles IAM.

### Milestone 2: Saga y Outbox (sábado 28)
Objetivo: Que una saga corra de punta a punta y que el reporte salga por el outbox.
Condición de salida: Al menos una ejecución completa de la saga en producción con el feature flag activo, y un negotiation-report enviado por el outbox.

Tareas:
- Máquinas de estados de vendedor y comprador, con Retry, Catch y timeouts.

- Lambdas de Reservar, Proponer, Avisar, Cancelar, Compensar, Verificar, Aceptar y Reconciliar.

- Consumer que guarda y busca tokens y reanuda la saga con SendTaskSuccess o SendTaskFailure.

- Tabla outbox y relay; negotiation-report por el outbox detrás de feature flag.

- Máquinas, Lambdas y permisos desplegados desde IaC (StartExecution sobre las dos máquinas, SendTaskSuccess y SendTaskFailure).

### Milestone 3: Operación (domingo 29)
Objetivo: Cumplir los esenciales de la entrega y que el nodo avise de sus propias fallas.
Condición de salida: G03, G04 y G05 cumplidos.

Tareas:
- Primer swap liquidado a través de la saga en producción (G03).

- Mensajes de la oferta e inicio de las sagas por el outbox (G04).

- Cinco alertas en New Relic y logs correlacionables por cycleId, swapId e idpk.

- Feed SSE autenticado con Last-Event-ID.

- Tres hallazgos de Prowler reparados con evidencia y reporte posterior (G05).

- Budget alerts que cubran Step Functions y Lambda.

### Milestone 4: Documentación y Ensayo (lunes 30)
Objetivo: Completar la documentación evaluada y ensayar la demo.
Condición de salida: Todos los documentos en /docs, simulacro de incidente y un ensayo completo de demo.

Tareas:
- Post-mortems de AD4, AD5 y AD6 con evidencia de la telemetría.

- Medición de los objetivos por ciclo declarados en el ADR de AD7 y prueba de caída para AD8.

- Runbook de las cinco alertas y diagrama UML de componentes actualizado.

- AI logs de todos los integrantes.

- Simulacro: cada integrante provoca una falla y el grupo la diagnostica solo con la telemetría.

- Ensayo de demo: recorrido de arquitectura por turnos y preguntas cruzadas sin AI.

### Milestone 5: Entrega (martes 1)
Objetivo: Entregar con todos los requisitos esenciales verificados.

Tareas:
- Congelamiento del código.

- Verificación de que ninguna ejecución queda abierta después de closesAt y ninguna reserva queda retenida al cierre.

- Verificación uno por uno de los gates G01 a G05 y deploy final.

- Demo agendada con el ayudante.

# 3. Roles
Víctor Castillo, Outbox y Mensajería: Implementa la tabla outbox y su relay, y pasa al outbox el negotiation-report, los mensajes de la oferta y el inicio de las sagas. Prueba la caída del backend y del broker entre el commit y la publicación (AD8). Documenta el ADR de AD8. Mantiene los contract tests y la reconexión automática al broker.

Maximiliano Weldt, Consumer de la Saga y Ledger: Implementa el lado del consumer de la saga: guarda y busca los task tokens y reanuda las ejecuciones con SendTaskSuccess o SendTaskFailure. Escribe las Lambdas de Reservar, Compensar, Verificar y Reconciliar. Expone la métrica de ledger desviado contra GET /balance. Documenta los post-mortems de AD4, AD5 y AD6.

Thomas Herrmann, Máquinas de Estados: Diseña las sagas de vendedor y comprador en Step Functions, con Retry, Catch y timeouts en cada estado que espera. Escribe las Lambdas de Proponer, Avisar, Cancelar y Aceptar. Logra el primer swap por la saga (G03) y mide los objetivos por ciclo. Documenta el ADR de AD7.

Camila Gómez, Feed SSE y Alertas: Construye el feed en tiempo real del panel (backend y frontend) con autenticación y Last-Event-ID. Configura las cinco alertas en New Relic, define el formato de logs correlacionables y escribe el runbook.

Sofía Guerrero, Infraestructura como Código y Seguridad: Estabilizó la infraestructura tras la caída del 26/11 (t3.small, restart, límite de logs). Escribe la IaC del almacenamiento de tokens, las Lambdas, las máquinas de estados y los roles con permisos mínimos, y describe la infraestructura existente. Corre Prowler y repara tres hallazgos con evidencia. Gestiona los secretos y las budget alerts. Escribe la spec y los milestones y el diagrama UML, y coordina los AI logs y el ensayo de la demo.
