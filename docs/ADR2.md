# ADR2: Persistencia del Ledger y modelo de datos

## Contexto
Se debe almacenar el estado financiero y energético de la ciudad de forma segura. El estado del ledger de cualquier ciclo pasado debe ser auditable, reconstruible, explicable y que los mensajes duplicados no alteren los saldos dos veces.

## Alternativas consideradas
1. **Modelo de Snapshot:** Mantener una tabla con el saldo actual y sobreescribir valores de energia y saldo acorde vayan llegando.
2. **Modelo Event logs:** Almacenar un registro de cada transacción individual usando una base de datos relacional (PostgreSQL) y no sobreescribir nada.

## Decisión
Se opta por la opción 2, Event Logs en base de datos relacional.

## Justificación
1. **Construcción de datos:** : Al guardar las transacciones como eventos inmutables, el balance final de un ciclo no es un número sobrescrito, sino el resultado de sumar matemáticamente todas las entradas y salidas de ese ciclo. Esto cumple la propiedad exigida de poder explicar con exactitud cómo se llegó a cualquier estado pasado.
2. **Control estricto con ID:** Las bases de datos SQL permiten establecer la columna idpk con una restricción de unicidad (UNIQUE CONSTRAINT). Si el broker reenvía un mensaje (reintento) o hay un problema de concurrencia, la base de datos rechazará automáticamente la el idpk duplicado, evitando el doble gasto y sirviendo de base para la tabla de auditoría y control.

## Consecuencias

* **Positivas:** Trazabilidad absoluta, protección nativa contra transacciones duplicadas a nivel de motor de datos, y cumplimiento estricto de corrección de arquitectura.
* **Negativas:** Mayor complejidad en las consultas de lectura, ya que el backend deberá ejecutar operaciones matemáticas cada vez que necesite conocer el balance actual para validar si existe capacidad de venta.

## Análisis Postmortem

### 1. Contexto de la Decisión
Para la Entrega 1, decidimos implementar el Ledger financiero y energético utilizando un patrón de *Event Log* (agregación en tiempo de lectura mediante `SUM()`) sobre una base de datos relacional (PostgreSQL), descartando el uso de *Snapshots* mutables o bases de datos NoSQL.

### 2. Éxitos
* **Idempotencia garantizada por el motor:** Delegar la responsabilidad de la unicidad del `idpk` a un índice único a nivel de motor de base de datos (PostgreSQL) demostró ser la decisión más segura. Ningún mensaje duplicado logró alterar los balances reales.
* **Cálculo de balances sin cuellos de botella:** La agregación de (`Transaction.where(cycle_id: x).sum(:energy_change)`) funcionó a la perfección. Al ser un *append-only log* (solo inserciones), evitamos bloqueos de escritura por concurrencia que habríamos tenido si actualizáramos un único registro mutable.
* **Auditoría:** Al tener una base relacional y transaccional, pudimos capturar el error nativo del motor (`ActiveRecord::RecordNotUnique`) y desviar el flujo hacia la tabla `audit_logs` sin afectar el estado general del sistema.

### 3. Qué requirió ajustes
* **Manejo de Transacciones en Rails:** En la práctica, descubrimos que cuando PostgreSQL lanza un error de restricción de unicidad, aborta toda la transacción actual. Tuvimos que ajustar nuestro `LedgerProcessorService` para utilizar `Transaction.transaction(requires_new: true)`. Sin esto, no podíamos rescatar la excepción y escribir en el `AuditLog` en la misma llamada.
* **Flexibilidad del Payload:** Al principio, el diseño estricto chocó con la realidad del protocolo (el Connector enviaba a veces `quantity` y otras veces estructuras anidadas en `balance`). El servicio del Ledger tuvo que ser flexibilizado para asimilar ambas formas antes de insertar en la base de datos.

### 4. Conclusión y resultados
La decisión arquitectónica de usar SQL y un modelo *Event Log* fue **correcta y se mantiene**. La rigidez estructural de PostgreSQL y sus garantías ACID fueron fundamentales para cumplir con las reglas de negocio de la Entrega 1 sin tener que escribir código complejo para manejar concurrencia. La base de datos actuó como nuestra barrera definitiva contra la contaminación de datos.