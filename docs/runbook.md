# Runbook Operacional - EnergyShark E3 (RDOC04)

## 1. Alerta: Wallet Lenta (`WALLET_SLOW`)
* **Qué significa:** El tiempo de respuesta (p95) de las llamadas HTTP hacia la wallet externa (`POST /transfer`, `GET /balance`) superó el umbral de ~2.5s–3.0s, poniendo en riesgo el timeout de los pasos de reserva y pago dentro de las sagas.
* **Dónde mirar primero:**
  1. Dashboard de observabilidad (panel de latencia externa / spans hacia wallet).
  2. Logs estructurados del backend filtrando por `cycleId` y `swapId` para identificar si la demora ocurre en la reserva inicial o en el pago final (`202 Accepted`).
* **Primera acción de mitigación:**
  1. Verificar en la consola de AWS Step Functions si las ejecuciones afectadas están reintentando automáticamente con backoff exponencial.
  2. Si la degradación persiste, ajustar en caliente el parámetro `spanSeconds` desde `/control` (RF04) para dar mayor margen antes del cierre del ciclo y evitar acumulación de bids tardíos.

---

## 2. Alerta: Consumidor Detenido (`CONSUMER_STOPPED`)
* **Qué significa:** El servicio `connector` dejó de procesar mensajes de las colas `city.{CODE}` y `market.{CODE}` durante una ventana de 20 minutos (1 ciclo completo) o perdió la conexión AMQP con el broker.
* **Dónde mirar primero:**
  1. Estado del contenedor en EC2 (`docker compose ps`) y logs del contenedor (`docker compose logs --tail=100 connector`).
  2. Pestaña **Auditoría (RF05)** en el frontend para descartar un bloqueo por mensajes malformados o `IDENTITY_MISMATCH` repetidos.
* **Primera acción de mitigación:**
  1. Reiniciar el contenedor del consumidor (`docker compose restart connector`) y confirmar en los logs que reconecta a RabbitMQ sin perder mensajes (los mensajes durables permanecen en cola).
  2. Verificar que la API `master` siga respondiendo con normalidad mientras el consumidor retoma la lectura.

---

## 3. Alerta: Ledger Desviado (`LEDGER_DRIFT`)
* **Qué significa:** Al cierre del ciclo, el balance registrado en la base de datos local de la ciudad no coincide (`abs(delta) > 0`) con el saldo real reportado por `GET /balance` en la wallet externa.
* **Dónde mirar primero:**
  1. Logs de reconciliación filtrando por `cycleId` para identificar qué `swapId` o `idpk` generó la diferencia.
  2. Consola de AWS Step Functions buscando ejecuciones del `cycleId` que hayan terminado en estado `FAILED` o con compensación incompleta.
  3. Pestaña **Auditoría (RF05)** para verificar que ningún mensaje duplicado (`idpk`) haya mutado dos veces el estado.
* **Primera acción de mitigación:**
  1. Ejecutar el proceso/endpoint de reconciliación contra `GET /balance` para sincronizar el saldo local con la fuente de verdad de la wallet antes de emitir el `negotiation-report`.
  2. Si hay una compensación pendiente en Step Functions, verificar el estado del `transfer` en la wallet para evitar doble reembolso.

---

## 4. Alerta: Saga Atascada o Fallando (`SAGA_STUCK_FAILED`)
* **Qué significa:** Una o más máquinas de estado en AWS Step Functions fallaron (`ExecutionsFailed > 0`) o siguen en estado `RUNNING` más de 60 segundos después del `closesAt` del ciclo.
* **Dónde mirar primero:**
  1. Consola de **AWS Step Functions** $\rightarrow$ filtrar ejecuciones por estado `Failed` o `Running` y abrir el grafo visual de estados.
  2. Copiar el `swapId` / `cycleId` / `idpk` del input de la ejecución y buscar la traza exacta en los logs estructurados del backend (`StructuredLogger`).
* **Primera acción de mitigación:**
  1. Distinguir si el fallo es un rechazo normal de negocio (ej. `SWAP_NOT_PROPOSED` en el comprador) o un error técnico de integración/timeout.
  2. Si quedó una reserva bloqueada sin completar el pago, verificar que la rama de compensación (`CompensateReservation`) se haya ejecutado correctamente; de lo contrario, liberar la reserva manualmente o mediante reintento idempotente con el mismo `idpk`.

---

## 5. Alerta: Outbox con Atraso (`OUTBOX_BACKLOG`)
* **Qué significa:** Existen mensajes pendientes en la tabla `outbox` que llevan más de 30–45 segundos sin poder publicarse hacia RabbitMQ o Step Functions (superando la meta de recuperación de ≤ 60s).
* **Dónde mirar primero:**
  1. Tabla `outbox` en PostgreSQL (consultar registros con estado `pending` ordenados por `created_at ASC`) usando `cycleId` e `idpk`.
  2. Logs del worker despachador del outbox y conectividad de red hacia el broker AMQP / AWS Step Functions.
* **Primera acción de mitigación:**
  1. Si el atraso se debe a un microcorte del broker o throttling de AWS, confirmar que el worker de outbox esté activo y reintentando en batch con backoff.
  2. Si el worker se detuvo, reiniciar el servicio correspondiente (`docker compose restart master1 master2` o worker) para drenar la cola pendiente respetando la clave de idempotencia `idpk`.