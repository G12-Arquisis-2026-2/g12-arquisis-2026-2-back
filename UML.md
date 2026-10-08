# Diagrama UML

Vista UML de componentes de lo que corre dentro del contenedor `web` (Rails) y de cómo se conecta con el
connector y la central. Cada flecha va **desde quien inicia** hacia quien recibe, y su etiqueta dice qué viaja.
Todo sale de `config/routes.rb`, `app/controllers`, `app/services`, `app/jobs`, `app/models` y `connector/`. Lo
marcado con † (y borde punteado) no se ve en el repo y se toma **según la documentación de despliegue**
(`docs/arquitectura-y-despliegue.md`).

```mermaid
flowchart LR
  subgraph EXT["Externos (Front, API Gateway, central RabbitMQ)"]
    FE["«component» Front React †<br/>S3 + CloudFront"]
    APIGW["«component» API Gateway †<br/>authorizer JWT, luego Nginx"]
    CENTRAL[("«component» RabbitMQ de la central<br/>cola city.TK3.q")]
  end

  subgraph ENT["Entrada (controladores)"]
    PC["«component» ProposalsController<br/>GET y POST /proposals"]
    RD["«component» CyclesController, ConnectivityController,<br/>AuditLogsController<br/>GET /cycles, /connectivity, /audit-logs"]
    EV["«component» EventsController<br/>POST /events, POST /events/rejected"]
    OB["«component» OutboxController<br/>GET /events/outbox, POST /events/outbox/:id"]
  end

  subgraph CORE["Core de negociación (servicios y modelos)"]
    LED["«component» LedgerProcessorService<br/>StatusStatementProcessorService<br/>DistanceTableProcessorService"]
    ERR["«component» ErrorProcessorService"]
    AUD["«component» AuditedEventService"]
    NS["«component» NegotiationService"]
    PRP["«component» Proposal<br/>modelo, máquina de estados"]
    CS["«component» CycleService<br/>CycleBalanceService, CyclePresenter"]
  end

  subgraph JOBS["Jobs (Solid Queue dentro de Puma)"]
    COJ["«component» CycleOrchestratorJob"]
    NTJ["«component» NegotiationTimeoutJob"]
  end

  subgraph INT["Integración con la central (outbox y connector)"]
    PUB["«component» RabbitMQPublisher"]
    OUTM["«component» OutboxMessage<br/>tabla outbox_messages"]
    CONN["«component» connector<br/>connector/consumer.rb"]
  end

  subgraph DAT["Datos (PostgreSQL)"]
    DB[("«component» base primary<br/>transactions, cycles, proposals,<br/>audit_logs, processed_messages,<br/>distance_tables, outbox_messages")]
  end

  FE -->|"HTTPS + Bearer JWT"| APIGW
  APIGW -->|"HTTP"| PC
  APIGW -->|"HTTP"| RD

  CONN -->|"AMQPS consume y publica ack, nack y outbox"| CENTRAL
  CONN -->|"HTTP mensaje de la central"| EV
  CONN -->|"HTTP pide y marca pendientes"| OB

  EV -->|"transfer, demand-statement, give, take,<br/>status-statement, distance-table"| LED
  EV -->|"error"| ERR
  EV -->|"ack, nack, demand-set"| AUD
  LED -->|"CONFIRMED o PAID"| PRP
  LED -->|"transfer de pago de un take"| PUB
  ERR -->|"REJECTED"| PRP
  ERR -->|"REPORT_TOO_EARLY"| CS

  PC -->|"build_proposal"| NS
  PC -->|"create PENDING"| PRP
  PC -->|"misma transacción"| PUB
  PRP -->|"after_commit de un give confirmado"| NTJ
  PC -->|"espera de 30 s"| NTJ
  NTJ -->|"reintento con el mismo idpk"| NS
  NTJ -->|"negotiation-proposal"| PUB
  COJ -->|"tick con advisory lock"| CS
  CS -->|"request y negotiation-report"| PUB
  RD -->|"format"| CS

  PUB -->|"fila de outbox pending"| OUTM
  OB -->|"pending, mark_sent, mark_failed"| OUTM

  LED -->|"SQL"| DB
  AUD -->|"SQL audit_logs"| DB
  PRP -->|"SQL"| DB
  CS -->|"SQL"| DB
  OUTM -->|"SQL"| DB

  classDef docdesp stroke-dasharray: 5 5
  class FE,APIGW docdesp
```

## Explicación del diagrama

- **Capas.** Los controladores reciben HTTP del front (vía API Gateway † y Nginx) o del connector (por la red
  interna de Docker). El core aplica las reglas del protocolo y guarda en la base `primary`. Los jobs corren en
  Solid Queue dentro del mismo proceso Puma, con sus colas en la base `queue`. El outbox y el connector son el único
  camino hacia la central: el back nunca abre una conexión al broker.
- **Evento entrante.** El connector consume `city.TK3.q`, valida el mensaje y hace `POST /events`.
  `EventsController` elige el procesador según `type` (`EventsController::PROCESSORS`). Si el procesador responde
  2xx, el connector publica el `ack` directo a la central (no por el outbox). Un `idpk` repetido responde
  `200 duplicate` y no toca el ledger (`transactions.idpk` y `processed_messages.idpk` son únicos).
- **Confirmación de una propuesta.** Un `give` de la central pasa la propuesta a CONFIRMED y su transfer a PAID. Un
  `take` la pasa a PAID y deja en el outbox nuestro `transfer` de pago. Un `error` (PRICE_ABOVE_CAP, OVER_CAPACITY,
  CYCLE_EXPIRED, CYCLE_UNKNOWN) la cierra como REJECTED.
- **Propuesta saliente.** `ProposalsController` valida con `NegotiationService` (precio y capacidad vendible),
  crea la `Proposal` PENDING y la fila de outbox en una sola transacción, y agenda `NegotiationTimeoutJob` a 30 s.
  El connector pide los pendientes cada 2 s (`GET /events/outbox`), los publica con `user_id` esperando el confirm
  del broker, y los marca con `POST /events/outbox/:id`.
- **Esperas de 30 s.** Una propuesta sin confirmación se reintenta con el mismo `idpk` y `msgId` nuevo hasta que
  cierra la ventana del ciclo (pasa a EXPIRED). Un `give` confirmado sin transfer se reintenta hasta 3 veces (luego
  FAILED).
- **Ciclo autónomo.** El initializer `start_orchestrator` encola `CycleOrchestratorJob`, que se reprograma solo
  y llama a `CycleService.tick`: pide el `status-statement` si no llega y encola el `negotiation-report` en el
  periodo de cierre, con los saldos que calcula `CycleBalanceService`.
- **Lectura del front.** `CyclesController` arma cada ciclo con `CyclePresenter`. `ConnectivityController` y
  `AuditLogsController` leen directo `distance_tables` y `audit_logs`.
