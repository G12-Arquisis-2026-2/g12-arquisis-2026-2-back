# Modelo de datos (base `primary`)

Entidad-relación de las tablas de `db/schema.rb` (versión `2026_10_08_200000`). El esquema **no declara claves
foráneas**: las relaciones son lógicas, por columnas de texto (`cycle_id`, `idpk`, `msg_id`) y se dibujan con línea
punteada. Todas las tablas tienen `id` bigint autoincremental como clave primaria. Las otras tres bases lógicas
(`cache`, `queue`, `cable`) son de Solid Cache, Solid Queue y Solid Cable y están en `db/cache_schema.rb`,
`db/queue_schema.rb` y `db/cable_schema.rb`; no se dibujan aquí.

```mermaid
erDiagram
  cycles {
    bigint id PK
    string cycle_id UK "not null"
    decimal generation_capacity
    decimal consumption
    decimal generation_cost
    datetime valid_until "fin de la ventana de negociación"
    boolean report_sent "default false"
    decimal reported_budget
    decimal reported_energy
    string report_idpk
    string report_msg_id "índice no único"
    datetime report_not_before "REPORT_TOO_EARLY"
    datetime report_missed_at
    datetime created_at
    datetime updated_at
  }

  transactions {
    bigint id PK
    string idpk UK "not null"
    string cycle_id "not null, índice"
    string operation_type "transfer, demand-statement, give, take"
    decimal energy_change "not null"
    decimal budget_change "not null"
    jsonb raw_data "mensaje original"
    datetime created_at
  }

  proposals {
    bigint id PK
    string idpk UK "not null"
    string cycle_id "not null, índice"
    string direction "give o take"
    decimal quantity "15,2 energía en kWh"
    decimal price_per_energy "15,2"
    decimal generation_cost "15,2 not null"
    string status "default PENDING"
    string status_reason
    datetime confirmed_at
    integer transfer_retries "default 0"
    datetime last_transfer_retry_at
    datetime created_at
    datetime updated_at
  }

  outbox_messages {
    bigint id PK
    string msg_id UK "not null"
    string idpk "not null"
    string message_type "not null"
    jsonb payload "envelope completo"
    string status "pending, sent o failed, índice"
    integer attempts "default 0"
    string error
    datetime sent_at
    datetime created_at
    datetime updated_at
  }

  processed_messages {
    bigint id PK
    string idpk UK "not null"
    string message_type "status-statement, distance-table, error, ack, nack, demand-set"
    datetime created_at
  }

  audit_logs {
    bigint id PK
    string idpk "nullable"
    string event_type "DUPLICATE, NACK, DISCARDED, CENTRAL_ACK, ..."
    string reason "not null"
    jsonb raw_payload
    datetime created_at
  }

  distance_tables {
    bigint id PK
    string destination_code UK "not null"
    integer distance "not null"
    decimal transport_cost "not null"
    boolean enabled "not null"
  }

  demand_events {
    bigint id PK
    string idpk UK "not null"
    string event_type "not null"
    jsonb package_body
    datetime received_at "índice"
    datetime created_at
    datetime updated_at
  }

  cycles ||..o{ transactions : "cycle_id"
  cycles ||..o{ proposals : "cycle_id"
  proposals ||..|{ outbox_messages : "idpk, propuesta y sus reintentos"
  cycles |o..o{ outbox_messages : "payload.cycleId del negotiation-report"
```

## Claves e índices únicos

| Tabla | Índice único | Para qué |
|---|---|---|
| `cycles` | `cycle_id` | Un registro por ciclo; el `status-statement` hace upsert por `cycleId` |
| `transactions` | `idpk` | Idempotencia del ledger: un `idpk` repetido no se aplica dos veces (ADR2) |
| `proposals` | `idpk` | Una propuesta por `idpk`; sus reintentos reutilizan el mismo |
| `outbox_messages` | `msg_id` | Cada mensaje de salida (incluido cada reintento) tiene `msgId` propio |
| `processed_messages` | `idpk` | Idempotencia de los mensajes que no dejan fila propia con `idpk` |
| `distance_tables` | `destination_code` | Una fila por destino; cada `distance-table` las actualiza |
| `demand_events` | `idpk` | Tabla de la E0 |

Índices no únicos: `cycles.report_msg_id`, `transactions.cycle_id`, `proposals.cycle_id`, `outbox_messages.status`,
`demand_events.received_at`.

## Notas de lectura

- Las relaciones declaradas en los modelos son `Cycle has_many :transactions` y `Transaction belongs_to :cycle`
  (`optional: true`), ambas por `cycle_id` (`app/models/cycle.rb:3`, `app/models/transaction.rb:2`). El resto
  (propuesta ↔ outbox, ciclo ↔ propuesta) se resuelve con consultas en los servicios.
- `outbox_messages.idpk` también guarda el `idpk` de mensajes que no son propuestas (`transfer` de pago,
  `negotiation-report`, `request`). La relación con `proposals` aplica solo a `message_type = negotiation-proposal`.
- `transactions.raw_data` guarda el mensaje completo de la central. Varias consultas leen dentro del JSON:
  `raw_data->'data'->>'becauseOf'`, `raw_data->'data'->>'target'` y `raw_data->>'msgId'`.
- `cycles.report_msg_id` apunta al `outbox_messages.msg_id` del último reporte encolado, y
  `cycles.report_idpk` a su `idpk`.

## A confirmar

- Si `demand_events` se mantiene: ningún componente actual escribe en ella (solo `HistoryController` la lee).
