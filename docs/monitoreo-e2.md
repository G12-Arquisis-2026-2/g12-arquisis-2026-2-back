# Monitoreo · E2

Cómo replicar el monitoreo del nodo TK3 en producción. El APM de New Relic está en el servicio `web` (gema `newrelic_rpm`, aplicación `energyshark-back`), y el agente de infraestructura corre en la EC2. Los logs de los contenedores complementan lo que New Relic no ve (el connector no tiene agente APM).

## 1. Acceso

1. Entrar a [one.newrelic.com](https://one.newrelic.com) con la cuenta del grupo.
2. **APM & Services → `energyshark-back`** para la aplicación.
3. **Infrastructure → Hosts** para la EC2 (`ip-172-31-20-186`).

## 2. Qué mirar en el APM (`energyshark-back`)

| Vista | Qué muestra | Para qué sirve |
| --- | --- | --- |
| **Summary** | Tiempo de respuesta, throughput y tasa de errores de la API | Ver si la API responde normal |
| **Transactions** | Endpoints (`EventsController#create`, `/cycles`, `/market-strategy`) y jobs (`MarketCycleJob`, `SellMarketBidJob`, `AcceptMarketBidJob`, `CycleOrchestratorJob`) | Ver qué job o endpoint tarda más o falla |
| **External services** | Llamadas HTTP salientes por host, incluida la wallet | **Latencia de la wallet** (tiempo de respuesta y throughput del host de la wallet) |
| **Errors inbox** | Excepciones con su traza | Ver errores como `WalletClient::RetryableFailure` o `RecordNotUnique` |

### Latencia de la wallet

En **External services**, elegir el host de la wallet. La vista muestra el tiempo de respuesta promedio y el throughput de las llamadas a `POST /swaps`, `accept`, `cancel` y `GET /balance`.

Para una consulta propia, en **Query your data** (NRQL):

```sql
SELECT average(duration), percentile(duration, 95), count(*)
FROM Span
WHERE appName = 'energyshark-back' AND category = 'http' AND http.url LIKE '%wallet%'
FACET http.method
SINCE 1 hour ago TIMESERIES
```

Si la consulta no devuelve datos (por ejemplo, si el tracing distribuido está desactivado), usar la vista **External services**, que se arma con las métricas del agente.

## 3. Qué mirar en infraestructura

En **Infrastructure → Hosts →** la EC2:

- **CPU y memoria:** la instancia tiene 1 GB de RAM y 2 GB de swap. Un swap usado sobre ~1,8 GB indica presión de memoria (por ejemplo, durante un `docker build`).
- **Contenedores (Docker):** estado y consumo de `web`, `connector` y `db`.
- **Disco:** espacio libre en `/` (las imágenes de Docker ocupan varios GB).

## 4. Logs de los contenedores

El connector no tiene agente APM, así que su actividad se revisa en los logs. En la EC2, dentro de `~/back`:

```bash
# Estado de los contenedores
docker compose -f docker-compose.prod.yml ps

# Connector: las dos colas, reconexiones y NACK
docker compose -f docker-compose.prod.yml logs --since 30m connector | grep -iE "Escuchando|market.TK3|reconect|recover|NACK|IDENTITY_MISMATCH"

# Web: ciclo, reporte, mercado y wallet
docker compose -f docker-compose.prod.yml logs --since 30m web | grep -iE "negotiation-report|MarketCycleJob|WalletClient|swap-"
```

