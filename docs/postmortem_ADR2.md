## Postmortem: ADR2 - Persistencia del Ledger (Event Log sobre PostgreSQL)

### 1. Contexto de la Decisión
Para la Entrega 1, decidimos implementar el Ledger financiero y energético utilizando un patrón de *Event Log* (agregación en tiempo de lectura mediante `SUM()`) sobre una base de datos relacional (PostgreSQL), descartando el uso de *Snapshots* mutables o bases de datos NoSQL.

### 2. Qué funcionó bien (Éxitos)
* **Idempotencia garantizada por el motor:** Delegar la responsabilidad de la unicidad del `idpk` a un índice único a nivel de motor de base de datos (PostgreSQL) demostró ser la decisión más segura. Ningún mensaje duplicado logró alterar los balances reales.
* **Cálculo de balances sin cuellos de botella:** La agregación de (`Transaction.where(cycle_id: x).sum(:energy_change)`) funcionó a la perfección. Al ser un *append-only log* (solo inserciones), evitamos bloqueos de escritura por concurrencia que habríamos tenido si actualizáramos un único registro mutable.
* **Auditoría:** Al tener una base relacional y transaccional, pudimos capturar el error nativo del motor (`ActiveRecord::RecordNotUnique`) y desviar el flujo hacia la tabla `audit_logs` sin afectar el estado general del sistema.

### 3. Qué no funcionó tan bien o requirió ajustes (Lecciones Aprendidas)
* **Manejo de Transacciones en Rails:** En la práctica, descubrimos que cuando PostgreSQL lanza un error de restricción de unicidad, aborta toda la transacción actual. Tuvimos que ajustar nuestro `LedgerProcessorService` para utilizar `Transaction.transaction(requires_new: true)`. Sin esto, no podíamos rescatar la excepción y escribir en el `AuditLog` en la misma llamada.
* **Flexibilidad del Payload:** Al principio, el diseño estricto chocó con la realidad del protocolo (el Connector enviaba a veces `quantity` y otras veces estructuras anidadas en `balance`). El servicio del Ledger tuvo que ser flexibilizado para asimilar ambas formas antes de insertar en la base de datos.

### 4. Conclusión y Veredicto
La decisión arquitectónica de usar SQL y un modelo *Event Log* fue **correcta y se mantiene**. La rigidez estructural de PostgreSQL y sus garantías ACID fueron fundamentales para cumplir con las reglas de negocio de la Entrega 1 sin tener que escribir código complejo para manejar concurrencia. La base de datos actuó como nuestra barrera definitiva contra la contaminación de datos.