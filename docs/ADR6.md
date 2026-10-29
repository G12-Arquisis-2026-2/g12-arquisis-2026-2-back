# AD6: Manejo de concurrencia al aceptar bids de múltiples ciudades

## Contexto
Cuando publicamos una oferta en el canal `market`, múltiples ciudades pueden estar interesadas y enviarnos un `bid` de compra casi al mismo tiempo a nuestra cola `city.{CODE}`. Si recibimos dos bids de 5,000 kWh, pero solo tenemos 6,000 kWh disponibles, y procesamos ambos bids en paralelo, podríamos aceptar ambos. Esto llevaría a la Wallet a rechazar el segundo swap por `INSUFFICIENT_ASSET`, dejándonos en una mala posición y perdiendo tiempo valioso del ciclo (60 segundos retenidos). 

## Decisiones Consideradas
1. **Delegar a la Wallet:**
   - *Pro:* Código más simple. Disparamos todos los `accept` y dejamos que la Central falle el segundo.
   - *Contra:* Retiene créditos innecesariamente, genera errores en cascada y una mala reputación/ineficiencia en nuestro nodo al prometer energía que no tenemos.
2. **Bloqueo distribuido (Redis Lock / Redlock):**
   - *Pro:* Alta performance para encolar o bloquear bids concurrentes.
   - *Contra:* Añade Redis como dependencia estricta para persistencia/candados, complicando la infraestructura (Sofi).
3. **Bloqueo Pesimista en Base de Datos (Row-level lock / FOR UPDATE):**
   - *Pro:* Utiliza PostgreSQL que ya tenemos configurado. Un `transaction` con `lock!` asegura que los bids se procesen estrictamente en serie, descontando la energía disponible de forma segura.
   - *Contra:* Puede ralentizar la base de datos si hay una inundación de mensajes.

## Decisión
Optamos por el **Bloqueo Pesimista en Base de Datos (Row-level lock)**. Dado que la E2 establece un límite de 60 operaciones por minuto, el volumen de mensajes no es lo suficientemente alto como para ahogar a PostgreSQL. Al recibir un bid, el worker iniciará una transacción, bloqueará la fila correspondiente al balance del ciclo actual (`CYCLE_BALANCE_ROW.lock!`), evaluará si queda capacidad disponible, descontará el monto localmente y procederá a generar el swap.

## Consecuencias
* **Positivas:** Protege la integridad de nuestra energía vendible sin necesidad de añadir infraestructura externa. Evitamos el error 409 `OVER_CAPACITY`.
* **Negativas:** Los workers concurrentes de RabbitMQ podrían quedarse esperando el lock de la base de datos por unos milisegundos, lo que incrementa ligeramente el tiempo promedio de respuesta del consumidor AMQP.