# ADR3: Manejo de timeouts de negociación

## Contexto
Las propuestas voluntarias (negotiation-proposal) exigen recibir confirmación y transferencia en menos de 30 segundos. Tras este plazo, el sistema debe reintentar con el mismo idpk asegurando que una respuesta tardía no impacte el ledger dos veces.

## Alternativas consideradas
1. **Espera síncrona (sleep 30):** Bloquear el proceso emisor 30 segundos y reintentar si no hay respuesta.
2. **Scheduler asíncrono con máquina de estados en BD:** Registrar ofertas en estado PENDING y usar un worker asíncrono para reintentar con el mismo idpk las vencidas.

## Decisión
Se opta por la Alternativa 2 (Scheduler asíncrono con máquina de estados).

## Justificación
1. **Sin bloqueos:** Mantiene libre a la API y al consumidor de eventos sin congelar hilos de ejecución.
2. **Garantía de idempotencia:** La restricción UNIQUE sobre idpk en la base de datos (ADR2) descarta cobros o abonos duplicados si la respuesta llega desfasada.
3. **Resiliencia ante reinicios:** Si el servicio cae durante la espera, la BD preserva el estado para reanudar reintentos al revivir el contenedor.

## Consecuencias
* **Positivas:** Evita el doble gasto en el ledger, maximiza el rendimiento asíncrono y tolera caídas.
* **Negativas:** Añade la complejidad de gestionar tareas programadas (schedulers) en segundo plano.