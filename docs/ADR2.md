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