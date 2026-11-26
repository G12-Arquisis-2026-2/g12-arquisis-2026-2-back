# ADR8: Publicación confiable con outbox
 
## Contexto
 
Nuestro nodo hace muchas veces la misma jugada: cambia algo en PostgreSQL y después publica un mensaje. Son dos escrituras a dos sistemas distintos y no existe una transacción que cubra a los dos: si el contenedor se cae o se corta el broker entre una y otra, el cambio queda guardado y el mensaje se pierde. En la E3 esto importa en tres lugares: el `negotiation-report` (perderlo cuesta 50 000 créditos), los mensajes de nuestra oferta (si se pierde un `offer-updated`, el mercado ve cantidad que ya no existe) y el inicio de las sagas de AD7 (registrar el bid y llamar a `StartExecution` es la misma doble escritura, ahora contra AWS).
 
Desde la E1 tenemos una tabla `outbox_messages` y un relay en el connector (ADR1: la API nunca abre una conexión al broker). Un diagnóstico del código encontró que eso cumple solo en parte:
 
- El envelope se guarda completo, con `msgId` e `idpk` generados al escribir, y el relay ya usa *publisher confirms*: solo marca una fila como enviada cuando el broker la confirmó.
- 5 de las 12 escrituras al outbox que acompañan un cambio de estado quedan **fuera** de la transacción de ese cambio (las ofertas y el bid en `market_cycle_job.rb`, y un rechazo y una liberación en `sell_market_bid_job.rb`). En una, el bid se publica antes de crear su registro.
- El relay no reserva filas: si corrieran dos, publicarían las mismas.
- No existe el inicio de sagas por el outbox ni ninguna métrica del atraso.
- La republicación de la oferta tras una reconexión sale de la memoria del connector, no de la tabla.
## Fuerzas
 
- **Ningún mensaje comprometido se pierde ni se inventa:** si el cambio de estado quedó, su mensaje sale; si no quedó, no sale.
- **Única puerta al broker (ADR1):** una caída del broker no debe botar la API.
- **Al menos una vez es aceptable:** todos los receptores deduplican por `idpk`, y Step Functions no crea dos ejecuciones con el mismo nombre.
- **Medida del enunciado:** el atraso del outbox (edad de la fila pendiente más antigua) vuelve a cero en 60 segundos o menos tras una recuperación, y si el nodo vuelve antes de `validUntil`, el `negotiation-report` sale dentro de la ventana.
- **Límites del curso:** 60 operaciones de mercado por minuto; el abuso puede significar un bloqueo.
- **Migración con el nodo en operación:** un ciclo sin reporte cuesta 50 000 créditos, así que el cambio tiene que poder apagarse.
## Alternativas consideradas
 
1. **Reforzar el outbox actual, con un solo relay en el connector que también inicia las sagas:** toda escritura al outbox exige una transacción abierta; el relay reserva las filas antes de publicarlas; la tabla gana un segundo tipo de destino (Step Functions) y el mismo relay hace `StartExecution`.
   - *Pro:* Reutiliza lo que ya funciona (confirms, reconexión, vigilancia, tope por minuto). Una sola tabla, un solo relay y una sola métrica de atraso: lo más simple de operar y de explicar. La API sigue sin tocar el broker.
   - *Contra:* El connector agrega una dependencia de AWS (el SDK de Step Functions) y necesita el permiso `states:StartExecution` en el rol de la EC2.
2. **Dos relays: el connector publica al broker y un job de Rails inicia las sagas.**
   - *Pro:* El connector sigue siendo solo de mensajería. Rails ya va a usar el SDK de AWS para `SendTaskSuccess`.
   - *Contra:* Dos procesos leyendo la misma tabla obligan a reservar filas sí o sí, y quedan dos métricas de atraso y dos lugares donde mirar en un incidente.
3. **Relay dentro de Rails para todo (un job que lee la tabla y publica al broker).**
   - *Pro:* Menos saltos HTTP entre la API y el connector.
   - *Contra:* Rompe el ADR1: la API tendría una conexión al broker y una caída del broker podría botarla. Habría que duplicar en Rails la reconexión y los confirms que ya tiene el connector.
4. **Captura de cambios desde el registro de PostgreSQL (CDC, por ejemplo Debezium):** un proceso lee el log de la base y publica cada cambio.
   - *Pro:* No depende de que el código escriba bien en el outbox: todo cambio se ve.
   - *Contra:* Infraestructura pesada (otro servicio, configuración de replicación) para un equipo chico y a días de la entrega; los mensajes igual hay que armarlos en algún lado.
