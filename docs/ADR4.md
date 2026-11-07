# ADR4: Implementación y persistencia de la estrategia de mercado

## Contexto
En la E2, nuestro nodo deja de transar exclusivamente con la central y comienza a comprar y vender energía directamente con otras ciudades. Necesitamos una forma de definir nuestra política comercial (cuánto vender, a qué precio, a quién comprarle, en que momento o tiempo de gracia, etc.) y poder alterar esta estrategia en vivo desde el panel de administración (frontend) sin requerir redespliegues. 

## Alternativas Consideradas
1. **Redis (cache):** 
   - *Pro:* Lectura ultrarrápida. 
   - *Contra:* Volátil. Difícil de auditar qué estrategia exacta se usó en un ciclo pasado para el "registro del experimento".
2. **Persistencia en Base de Datos Relacional (PostgreSQL):** 
   - *Pro:* Permite mantener un historial de estrategias. Podemos enlazar el ID de la estrategia activa al `negotiation-report` de cada ciclo para auditar qué configuración produjo qué resultados.
   - *Contra:* Leve latencia de lectura (milisegundos) al inicio de cada ciclo.

## Decisión
Optamos por la **Persistencia en Base de Datos Relacional (PostgreSQL)**. `MarketStrategy` almacena `sell_price_multiplier`, `max_buy_effective_price_ratio` y `span_seconds`. La configuración se versiona: actualizarla crea una nueva estrategia activa y conserva las anteriores. Al primer uso de la estrategia en un ciclo, `NegotiationStrategyService` fija el ID de esa versión en el ciclo; cambios posteriores rigen desde el próximo ciclo.

La política inicial ofrece a no menos del `buybackPrice`, con un precio objetivo de `buybackPrice × sell_price_multiplier` limitado por `imbalancePrice`. Como comprador elige la oferta con menor costo efectivo (precio más distancia por tarifa de transporte), acepta solo cantidades de al menos `minBid` y no supera `imbalancePrice × max_buy_effective_price_ratio`. En rutas deshabilitadas se usa `disabledRouteTransportCost`, sin sustituirlo por la tarifa normal.

La configuración se lee y actualiza mediante `GET /market-strategy` y `PUT /market-strategy` (o `PATCH`), con propiedades camelCase, por ejemplo `{ "marketStrategy": { "spanSeconds": 30 } }`. La API publica valores por defecto cuando aún no hay una estrategia: multiplicador vendedor 1.1, límite comprador 1.0 y span de 60 segundos. El `status-statement` fija la versión activa en el ciclo al registrarlo.

## Consecuencias
* **Positivas:** Cumplimos con el requisito de cambio dinámico y aseguramos la trazabilidad exacta de los experimentos por ciclo .
* **Negativas:** Requerirá migraciones adicionales y un endpoint CRUD para que el frontend pueda interactuar con las configuraciones.

## Análisis Postmortem

### Modificaciones y Adaptaciones durante Implementación
1. **Versionado activo en vez de historial explícito:** se agregó una versión activa y se guarda su ID en el ciclo, conservando trazabilidad sin duplicar toda la configuración anterior.
2. **Configuración vinculada al status-statement:** al registrar el ciclo se fija la estrategia, y el presentador expone sus parámetros al frontend.
3. **Métricas de experimento:** el endpoint de span usa el mismo `span_seconds`, el déficit cubierto, el costo efectivo y los bids rechazados del ciclo.

### Evaluación de Resultados
1. **Cambio dinámico sin redespliegue:** exitoso. La API permite leer y actualizar el multiplicador, el límite comprador y el span.
2. **Precios controlados:** exitoso en implementación; las rutas deshabilitadas usan su costo específico y no el costo normal.
3. **Trazabilidad:** exitoso. El ciclo conserva la estrategia usada, aunque conviene seguir probando cambios concurrentes entre el status-statement y una actualización de estrategia.