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

## Análisis Postmortem

### Modificaciones y Adaptaciones durante Implementación
1. **Validación alineada con los schemas oficiales:** La decisión no decía contra qué se validaba. En la práctica, el validador se ajustó a los schemas del curso (energyshark-contracts v3.0.2), que mandan cuando hay diferencias con el texto. Eso corrigió el error de la demo de la E1: un `distance-table` sin `cycleId` recibía `ack` y ahora recibe `nack` `MALFORMED_MESSAGE`. Se mantuvo el principio de lector tolerante: se exigen los campos obligatorios, pero los campos extra se ignoran, aunque los mensajes de la central sean cerrados en el schema.
2. **Reglas de identidad más finas:** Además de comparar `user_id` con `cityId`, un mensaje de ciudad sin `user_id` también recibe `IDENTITY_MISMATCH`, y un mensaje que dice venir de la central sin `user_id` `central` se descarta sin respuesta, como indica el contrato v3.0.2. Las ofertas solo se aceptan si llegan por `market.offer.{su cityId}`, y `market-closed` solo por `market.closed`, para que otra ciudad no pueda cerrarnos el mercado con un mensaje falso.
3. **Riesgo abierto mitigado:** El ADR dejaba como riesgo que un rechazo de permisos del broker cerrara el canal del outbox y reiniciara el contenedor. Se implementó la mitigación: el mensaje queda fallido con el motivo del broker, se abre un canal nuevo y se sigue. La vigilancia ahora solo termina el proceso por los canales de consumo (city y market).
4. **Anomalías de la demo sobre las dos colas:** Se agregaron dos comportamientos que el ADR no describía. Tras una reconexión, el connector republica la oferta vigente del ciclo con el mismo `idpk` (anomalía 5). Ante un bid repetido, el outbox reenvía la misma respuesta (`bid-accepted` o `bid-rejected`) con el mismo `idpk` (anomalía 1).
5. **Límite más estricto que el del curso:** El tope de 50 por minuto cuenta ofertas, bids y respuestas a otras ciudades. El `marketOpsPerMinute` del curso cuenta solo ofertas. Se dejó más estricto a propósito, para no arriesgar un bloqueo.
6. **Contract tests:** Para comprobar que lo que publicamos cumple el contrato, se agregó un workflow de CI que genera los mensajes con nuestro propio código y los valida con el validador oficial del curso.

### Evaluación de Resultados
1. **La cola de la central no espera al mercado:** Parcial. Cada cola tiene su propio canal y su propio consumidor, cubierto por tests. No se midió con una ráfaga real de ofertas. Queda un caso que sí frena la cola de la ciudad: si la API responde 500 de forma repetida para un mensaje (por ejemplo, un `swap-proposed` con token inválido), el connector reintenta hasta 4 veces antes de descartarlo y, con prefetch 1, la cola espera unos 65 segundos.
2. **Se mantiene el aislamiento del ADR1:** Exitoso en pruebas locales. Con un RabbitMQ de prueba, después de `docker restart` del broker, los dos consumidores (`city.TK3` y `market.TK3`) volvieron solos, sin reiniciar el contenedor del connector. Si la cola del mercado no existe, el connector sigue consumiendo la de la ciudad. La API no tiene conexión al broker.
3. **Cero pérdida de mensajes en las dos colas:** Parcial. Las dos colas usan confirmación manual y prefetch 1, y un mensaje solo se confirma al broker después de que la API lo guardó; está cubierto por tests. Se mantienen las dos excepciones conocidas: el descarte tras 4 errores 500 (ADR1) y las ofertas de más de un ciclo, que el broker descarta por TTL.
4. **Identidad verificada en la frontera:** Exitoso en pruebas locales. Un bid de HGW con su `user_id` recibió `ack` en `city.HGW`. Un mensaje de HGW que decía venir de MET recibió `nack` `IDENTITY_MISMATCH` en `city.HGW`, la ciudad que realmente lo publicó. Un `market-closed` enviado por `market.offer.HGW` se descartó.
5. **Respuestas a la ciudad que envió, con el formato del curso:** Exitoso en pruebas locales y en CI. Los ack y nack a otras ciudades salieron con routing key `city.{CIUDAD}` y `user_id` `city.TK3`. Los 12 mensajes que genera nuestro código (ack y nack hacia la central y hacia otra ciudad, bid, bid-accepted, bid-rejected y las tres ofertas) validan contra los schemas oficiales v3.0.2. Además, los 140 ejemplos oficiales del curso pasan por nuestro validador como tests.
6. **Mitigación del riesgo abierto:** Exitoso en pruebas locales. El broker de prueba rechazó una oferta con `ACCESS_REFUSED`. El mensaje quedó fallido con ese motivo, el canal del outbox se reabrió y el mensaje siguiente salió, sin reiniciar el contenedor.
7. **Respeto al límite del curso:** Parcial. El tope de 50 por minuto está cubierto por tests con un reloj simulado, pero no se midió contra el broker real.
