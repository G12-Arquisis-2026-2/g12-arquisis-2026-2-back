# AD5: Resiliencia del Cliente HTTP y manejo de Idempotencia con la Wallet

## Contexto
La Wallet de la Central es intencionalmente lenta, inestable (devuelve errores 502/504 o 503) y procesa todo de forma asíncrona. Una escritura (POST `/swaps`) solo devuelve 202 Accepted, y el resultado llega como un evento AMQP. Si se pierde una petición HTTP en tránsito, debemos reintentar con la **misma** `Idempotency-Key`; de lo contrario, arriesgamos duplicar la compra o venta de energía.

## Alternativas Consideradas
1. **Generar el UUID en memoria al momento del request:**
   - *Pro:* Rápido y sin uso de base de datos.
   - *Contra:* Si el pod/contenedor de Rails muere justo durante un timeout HTTP, perdemos el UUID. Al reiniciar el worker, se creará un UUID nuevo y duplicaremos la transacción.
2. **Generar y persistir la `Idempotency-Key` en Base de Datos antes de enviar:**
   - *Pro:* Garantiza que si el request falla por red (timeout) o el contenedor se reinicia, el job de fondo (Sidekiq/ActiveJob) puede recuperar el mismo UUID desde la DB y reintentar.
   - *Contra:* Añade complejidad al flujo; requiere crear un registro "pendiente" antes de hablar con la API externa.

## Decisión
Optamos por **Generar y persistir la `Idempotency-Key` en Base de Datos**. Introduciremos un modelo `SwapIntention` (o tabla de auditoría de transacciones). Antes de hacer cualquier POST a `/swaps`, crearemos un registro local con el `idpk` (UUID), la intención (give/take), y el estado "pending". El cliente HTTP (Faraday o Net::HTTP) usará siempre este `idpk`. Los reintentos por 503 o timeouts simplemente recargarán el registro de `SwapIntention` y volverán a disparar la petición HTTP.

## Consecuencias
* **Positivas:** Prevención total de transacciones financieras duplicadas, crucial para no quedar con balance negativo no deseado.
* **Negativas:** Desacopla la lógica de negocio; el ledger interno queda en un estado temporal "retenido" que debe ser limpiado/conciliado posteriormente usando los eventos `swap-settled` o `swap-rejected` recibidos por RabbitMQ.

## Análisis Postmortem

### Modificaciones y Adaptaciones durante Implementación
1. **Intención persistida antes del POST:** los jobs crean `SwapIntention` con `idpk`, montos, vencimiento y estado pending, reutilizando el mismo valor en HTTP y reintentos.
2. **HTTP transitorio y 429:** `WalletClient` conserva la Idempotency-Key, respeta `Retry-After` y encola `WalletRetryJob` sin generar una clave nueva.
3. **Reconciliación por ciclo:** el job separa CR y KWH, suma available + held y persiste ambos deltas junto con la fecha de conciliación.
4. **Eventos fuera de orden:** el servicio de mercado localiza una intención por `idpk` o `swap_id`; si no existe, crea una fila mínima para no perder resoluciones adelantadas.
5. **Estados terminales:** el worker impide volver de settled/rejected/cancelled/expired a pending.

### Evaluación de Resultados
1. **Idempotencia:** exitoso. La clave persiste entre timeouts, reintentos y reinicios del proceso.
2. **Rate limiting:** exitoso en código; el delay de 429 se deriva de la respuesta HTTP sin cambiar la operación ni la clave.
3. **Conciliación:** exitoso con una dependencia crítica: cada intención debe quedar asociada a su ciclo para filtrar correctamente los swaps settled.
4. **Orden de eventos:** exitoso parcialmente. Las resoluciones adelantadas pueden crear o completar la intención, pero los montos pueden quedar incompletos si el evento de resolución no los incluye.
5. **Cleanup:** exitoso. El job reutiliza una clave de cancelación persistida en vez de crear otra en cada minuto.