5. **Sin outbox: publicar después del commit, con reintentos.**
   - *Pro:* Lo más simple.
   - *Contra:* No cubre el caso que pide el enunciado: si el proceso muere entre el commit y la publicación, no queda nada que reintentar.
## Decisión
 
Se opta por la Alternativa 1.
 
**Qué pasa por el outbox:**
- El `negotiation-report` y los `request` a la central.
- Los mensajes de nuestra oferta: `offer`, `offer-updated` y `offer-withdrawn`, incluido el `offer-updated` de la compensación de una saga.
- Los `bid` que envía nuestra estrategia.
- El inicio de las sagas: una fila con destino Step Functions, la máquina (vendedor o comprador), la entrada y el **`idpk` como nombre de la ejecución** (el del `bid` para el vendedor, el del `bid-accepted` para el comprador).
- La republicación de la oferta tras una reconexión se hace desde la última fila de oferta enviada, no desde la memoria del connector, para que sobreviva a un reinicio.
**Qué no pasa por el outbox:**
- Los `ack` y `nack` que el connector responde a un mensaje recibido. Su registro durable es la cola: el connector confirma al broker solo después de responder, así que si se cae antes, el broker reentrega el mensaje y se vuelve a responder.
- Los mensajes que publica una tarea de la saga (por ejemplo `bid-accepted`). Su registro durable es la ejecución, que reintenta la tarea; la tarea usa el mismo `idpk` en cada intento.
**Cómo opera:**
1. **Escritura:** `RabbitMQPublisher` falla si no hay una transacción abierta, así que el mensaje queda en la misma transacción que el cambio de estado. O quedan los dos, o ninguno.
2. **Reserva:** el relay pide las filas a la API con una reserva (`FOR UPDATE SKIP LOCKED` y un plazo de unos 30 segundos). Una fila reservada no la toma otro relay; si el relay muere, el plazo vence y la fila vuelve a estar disponible.
3. **Publicación:** se publica el payload guardado tal cual (mismo `msgId` e `idpk`). Al broker, con *publisher confirms* y un tiempo máximo de espera; a Step Functions, con `StartExecution`, donde `ExecutionAlreadyExists` cuenta como éxito.
4. **Marcado:** la fila pasa a `sent` solo con la confirmación del broker o la respuesta de Step Functions. Si el relay se cae antes de marcar, la fila se publica de nuevo (al menos una vez).
5. **Prioridad y límite:** los mensajes a la central no tienen tope; los de mercado y otras ciudades respetan el tope de 50 por minuto.
6. **Atraso:** cada 15 segundos se envía a New Relic la edad de la fila pendiente más antigua, que usa la alerta "Outbox con atraso".
7. **Interruptor:** la reserva y el inicio de sagas van detrás de un feature flag, para volver al relay actual en un ciclo si algo falla.
## Justificación
 
- **Cero cambios de estado sin su mensaje:** al exigir una transacción abierta, el código no puede escribir el cambio sin su mensaje, ni el mensaje sin su cambio.
- **Ninguno se pierde:** la fila sobrevive a una caída del backend o del broker, y el relay la publica al volver.
- **Ninguno se inventa ni se duplica en sus efectos:** un reenvío es el mismo mensaje con el mismo `idpk`; los receptores lo deduplican y Step Functions no abre una segunda ejecución con el mismo nombre.
- **Se mantiene el ADR1:** la API sigue sin conexión al broker.
- **Se mide:** la edad de la fila más antigua dice en todo momento si algo anda mal entre el nodo y el broker.
## Consecuencias
 
- **Positivas:** Una sola pieza que publica todo lo que el nodo decidió decir, con un registro ordenado que además sirve de fuente para el feed del panel (RF01). La migración puede apagarse con un flag.
- **Negativas:** El connector depende del SDK de AWS y de un permiso en el rol de la EC2. Cada mensaje hace un salto HTTP extra (la reserva). Si se acumulan más de 50 mensajes de mercado, el atraso de esos mensajes puede superar 60 segundos por el tope por minuto; los mensajes a la central no se ven afectados.
- **Riesgo:** si el nodo vuelve en el último minuto antes de `validUntil`, el reporte puede no alcanzar a salir (no se encola con menos de 30 s y se descarta con menos de 5 s). Se medirá en la prueba de caída.
## Cómo se va a medir
 
- **Cero cambios sin mensaje:** tests que fuerzan un error dentro de la transacción y comprueban que no quedan ni el cambio ni la fila, y una consulta que compara ofertas y reportes con sus filas.
- **Atraso a cero en 60 s o menos:** prueba de caída (detener el backend justo después de un commit y cortar el broker a mitad de mercado), con el gráfico de la métrica en New Relic como evidencia.
- **Reporte dentro de la ventana:** la misma prueba durante el periodo de cierre.