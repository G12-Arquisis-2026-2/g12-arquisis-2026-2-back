# Secuencia de un mensaje entrante

Qué pasa con cada mensaje que llega a la cola `city.TK3.q`. El connector consume con `prefetch(1)` y ack manual,
lo valida (`MessageValidator`), y si es válido lo entrega con `POST /events`. Según la respuesta del back decide si
responde `ack` o `nack` a la central y qué hace con el mensaje en la cola: `basic.ack` (sale de la cola),
`basic.nack` con requeue (vuelve a la cola) o `basic.nack` sin requeue (descartado). Las respuestas de la central
(`ack`, `nack`, `error`) se guardan pero nunca se responden.

```mermaid
sequenceDiagram
  autonumber
  participant C as Central (RabbitMQ)
  participant K as connector
  participant W as web (POST /events)
  participant D as db

  C->>K: mensaje en city.TK3.q
  K->>K: MessageValidator.check

  alt No es un objeto JSON o no trae msgId
    K->>W: POST /events/rejected kind discard
    W->>D: AuditLog DISCARDED
    K->>K: basic.ack, no se responde a la central
  else Respuesta de la central (ack, nack, error) con envelope inválido
    K->>W: POST /events/rejected kind central
    W->>D: AuditLog CENTRAL_ tipo
    K->>K: basic.ack, no se responde
  else Envelope o contenido inválido, idpk igual a msgId, o tipo desconocido
    K->>C: nack MALFORMED_MESSAGE 422, IDPK_EQUALS_MSGID 422 o UNKNOWN_TYPE 400
    K->>W: POST /events/rejected kind nack
    W->>D: AuditLog NACK
    K->>K: basic.ack
  else Mensaje válido
    K->>W: POST /events
    W->>W: tipo conocido, EventPayloadValidator y procesador del tipo
    alt 201 saved
      W->>D: fila nueva (ledger, ciclo, tabla de distancias o AuditLog)
      W-->>K: 201
      K->>C: ack (salvo que el mensaje sea ack, nack o error)
      K->>K: basic.ack
    else 200 duplicate (idpk ya procesado)
      W->>D: AuditLog DUPLICATE, el ledger no cambia
      W-->>K: 200 duplicate
      K->>C: ack (salvo que el mensaje sea ack, nack o error)
      K->>K: basic.ack
    else 422 UNKNOWN_TYPE o MALFORMED_MESSAGE
      W-->>K: 422
      alt Mensaje de un tipo que se responde
        K->>C: un nack UNKNOWN_TYPE 400 o MALFORMED_MESSAGE 422
      else Respuesta de la central
        K->>K: no se responde
      end
      K->>K: basic.ack
    else 500 (u otro código no 2xx distinto de 422, 502, 503 y 504)
      W-->>K: 500
      loop Reintentos 1 a 3, esperas de 5 s, 15 s y 45 s
        K->>K: espera y basic.nack con requeue
        C->>K: el mismo mensaje vuelve
        K->>W: POST /events
      end
      K->>W: al 4.º fallo POST /events/rejected kind discard, MAX_RETRIES_EXCEEDED
      W->>D: AuditLog DISCARDED
      K->>K: basic.nack sin requeue, sin nack a la central
    else 502, 503, 504 o sin respuesta (conexión rechazada o timeout)
      loop Sin límite, no cuenta como intento
        K->>K: espera 5 s y basic.nack con requeue
        C->>K: el mismo mensaje vuelve
        K->>W: POST /events
      end
      Note over K: No hay ack ni descarte mientras la API siga caída
    end
  end

  opt No se pudo publicar el ack o el nack a la central
    K->>K: espera 5 s y basic.nack con requeue, sin límite
  end
```

## Referencias en el código

| Paso | Dónde |
|---|---|
| Consumo, `prefetch(1)`, ack manual y `settle` | `connector/consumer.rb:41-50`, `87`, `97-99` |
| Reglas de validación del connector | `connector/lib/message_validator.rb:20-50` |
| Descarte, NACK propio y entrega | `connector/lib/message_processor.rb:44-57`, `107-161` |
| Reintentos 5/15/45 s y descarte | `connector/lib/message_processor.rb:12`, `76-98` |
| Espera sin límite (API caída o no se pudo publicar) | `connector/lib/message_processor.rb:14`, `50-62`; `connector/lib/master_client.rb:21-23` |
| Respuestas del back | `app/controllers/events_controller.rb:34-63` |
| 503 si la base no está disponible | `app/controllers/events_controller.rb:17-22`, `57-59` |
| Registro de rechazos | `app/controllers/events_controller.rb:65-76`, `app/models/audit_log.rb` |

## Notas de lectura

- "Descarte" en la rama 500 es un `basic.nack` sin requeue al broker, no un `nack` del protocolo: a la central no se
  le publica nada (`message_processor.rb:88-98`).
- Con `ENABLE_PUBLISHER` distinto de `true` los `ack` y `nack` no se publican (solo se loguean) y el flujo sigue
  igual.
- El NACK de la rama 422 no pasa por `POST /events/rejected`, así que no queda fila NACK en `audit_logs`
  (`message_processor.rb:154-161`). Los NACK que decide el propio connector sí quedan.
- La cuenta de fallos de la rama 500 vive en memoria del connector (`@failures`, por `msgId`): un reinicio del
  contenedor la reinicia.

## A confirmar

- Si el NACK de la rama 422 debería registrarse en `audit_logs` como los demás (hoy no se registra).
