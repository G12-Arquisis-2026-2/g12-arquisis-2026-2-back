# Secuencia de una propuesta de negociación (give y take)

Flujo de una `negotiation-proposal` creada desde el front: validación local, persistencia de la propuesta y del
mensaje de salida en una sola transacción, publicación por el outbox, confirmación de la central y pago.
Hay dos esperas de 30 s distintas en `NegotiationTimeoutJob`: la de la **confirmación** (propuesta `pending`, se
reintenta cada 30 s con el mismo `idpk` hasta que cierra la ventana del ciclo) y la del **transfer** de un `give`
ya confirmado (hasta 3 reintentos con el mismo `idpk`). Cada reintento lleva un `msgId` nuevo.

```mermaid
sequenceDiagram
  autonumber
  participant F as Front (vía API Gateway y Nginx)
  participant P as ProposalsController
  participant N as NegotiationService
  participant D as db
  participant Q as NegotiationTimeoutJob (Solid Queue)
  participant K as connector
  participant C as Central (RabbitMQ)
  participant L as EventsController y procesadores
  participant O as OutboxController

  F->>P: POST /proposals con cycleId, direction, energy
  alt energy menor o igual a 0, o falta cycleId o direction
    P-->>F: 422
  end
  P->>N: build_proposal
  N->>D: Cycle, ventas give ya confirmadas del ciclo
  alt Ciclo inexistente
    P-->>F: 404
  else give que supera la capacidad vendible, o precio sobre el tope
    P-->>F: 422
  end
  N-->>P: envelope con idpk y msgId nuevos, pricePerEnergy (take = generationCost, give = round2 de 1.05 x generationCost)

  rect rgb(235,245,255)
    Note over P,D: Una sola transacción
    P->>D: Proposal.create con status PENDING
    P->>D: RabbitMQPublisher, OutboxMessage negotiation-proposal pending
  end
  P->>Q: perform_later con espera de 30 s
  P-->>F: 201 con la propuesta

  K->>O: GET /events/outbox (cada 2 s)
  O-->>K: negotiation-proposal pendiente
  K->>C: publica negotiation-proposal con user_id y espera el confirm
  K->>O: POST /events/outbox/id con status sent
  C->>K: ack de recepción
  K->>L: POST /events (type ack), queda AuditLog CENTRAL_ACK

  alt give confirmado por la central
    C->>K: give con data.target = msgId de la propuesta
    K->>L: POST /events
    L->>D: Transaction give (energy -e) y Proposal CONFIRMED
    L->>Q: after_commit agenda la espera del transfer a confirmed_at + 30 s
    K->>C: ack del give
    loop Hasta que llega el transfer o se cierra la propuesta
      alt Llega el transfer de pago
        C->>K: transfer con data.becauseOf = msgId del give
        K->>L: POST /events
        L->>D: Transaction transfer (budget +quantity) y Proposal PAID
        K->>C: ack del transfer
      else Pasan 30 s sin transfer
        Q->>D: transfer_received es falso
        alt Ventana del ciclo cerrada o ya hubo 3 reintentos
          Q->>D: Proposal FAILED
        else Quedan reintentos
          Q->>N: build_proposal con existing_idpk
          Q->>D: OutboxMessage con el mismo idpk y msgId nuevo, transfer_retries + 1
          Q->>Q: nueva espera de 30 s
        end
      end
    end
  else take confirmado por la central
    C->>K: take con data.target = msgId de la propuesta
    K->>L: POST /events
    L->>D: Transaction take (energy +e, budget -round2 de e x precio) y Proposal PAID
    L->>D: RabbitMQPublisher, OutboxMessage transfer con becauseOf = msgId del take
    K->>C: ack del take
    K->>O: GET /events/outbox (cada 2 s)
    K->>C: publica el transfer de pago
  else error de la central (después de su ack)
    C->>K: error PRICE_ABOVE_CAP, OVER_CAPACITY, CYCLE_EXPIRED o CYCLE_UNKNOWN
    K->>L: POST /events (type error), el connector no responde
    L->>D: AuditLog CENTRAL_ERROR
    L->>D: OutboxMessage por msg_id lleva al idpk, Proposal.close a REJECTED
    L->>D: reintentos aún pendientes en el outbox pasan a failed
  else Pasan 30 s sin confirmación
    Q->>D: la propuesta sigue PENDING
    alt Ventana del ciclo cerrada (now mayor o igual a valid_until)
      Q->>D: Proposal.close a EXPIRED
    else Ventana abierta
      Q->>N: build_proposal con existing_idpk
      Q->>D: OutboxMessage con el mismo idpk y msgId nuevo
      Q->>Q: nueva espera de 30 s, sin tope de intentos
    end
    opt El reintento no se puede armar (ciclo borrado, sobre capacidad o sobre tope)
      Q->>D: Proposal.close a FAILED
    end
  end
```

## Referencias en el código

| Paso | Dónde |
|---|---|
| Validación de parámetros y respuesta | `app/controllers/proposals_controller.rb:11-69` |
| Precio, tope y capacidad vendible | `app/services/negotiation_service.rb:6-64` |
| Transacción propuesta + outbox | `app/controllers/proposals_controller.rb:37-49` |
| Primera espera de 30 s | `app/controllers/proposals_controller.rb:52` |
| `give` → CONFIRMED | `app/services/ledger_processor_service.rb:51-52`, `78-81` |
| Espera del transfer agendada | `app/models/proposal.rb:27`, `74-77` |
| `transfer` con `becauseOf` → PAID | `app/services/ledger_processor_service.rb:57-60`, `109-117` |
| `take` → PAID y transfer de pago | `app/services/ledger_processor_service.rb:54-55`, `86-105` |
| Error de la central → REJECTED | `app/services/error_processor_service.rb:6`, `23-24`, `32-47`; `app/models/proposal.rb:36-44` |
| Espera de confirmación, EXPIRED y reintento | `app/jobs/negotiation_timeout_job.rb:13-44` |
| Espera del transfer, hasta 3 reintentos | `app/jobs/negotiation_timeout_job.rb:51-94`; `app/models/proposal.rb:4-5` |
| Mismo `idpk`, `msgId` nuevo | `app/services/negotiation_service.rb:67-68` |

## Notas de lectura

- `Proposal.close!` solo cierra desde el estado indicado en `from:` (por defecto `pending`). Un `error` de la
  central sobre el reintento de un `give` ya confirmado no lo pasa a REJECTED: ese caso lo cierra el job como
  FAILED.
- La propuesta se busca por `data.target` → `outbox_messages.msg_id` → `idpk`. Si no aparece, `LedgerProcessorService`
  toma la primera propuesta PENDING o CONFIRMED del mismo ciclo y dirección (`ledger_processor_service.rb:121-135`).

## A confirmar

- El enunciado pide reintentar con el mismo `idpk` si no llega el transfer; no fija un tope. El tope de 3
  (`Proposal::MAX_TRANSFER_RETRIES`) y el reintento sin tope de una propuesta sin confirmación son decisiones del
  equipo: confirmar que es lo que se quiere documentar.
- El front recibe `201` con `status: "pending"` y luego consulta `GET /proposals` para ver el estado. No se revisó
  cada cuánto refresca.
