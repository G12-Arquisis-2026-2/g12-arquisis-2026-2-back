# Secuencia de un ciclo de negociación

Un ciclo completo visto desde nuestro nodo. `T` es el `data.validUntil` del `status-statement`, es decir, el
cierre de la ventana de negociación. El código trabaja siempre relativo a `T` (`app/services/cycle_service.rb:5-22`):
la ventana abre en `T - 20 min`, el periodo de cierre va de `T - 5 min` a `T`, y el reporte solo se encola hasta
`T - 30 s`. Si `T` cae en una hora en punto, eso corresponde a xx:40, xx:55 y xx:59:30.
El detalle de cada entrega al back (validación y ramas por código HTTP) está en `secuencia-evento-entrante.md`, y la
negociación voluntaria en `secuencia-propuesta.md`.

```mermaid
sequenceDiagram
  autonumber
  participant C as Central (RabbitMQ)
  participant K as connector
  participant W as web (EventsController y procesadores)
  participant D as db (base primary)
  participant J as CycleOrchestratorJob y CycleService
  participant X as web (OutboxController)

  Note over C,X: Apertura de la ventana en T - 20 min

  C->>K: status-statement en city.TK3.q
  K->>W: POST /events
  W->>D: ProcessedMessage + Cycle (upsert por cycleId, guarda validUntil)
  W-->>K: 201 saved
  K->>C: ack con data.target = msgId recibido
  K->>K: basic.ack en la cola

  opt No llegó el status-statement 1 min después de la apertura esperada
    J->>D: tick encuentra la ventana abierta sin ciclo nuevo
    J->>D: OutboxMessage request con ask = status-statement
    Note over J,D: Máximo 3 peticiones por ventana, separadas por 1 min y 3 min
  end

  C->>K: transfer de fondos (data.quantity, sin becauseOf)
  K->>W: POST /events
  W->>D: Transaction transfer, budget_change = +quantity
  W-->>K: 201 saved
  K->>C: ack

  C->>K: demand-statement (data.balance.quantity y valuePerKwh)
  K->>W: POST /events
  W->>D: Transaction demand-statement, energy +q y budget -q x valuePerKwh
  W-->>K: 201 saved
  K->>C: ack

  Note over C,X: Negociación voluntaria opcional durante la ventana, ver secuencia-propuesta.md

  Note over C,X: Periodo de cierre, de T - 5 min a T - 30 s

  loop Cada tick del orquestador (cada 30 s dentro del periodo, nunca más de 1 min)
    J->>D: pg_advisory_xact_lock y CycleService.tick
    alt Primer reporte o los saldos cambiaron
      J->>D: CycleBalanceService calcula budget y energy
      J->>D: OutboxMessage negotiation-report con idpk nuevo
      J->>D: Cycle.report_sent, report_idpk, report_msg_id, reported_budget, reported_energy
    else Mismos saldos y sin REPORT_TOO_EARLY pendiente
      J->>J: no encola nada
    end
  end

  loop Cada 2 s (hilo outbox del connector)
    K->>X: GET /events/outbox
    X->>D: expire_late_reports marca failed los reportes a menos de 5 s de T
    X-->>K: mensajes pendientes en orden de id
    K->>C: publica en el exchange con user_id y espera el confirm del broker
    K->>X: POST /events/outbox/id con status sent
  end

  C->>K: ack con data.target = msgId del reporte
  K->>W: POST /events (type ack)
  W->>D: AuditLog CENTRAL_ACK
  Note over K: Un ack de la central no se responde

  opt La central responde error (siempre después de su ack)
    C->>K: error
    K->>W: POST /events (type error)
    W->>D: AuditLog CENTRAL_ERROR
    alt reason REPORT_TOO_EARLY
      W->>D: Cycle.report_not_before = data.opensAt
      J->>D: desde opensAt reenvía el mismo contenido con el mismo idpk y msgId nuevo
    else reason CYCLE_EXPIRED
      Note over W,D: Solo queda el AuditLog
    end
  end

  Note over C,X: Cierre de la ventana en T
  J->>D: si ningún negotiation-report salió, Cycle.report_missed_at y AuditLog REPORT_MISSED
```

## Referencias en el código

| Paso | Dónde |
|---|---|
| Ventana, periodo de cierre y márgenes | `app/services/cycle_service.rb:5-22` |
| Petición del `status-statement` si no llega | `app/services/cycle_service.rb:79-110` |
| Petición de `distance-table` si la tabla está vacía | `app/services/cycle_service.rb:63` |
| Guardado del `status-statement` | `app/services/status_statement_processor_service.rb` |
| `transfer` y `demand-statement` en el ledger | `app/services/ledger_processor_service.rb:14-24` |
| Cuándo se encola el reporte | `app/services/cycle_service.rb:113-122` |
| Reporte nuevo vs. corrección vs. reintento (mismo `idpk`) | `app/services/cycle_service.rb:124-141` |
| Saldos del reporte | `app/services/cycle_balance_service.rb` |
| Reportes que no alcanzan a salir | `app/models/outbox_message.rb:16-23` |
| Publicación del outbox | `connector/lib/outbox_sender.rb`, `connector/consumer.rb:65-77` |
| `REPORT_TOO_EARLY` | `app/services/error_processor_service.rb:20-22`, `app/services/cycle_service.rb:68-75` |
| Ciclo sin reporte entregado | `app/services/cycle_service.rb:144-164` |

## A confirmar

- Que la central publique en el orden mostrado (`status-statement`, `transfer`, `demand-statement`). El código no
  depende del orden y el enunciado dice que `demand-statement` llega "cada cierto tiempo".
- Que `validUntil` caiga en horas en punto (de eso salen los xx:40, xx:55 y xx:59:30). El código no lo asume.
- Que en producción no se hayan cambiado `CYCLE_LENGTH_MINUTES`, `NEGOTIATION_WINDOW_MINUTES` ni
  `REPORT_PERIOD_MINUTES` (por defecto 120, 20 y 5).
