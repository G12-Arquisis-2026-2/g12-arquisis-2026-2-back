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
Optamos por la **Persistencia en Base de Datos Relacional (PostgreSQL)**. Crearemos un modelo `MarketStrategy` que almacene parámetros configurables como `buy_policy`, `sell_policy`, `span_seconds`, `acceptance_criteria`. El frontend actualizará la estrategia insertando un nuevo registro y marcándolo como "activo". Al inicio de cada ciclo, el sistema consultará la estrategia activa y guardará su ID en los logs del ciclo.

## Consecuencias
* **Positivas:** Cumplimos con el requisito de cambio dinámico y aseguramos la trazabilidad exacta de los experimentos por ciclo .
* **Negativas:** Requerirá migraciones adicionales y un endpoint CRUD para que el frontend pueda interactuar con las configuraciones.