# ADR7: Consumo de dos colas y respuestas a otras ciudades

## Contexto

En la E1 el sistema consumía una sola cola (`city.TK3`) y respondía siempre a la central. El ADR1 decidió que el connector es la única puerta entre el broker y nuestro sistema: la API nunca abre una conexión al broker, para que una caída del broker no la bote. La E2 (protocolo v3) obliga a reexaminar esa decisión, porque cambia tres cosas:

1. Una segunda cola, `market.TK3`: Ahí llegan las ofertas de todas las ciudades (`offer`, `offer-updated`, `offer-withdrawn`) y el aviso `market-closed`. Son difusión: nadie los responde con `ack`.
2. Mensajes directos entre ciudades: `bid`, `bid-accepted` y `bid-rejected` viajan por `energy.x` con routing key `city.{CIUDAD}`. El `ack` o `nack` de esos mensajes va a la ciudad que los envió, no a la central.
3. Verificación de identidad en el receptor: Toda ciudad publica con la propiedad AMQP `user_id` igual a `city.{CODE}`, y la central con `user_id` `central`. Antes la central filtraba a quien se hacía pasar por otro, ahora el receptor compara `user_id` con el `cityId` y responde `nack` `IDENTITY_MISMATCH` (403) si no corresponden.

Además, una inundación de ofertas o de bids no debe frenar los mensajes de la central (`status-statement`, `transfer`, `distance-table`), que deciden el financiamiento, las multas y el costo de transporte. El curso limita a 60 las operaciones de mercado por minuto, y la cola `market.TK3` guarda a lo sumo un ciclo de mensajes (máximo 5 000, el broker descarta los más antiguos).

## Alternativas consideradas

1. **El mismo connector, con un segundo canal y consumidor para `market.TK3`:** cada cola tiene su propio canal, con confirmación manual y prefetch 1.
   - *Pro:* Reutiliza toda la resiliencia del ADR1 (reconexión, vigilancia y healthcheck). Las credenciales siguen en un solo lugar y la API sigue sin tocar el broker. Como los canales son independientes, un atasco en el mercado no frena la cola de la ciudad.
   - *Contra:* Si el proceso muere, se cortan las dos colas a la vez. Además, el connector concentra más responsabilidades (dos canales y el hilo del outbox).
2. **Un segundo contenedor de connector dedicado a `market.TK3`:**
   - *Pro:* Una falla en el consumo del mercado no afecta a la cola de la ciudad.
   - *Contra:* Duplica configuración, credenciales, monitoreo y despliegue (Sofi). Son dos procesos con el mismo usuario del broker, más difíciles de razonar. La ganancia en aislamiento es poca, porque la alternativa 1 ya separa por canal.
3. **La API consume `market.TK3` directamente:**
   - *Pro:* Un salto menos para las ofertas.
   - *Contra:* Rompe el ADR1: la API tendría una conexión al broker y una caída del broker podría botarla. La validación de mensajes quedaría repartida en dos lugares.
4. **El mismo connector, pero `market.TK3` con confirmación automática (auto-ack):** el broker borra cada mensaje apenas lo entrega.
   - *Pro:* Más simple y más rápido.
   - *Contra:* Si la API está caída, la oferta se pierde sin reintento y el libro de ofertas queda incompleto. Rompe la regla del ADR1 de confirmar al broker solo después de guardar.

## Decisión

Se opta por la Alternativa 1. El connector sigue siendo la única puerta: abre un canal y un consumidor por cola, ambos con confirmación manual y prefetch 1. Los mensajes de `market.TK3` se confirman al broker (para sacarlos de la cola), pero nunca se responden con `ack` del protocolo. Las respuestas a mensajes de otras ciudades van a `city.{esa ciudad}`. Lo que la API quiere enviar a otra ciudad o al mercado pasa por el outbox del ADR1, que ahora guarda el destino (exchange y routing key).

## Justificación

- **La cola de la central no espera al mercado:** con un canal por cola, cada consumidor procesa su propia fila de mensajes, así que una ráfaga de ofertas no retrasa un `status-statement`.
- **Se mantiene el aislamiento del ADR1:** la API sigue sin conexión al broker, y una caída del broker solo afecta al connector.
- **Cero pérdida de mensajes en las dos colas:** igual que en el ADR1, un mensaje solo se confirma al broker después de que la API lo guardó. Si la API está caída, la oferta espera en la cola en vez de perderse, que es lo que descarta la alternativa 4.
- **Identidad verificada en la frontera:** el connector compara `user_id` con `cityId` antes de entregar el mensaje a la API. Ante un `user_id` que no corresponde, responde `nack` `IDENTITY_MISMATCH` a la ciudad que realmente envió (la del `user_id`). Un mensaje que dice venir de la central sin `user_id` `central` se descarta sin respuesta, como indica el contrato v3.0.2.
- **Respeto al límite del curso:** el connector publica a lo sumo 50 mensajes por minuto a otras ciudades o al mercado, para dejar margen bajo el límite de 60. Superarlo, o inundar de bids, puede significar un bloqueo.

## Consecuencias

- **Positivas:** Una sola pieza que operar y defender, con las mismas tácticas de disponibilidad del ADR1. La cola de la central no se frena por el tráfico del mercado, y la regla de confirmar después de guardar se mantiene en las dos colas.
- **Negativas:** El connector se vuelve más complejo. Si la API está caída por más de un ciclo, el broker descarta ofertas viejas de `market.TK3`, es aceptable, porque una oferta de un ciclo pasado ya no sirve. Queda un riesgo abierto: si el broker real rechaza por permisos una publicación a otra ciudad o al mercado, cierra el canal, y la vigilancia del ADR1 reiniciaría el contenedor con el mismo mensaje pendiente. Se mitigará reabriendo solo el canal del outbox y marcando ese mensaje como fallido.

- Logs del connector con los dos consumidores activos y su recuperación tras un corte del broker.
- El `ack` de un `bid` real enviado a `city.{otra ciudad}`, visible en el log y en la auditoría.
- Ningún `nack` `UNKNOWN_TYPE` a mensajes v3 válidos durante el período de evaluación.
- Ningún bloqueo por superar el límite de operaciones de mercado.
