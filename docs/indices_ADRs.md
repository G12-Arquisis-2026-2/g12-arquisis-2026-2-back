# Índice de decisiones de arquitectura

Los archivos ADR se numeran en el orden en que se escribieron, que no coincide con la numeración de las decisiones del enunciado. Esta tabla hace la correspondencia. Los archivos no se renombraron, para conservar en el historial el orden entre cada ADR y su implementación (RDOC01).

## Decisiones de la E2

| Decisión del enunciado | Archivo | Mecanismo elegido | Commit del ADR |
| --- | --- | --- | --- |
| AD4: serialización de la aceptación | [ADR6](ADR6.md) | Lock pesimista en PostgreSQL: los bids de una oferta se aceptan en serie | 5809bb0 (2026-10-29) |
| AD5: consistencia entre el ledger local y la wallet | [ADR5](ADR5.md) | Idempotency-Key persistida antes de cada escritura a la wallet | 5809bb0 (2026-10-29) |
| AD6: estrategia como configuración | [ADR4](ADR4.md) | Estrategia versionada en PostgreSQL (MarketStrategy); se lee al inicio de cada ciclo y su ID queda registrado | 5809bb0 (2026-10-29) |

## Re-examen de las decisiones de la E1

| Decisión | Archivo | Qué cambió en la E2 | Commit |
| --- | --- | --- | --- |
| AD1: consumo de mensajes | [ADR1](ADR1.md) (E1) y [ADR7](ADR7.md) (E2) | Dos colas (city.TK3.q y market.TK3) en el mismo connector, un canal por cola, y respuestas a otras ciudades | 2c4a107 (E1), 5d7603c (2026-11-04) |
| AD2: ledger local | [ADR2](ADR2.md) | (el ledger pierde autoridad frente a la wallet) | 2c4a107 (E1) |
| AD3: negociación con timeout | [ADR3](ADR3.md) | (el flujo se retira; la disciplina de timeout y reintento con el mismo idpk se reutiliza con la wallet y con otras ciudades) | 2c4a107 (E1) |

## Verificar el orden en el historial

    git log --follow --diff-filter=A --format="%h %ad %s" --date=short -- docs/ADR6.md

Repetir para cada archivo. El commit que agrega cada ADR de la E2 es anterior a los commits que lo implementan.