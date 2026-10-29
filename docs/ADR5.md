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