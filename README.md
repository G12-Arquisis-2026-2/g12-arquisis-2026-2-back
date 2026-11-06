# EnergyShark · Backend de Tokyo-3 (TK3) · Entrega 2

Backend del nodo de la ciudad **Tokyo-3 (TK3)** para EnergyShark (IIC2173, 2026-2). En la E2 (protocolo v3), el nodo compra y vende energía directamente con otras ciudades. La wallet de la central actúa como escrow: custodia créditos (`CR`) y energía (`KWH`), y liquida cada swap en una sola transacción.

- API en producción: https://api.sofiaguerrero.me
- Frontend: repositorio aparte (React + Vite), publicado en S3 + CloudFront

## Repositorio de contratos

Los schemas de los mensajes y el OpenAPI de la API viven en el repositorio de contratos: [https://github.com/<org>/energyshark-e1-contracts](https://github.com/G12-Arquisis-2026-2/IIC2173-2026-2-G12-contratos/blob/main/agents.md)

Contexto compartido para agentes: ver [`agents.md`] en ese repositorio.

## Arquitectura

| Componente | Qué hace |
| --- | --- |
| `connector` (Ruby + Bunny) | Única conexión al broker. Consume `city.TK3.q` (central, otras ciudades y eventos de la wallet) y `market.TK3` (feed de ofertas), cada una en su propio canal. Valida el envelope y el `user_id`, responde ACK/NACK, reenvía a la API y publica lo que la API deja en el outbox |
| `web` (Rails 8, modo API) | Ledger, ciclos, auditoría, cliente de la wallet y estrategia de mercado. Expone la API JSON para el frontend. Los jobs corren con Solid Queue dentro de Puma |
| `db` (PostgreSQL 15) | Base de datos del nodo |

En producción: API Gateway (HTTP API, authorizer JWT de Auth0) → Nginx en EC2 → contenedores `web` y `connector`. Imágenes en Amazon ECR (`us-east-2`). Monitoreo con New Relic (APM en `web` y agente de infraestructura en la EC2).

El detalle está en el [diagrama UML de componentes](docs/diagrama_UML.md).

## Correr en local

Guía completa: [docs/guia-local.md](docs/guia-local.md).

```bash
cp .env.example .env      # completar; en local RabbitMQ apunta al contenedor rabbitmq
docker compose up -d --build
```

- API local: `http://localhost:3001` (master1) y `http://localhost:3002` (master2)
- Panel de RabbitMQ local: `http://localhost:15672` (guest / guest)
- Si el build falla en `apt-get` por la red, usar `docker build --network=host -f Dockerfile.dev -t back-master1 .`

**No usar las credenciales reales del broker en local** mientras producción esté corriendo: los dos connectors se repartirían los mensajes de `city.TK3.q`.

## Tests

```bash
cd connector
bundle install
for f in test/*_test.rb; do ruby -Itest "$f"; done
```

Incluye los contract tests (`contract_examples_test.rb`), que validan los mensajes contra los ejemplos oficiales del curso (`test/fixtures/contracts-v3.0.2`). Corren en GitHub Actions en cada PR ([.github/workflows/ci.yml](.github/workflows/ci.yml)).

## Documentación

| Documento | Contenido |
| --- | --- |
| [docs/e2-spec-milestones.md](docs/e2-spec-milestones.md) | Spec de la entrega, plan de milestones y roles |
| [docs/ADRs.md](docs/ADRs.md) | Índice de decisiones de arquitectura (AD1 a AD6) y su correspondencia con los archivos ADR |
| [docs/diagrama_UML.md](docs/diagrama_UML.md) | Diagrama de componentes |
| [docs/guia-local.md](docs/guia-local.md) | Cómo correr la aplicación en local |
| `docs/` (AI logs) | Logs de uso de AI por integrante |

## Configuración

Todas las variables están documentadas en [.env.example](.env.example). Las de la E2 son:

- `WALLET_URL`: URL de la wallet terminada en `/v1`
- `CITY_API_KEY`: API key de la wallet (secreto)
- `CYCLE_LENGTH_MINUTES=20`, `NEGOTIATION_WINDOW_MINUTES=15`, `REPORT_PERIOD_MINUTES=5`: ciclo de 20 minutos

Nunca subir `.env`, `.pem` ni la API key al repositorio.

