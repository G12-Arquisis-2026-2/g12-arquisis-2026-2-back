# Diagrama de componentes (arquitectura actual)

Vista UML de componentes del nodo EnergyShark de la ciudad TK3 tal como corre hoy en producción.
Cada flecha va **desde quien inicia la conexión** hacia quien la recibe, y su etiqueta indica el protocolo.
Los contenedores `web`, `connector` y `db` y sus conexiones salen de `docker-compose.prod.yml`, `Dockerfile`,
`config/puma.rb`, `infra/nginx/api.conf` y del código del connector. Lo marcado con † (y borde punteado)
no se ve en el repo y se toma **según la documentación de despliegue** (`docs/arquitectura-y-despliegue.md`).

```mermaid
flowchart LR
  NAV["Navegador del usuario<br/>SPA React"]

  subgraph EXT["Servicios externos"]
    AUTH0["«component» Auth0 †<br/>login y emisión del access token JWT"]
    BROKER[("«component» RabbitMQ de la central<br/>broker.iic2173.org:5671 †<br/>cola city.TK3.q")]
    NR["«component» New Relic SaaS"]
  end

  subgraph AWS["AWS"]
    CF["«component» CloudFront †<br/>app.sofiaguerrero.me<br/>403 y 404 a /index.html"]
    S3[("«component» S3 privado †<br/>build estático del front")]
    APIGW["«component» API Gateway HTTP API †<br/>api.sofiaguerrero.me<br/>authorizer JWT, CORS<br/>OPTIONS sin authorizer"]
    ECR[("«component» ECR us-east-2<br/>energyshark-back-web<br/>energyshark-back-connector")]

    subgraph EC2["EC2 Ubuntu"]
      NGINX["«component» Nginx :80<br/>exige X-Origin-Verify †<br/>responde 404 en = /events"]
      NRI["«component» Agente de infraestructura<br/>New Relic †"]

      subgraph COMPOSE["docker-compose.prod.yml"]
        subgraph WEB["contenedor web"]
          THR["Thruster :80"]
          PUMA["Puma :3000<br/>Rails 8 modo API"]
          SQ["Solid Queue dentro de Puma<br/>SOLID_QUEUE_IN_PUMA=true<br/>CycleOrchestratorJob, NegotiationTimeoutJob"]
          APM["Agente APM<br/>gema newrelic_rpm"]
        end
        CONN["«component» contenedor connector<br/>Ruby + Bunny<br/>consumidor + hilo outbox"]
        DB[("«component» contenedor db<br/>PostgreSQL 15, sin puerto publicado<br/>bases primary, cache, queue, cable")]
      end
    end
  end

  NAV -->|"HTTPS"| CF
  CF -->|"lectura con OAC †"| S3
  NAV -->|"HTTPS login"| AUTH0
  NAV -->|"HTTPS + Bearer JWT"| APIGW
  APIGW -->|"HTTPS claves JWKS †"| AUTH0
  APIGW -->|"HTTP + header X-Origin-Verify †"| NGINX
  NGINX -->|"HTTP 127.0.0.1:3000"| THR
  THR -->|"HTTP"| PUMA
  PUMA -->|"SQL base primary y cache"| DB
  SQ -->|"SQL base queue"| DB
  CONN -->|"HTTP red interna<br/>POST /events, POST /events/rejected<br/>GET /events/outbox, POST /events/outbox/:id"| THR
  CONN -->|"AMQPS consume city.TK3.q, ack manual"| BROKER
  CONN -->|"AMQPS publica al exchange con user_id<br/>ack, nack y mensajes del outbox<br/>solo si ENABLE_PUBLISHER=true"| BROKER
  COMPOSE -->|"HTTPS docker pull de las imágenes"| ECR
  APM -->|"HTTPS"| NR
  NRI -->|"HTTPS"| NR

  classDef docdesp stroke-dasharray: 5 5
  class AUTH0,CF,S3,APIGW,NRI docdesp
```

## Notas de lectura

- **El back nunca habla con el broker.** `RabbitMQPublisher` (`app/services/rabbit_m_q_publisher.rb`) solo
  inserta una fila en `outbox_messages`. El hilo outbox del connector la pide cada 2 s con `GET /events/outbox`,
  la publica esperando el *publisher confirm* del broker y la marca con `POST /events/outbox/:id`
  (`connector/lib/outbox_sender.rb`). Por el outbox salen `negotiation-proposal`, `transfer` (pago de un `take`),
  `negotiation-report` y `request`.
- **Los `ack` y `nack` de los mensajes recibidos no pasan por el outbox:** el connector los publica directo en el
  canal de consumo (`connector/lib/central_publisher.rb`). El connector no publica mensajes `error`, `give` ni
  `take`: esos los emite la central.
- **`ENABLE_PUBLISHER`** (`connector/consumer.rb:16`): solo con el valor exacto `true` el connector publica. En
  `docker-compose.prod.yml` el valor por defecto es `false` si falta en el `.env`. Apagado, el connector sigue
  consumiendo y guardando, pero solo loguea lo que publicaría y deja el outbox pendiente.
- **Solid Queue** corre como plugin de Puma (`config/puma.rb:38`) y guarda sus jobs en la base lógica `queue`
  (`config/environments/production.rb:50-51`). Las cuatro bases lógicas (`config/database.yml`, sección
  `production`) viven en el mismo servidor Postgres del contenedor `db`.
- **New Relic:** el agente APM es la gema `newrelic_rpm` (`Gemfile`), configurada con las variables `NEW_RELIC_*`.
  El agente de infraestructura está instalado en la EC2 (†).
- **ECR:** `web` y `connector` usan imágenes de ECR en `us-east-2` (`docker-compose.prod.yml`); `db` usa
  `postgres:15-alpine` de Docker Hub.

## A confirmar

- Valor real de `MASTER_URL` en producción (vive en el `.env`, que no se leyó). La documentación de despliegue dice
  `http://web/events`, que apunta a Thruster en el puerto 80 del contenedor `web`.
- Quién construye y sube las imágenes a ECR y con qué comando: el repo no tiene CI (no hay `.github/`).
- Que las variables `NEW_RELIC_*` estén definidas en el `.env` de producción (de eso depende que el APM reporte).
- Protocolo y región del endpoint de New Relic (se asume HTTPS, que es como reportan sus agentes; el repo no lo
  fija).
- Si API Gateway enruta o bloquea `/events/rejected`, `/events/outbox` y `/events/outbox/:id`: Nginx solo bloquea
  la ruta exacta `/events` (`infra/nginx/api.conf:6`).
- Nombre del exchange: el código lo lee de `RABBITMQ_EXCHANGE`; la documentación de despliegue lo nombra `energy.x`.
