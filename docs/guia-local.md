# Guía para correr EnergyShark (TK3) en local

Objetivo: clonar los repos y correr la API (back) y el front en tu PC **sin credenciales reales** y sin conectarse al broker de la central.

Cada paso está marcado:

- **[verificado]**: se ejecutó el 2026-10-07 sobre `development` (`439677d`) para el back y `main` (`f7347f5`) para el front.
- **[no probado]**: no se ejecutó; puede requerir ajustes.

Cuando un comando difiere entre shells se dan las dos versiones: **bash** (Linux, macOS, Git Bash) y **PowerShell** (Windows).

> El README del back no tiene una sección de ejecución local, así que esta guía no duplica nada.

---

## 1. Requisitos

1. **Docker** con **Compose v2 o superior** (`docker compose`, no `docker-compose`). Se probó con Docker 29.7.2 y Compose v5.4.0. **[verificado]**
2. **Node 22 LTS** y npm. El `package.json` del front no fija versión (no tiene `engines`). Se probó con `node:22` (v22.23.3) en un contenedor. **[verificado]** Con otras versiones: **[no probado]**.
3. **Git**.

## 2. Clonar

Conviene clonar **fuera de OneDrive**, Dropbox o carpetas sincronizadas (ver §9).

```bash
git clone https://github.com/G12-Arquisis-2026-2/g12-arquisis-2026-2-back.git back-proyecto
git clone https://github.com/G12-Arquisis-2026-2/g12-arquisis-2026-2-front.git front-proyecto
cd back-proyecto && git switch development
```

- El back incluye el connector en `connector/`.
- El front vive en `front-proyecto/frontend/`.
- Los scripts (`bin/*`, `*.sh`, `Dockerfile*`) se guardan siempre con LF por `.gitattributes`, también en Windows. **[verificado]**

## 3. Variables de entorno del back

### 3.1 `.env`

```bash
cp .env.example .env                 # bash
Copy-Item .env.example .env          # PowerShell
```

**Para levantar solo `db` y `master1` (§4) el `.env` no es necesario.** En `docker-compose.yml`, `db`, `master1` y `master2` tienen sus variables escritas en el archivo; solo el `connector` declara `env_file: .env`. Se comprobó con `docker compose up --dry-run db master1` sin `.env`: no da error. **[verificado]**

El `.env` lo usan el connector y `docker-compose.prod.yml`. Si lo creas, deja los valores de ejemplo:

- **`ENABLE_PUBLISHER=false`**
- **Nunca pongas en local credenciales reales del broker** (`RABBITMQ_URL`, `RABBITMQ_USER`).

| Variable | Qué hace | Dónde se usa | ¿Obligatoria en local (db + master1)? |
|---|---|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Usuario, clave y base de Postgres | `docker-compose.prod.yml` (en dev están fijas en `docker-compose.yml`) | No |
| `RAILS_ENV` | Entorno de Rails | producción (en dev, `master1` fija `development`) | No |
| `RAILS_MASTER_KEY` | Descifra `config/credentials.yml.enc` | producción y `config/deploy.yml` | No |
| `ALLOWED_HOSTS` | Hosts públicos permitidos | `config/environments/production.rb` | No |
| `E0_DATABASE_PASSWORD` | Clave del usuario `e0` | `config/database.yml` (producción) | No |
| `DATABASE_URL`, `CACHE_/QUEUE_/CABLE_DATABASE_URL` | Conexión a las bases | producción (en dev, `master1` recibe `DATABASE_URL` desde el compose) | No |
| `SOLID_QUEUE_IN_PUMA` | Corre los jobs (orquestador) dentro de Puma | `config/puma.rb`, `docker-compose.prod.yml` | No (en dev los jobs usan el adaptador async) |
| `RABBITMQ_URL`, `RABBITMQ_USER` | Conexión al broker y `user_id` AMQP | `connector/consumer.rb` | No. **No usar credenciales reales** |
| `MASTER_URL`, `QUEUE_NAME`, `RABBITMQ_EXCHANGE`, `CENTRAL_ROUTING_KEY` | URL de la API para el connector, cola, exchange y routing key | `connector/consumer.rb` | No |
| `ENABLE_PUBLISHER` | Solo con `true` el connector publica hacia la central | connector, `docker-compose.prod.yml` | No. En local, **`false`** |
| `CITY_ID` | Código de la ciudad (`TK3`) | API (`rabbit_m_q_publisher.rb:32`, `cycle_service.rb`, `connectivity_controller.rb`), connector y tests | **Sí, vía override (§3.2)** |
| `NEW_RELIC_LICENSE_KEY`, `NEW_RELIC_APP_NAME`, `NEW_RELIC_LOG` | APM New Relic | gema `newrelic_rpm` | No |
| `ECR_REGISTRY` | Registro de imágenes | `docker-compose.prod.yml` | No |
| `CITY_ROUTING_KEY`, `OBSERVER_ID`, `CITY_NAME`, `CORS_ORIGINS` | Aparecen en `.env.example` | **ningún archivo del código las lee** (grep vacío) | No |

### 3.2 `CITY_ID` con un `docker-compose.override.yml` local

**`CITY_ID=TK3` es obligatorio.** `RabbitMQPublisher` usa `ENV.fetch("CITY_ID")` sin valor por defecto (`app/services/rabbit_m_q_publisher.rb:32`). Sin `CITY_ID`, cualquier publicación lanza `KeyError`: `POST /proposals` y las peticiones del orquestador. Qué pasa con los tests sin `CITY_ID`: **[no probado]**.

`master1` y `master2` **no leen `.env`** (no tienen `env_file`), así que `CITY_ID` se pasa con un override. Crea `docker-compose.override.yml` en la raíz del back:

```yaml
services:
  master1:
    environment:
      CITY_ID: "TK3"
      ENABLE_PUBLISHER: "false"
```

Compose lo combina automáticamente con `docker-compose.yml`. **No lo commitees.** Exclúyelo solo en tu clon, no en el `.gitignore` del repo:

```bash
echo "docker-compose.override.yml" >> .git/info/exclude                         # bash
Add-Content -Encoding ascii .git/info/exclude "docker-compose.override.yml"     # PowerShell
```

## 4. Levantar la API

```bash
docker compose up -d --build db master1
```

- **No levantes `connector` ni `master2`.** El connector lee `.env` y, con credenciales reales, se conectaría al broker de la central. `master2` no hace falta.
- La API queda en **http://localhost:3001** (`master1` publica `3001:3000`).
- `entrypoint.sh` corre `rails db:migrate` y luego `rails server`: no hay que migrar a mano.

Estado:

- Que `entrypoint.sh` migra solo y que la API responde con `RAILS_ENV=development`, `CITY_ID=TK3` y el mismo `DATABASE_URL` del compose: **[verificado]**. Se corrió el mismo `entrypoint.sh` en un contenedor `ruby:3.3-slim` con Postgres 15 desechable en una red `--internal`.
- El comando `docker compose up -d --build db master1` tal cual: **[no probado en esta verificación]**. No se pudo correr sin chocar con un `master1` que ya estaba levantado (`container_name: master1` es fijo).

## 5. Comprobar

```bash
curl -s http://localhost:3001/up                  # bash
curl.exe -s http://localhost:3001/up              # PowerShell (curl.exe, no el alias curl)
```

Con la base vacía, la respuesta esperada de cada ruta es: **[verificado]**

| Ruta | HTTP | Cuerpo |
|---|---|---|
| `/up` | 200 | página HTML de Rails (health) |
| `/healthz` | 200 | `ok` |
| `/cycles` | 200 | `{"cycles":[]}` |
| `/cycles/current` | **404** | `{"error":"NO_ACTIVE_CYCLE",...}`. Es lo correcto sin ciclos |
| `/proposals` | 200 | `{"proposals":[]}` |
| `/connectivity` | 200 | `{"cityId":"TK3","updatedAt":null,"distances":{}}` |
| `/audit-logs` | 200 | `{"duplicates":[],"rejectedMessages":[]}` |

En local la API **no pide token**: no valida JWT y en producción la autenticación la hace el API Gateway. **[verificado]**

## 6. Cargar datos de prueba sin la central

`POST /events` es la ruta interna por la que el connector entrega los mensajes. En local se puede llamar directo.

Respuestas:

- **201** `{"status":"saved"}`: mensaje guardado.
- **200** `{"status":"duplicate"}`: idpk repetido; el ledger no cambia y queda registrado en `/audit-logs`.
- **422** `{"error":"MALFORMED_MESSAGE",...}`: mensaje malformado.

Guarda cada JSON en un archivo **fuera del repo** (por ejemplo `../ejemplos-locales/`). En PowerShell, guárdalos en ASCII (`Set-Content -Encoding ascii`) para que no lleven BOM. El `validUntil` de 2030 es a propósito: así el orquestador no intenta reportar ese ciclo.

Para enviar un archivo, la misma línea sirve en ambas shells (en PowerShell usa `curl.exe`):

```bash
curl -s -X POST http://localhost:3001/events -H "Content-Type: application/json" --data-binary "@status.json"
```

### 6.1 `status.json`: abre el ciclo `cycle-local-1` → 201 **[verificado]**

```json
{"idpk":"11111111-1111-4111-8111-111111111111","msgId":"aaaaaaaa-0000-4000-8000-000000000001","type":"status-statement","timestamp":"2030-01-01T10:00:00Z","sender":"central","cycleId":"cycle-local-1","data":{"energy":{"generationCapacity":1200,"consumption":950,"generationCost":210},"validUntil":"2030-01-01T12:00:00Z"}}
```

### 6.2 `status-dup.json`: mismo `idpk`, `msgId` nuevo → 200 `duplicate` **[verificado]**

```json
{"idpk":"11111111-1111-4111-8111-111111111111","msgId":"aaaaaaaa-0000-4000-8000-000000000002","type":"status-statement","timestamp":"2030-01-01T10:00:05Z","sender":"central","cycleId":"cycle-local-1","data":{"energy":{"generationCapacity":1200,"consumption":950,"generationCost":210},"validUntil":"2030-01-01T12:00:00Z"}}
```

### 6.3 `transfer.json`: fondos → 201. Si lo envías de nuevo con otro `msgId` → 200 `duplicate` **[verificado]**

```json
{"idpk":"22222222-2222-4222-8222-222222222222","msgId":"aaaaaaaa-0000-4000-8000-000000000003","type":"transfer","timestamp":"2030-01-01T10:00:10Z","sender":"central","cycleId":"cycle-local-1","data":{"quantity":508145}}
```

### 6.4 `demand.json`: la central entrega 1500 kWh a 215 → 201 **[verificado]**

```json
{"idpk":"33333333-3333-4333-8333-333333333333","msgId":"aaaaaaaa-0000-4000-8000-000000000005","type":"demand-statement","timestamp":"2030-01-01T10:01:00Z","sender":"central","cycleId":"cycle-local-1","data":{"balance":{"quantity":1500,"valuePerKwh":215}}}
```

### 6.5 `distances.json` → 201 **[verificado]**

```json
{"idpk":"44444444-4444-4444-8444-444444444444","msgId":"aaaaaaaa-0000-4000-8000-000000000006","type":"distance-table","timestamp":"2030-01-01T10:02:00Z","sender":"central","data":{"distances":{"HGW":{"distance":62763183,"transportCost":0.0034,"enabled":true},"TAR":{"distance":94306517,"transportCost":0.0013,"enabled":false}}}}
```

### 6.6 `error.json`: `error` de la central → 201; aparece en `/audit-logs` → `rejectedMessages` con `type: "error"` **[verificado]**

```json
{"idpk":"55555555-5555-4555-8555-555555555555","msgId":"aaaaaaaa-0000-4000-8000-000000000007","type":"error","timestamp":"2030-01-01T10:03:00Z","sender":"central","cycleId":"cycle-local-1","reason":"PRICE_ABOVE_CAP","code":422,"data":{"target":"bbbbbbbb-0000-4000-8000-000000000001","message":"bid 230 exceeds the cap of 220.5 for cycle-local-1","cap":220.5}}
```

### 6.7 `malformado.json`: status-statement sin `validUntil` → 422 `missing field data.validUntil` **[verificado]**

```json
{"idpk":"66666666-6666-4666-8666-666666666666","msgId":"aaaaaaaa-0000-4000-8000-000000000008","type":"status-statement","timestamp":"2030-01-01T10:04:00Z","sender":"central","cycleId":"cycle-local-2","data":{"energy":{"generationCapacity":1,"consumption":1,"generationCost":1}}}
```

### 6.8 Resultado esperado tras 6.1–6.7 **[verificado]**

`/cycles` muestra `cycle-local-1` con:

- `fundsReceived: 508145.0`
- `finalBalances.budget: "185645.0"`, que es 508145 − 1500 × 215
- `finalBalances.energy: "1750.0"`, que es 1200 − 950 + 1500
- `lastOperation: "demand-statement"`
- `negotiationReport: null`

`/audit-logs` lista los 2 duplicados y el error.

Los decimales de Postgres llegan como **strings** en el JSON (`"1200.0"`). Es el comportamiento de Rails con `BigDecimal`.

Para reiniciar la base: `docker compose down -v` (§9).

## 7. Front local

1. Entra a la carpeta del front:
   ```bash
   cd front-proyecto/frontend
   ```
2. **Existe `frontend/.env.example`** con los nombres de las 4 variables. Cópialo a `frontend/.env` y completa `VITE_AUTH0_DOMAIN`, `VITE_AUTH0_CLIENT_ID` y `VITE_AUTH0_AUDIENCE`. **Pídelos al equipo; no los subas al repo.** `.env` está en el `.gitignore` de la raíz del front.
3. Crea `frontend/.env.local` con **una sola línea**, en ASCII (sin BOM):
   ```bash
   echo "VITE_API_BASE_URL=http://localhost:3001" > .env.local                          # bash
   "VITE_API_BASE_URL=http://localhost:3001" | Set-Content -Encoding ascii .env.local   # PowerShell
   ```
   `.env.local` tiene prioridad sobre `.env` y queda ignorado por `*.local` (`frontend/.gitignore:13`).
   - Con `Set-Content -Encoding ascii` el archivo queda sin BOM. Con `Out-File -Encoding utf8` en PowerShell 5.1 se agrega el BOM `EF BB BF`. **[verificado]**
   - Con `.env.local`, Vite usa `VITE_API_BASE_URL=http://localhost:3001` aunque `.env` apunte a producción. **[verificado]**
4. Instala y arranca:
   ```bash
   npm ci
   npm run dev
   ```
   Abre http://localhost:5173. `npm ci` y `npm run dev` arrancaron y `GET /` respondió 200. **[verificado]**
5. **Todas las vistas exigen login con Auth0** (`ProtectedRoute` en `App.tsx:75-78`).
   - En Auth0, la aplicación debe permitir `http://localhost:5173` en **Allowed Callback URLs**, **Allowed Logout URLs** y **Allowed Web Origins**. **[no probado]**: no se tuvo acceso a Auth0.
   - El login completo: **[no probado]**.
6. El CORS del back permite `http://localhost:5173`: un preflight devuelve `access-control-allow-origin: http://localhost:5173`. **[verificado]**
7. **Reinicia `npm run dev` después de cambiar cualquier variable.**
8. **Borra `.env.local` antes de compilar para producción.** `npm run build` también lo lee y deja `localhost:3001` incrustado en `dist/`. **[verificado]**

Problema conocido del front (detectado leyendo el código, no reproducido en el navegador): expandir un ciclo con `negotiationReport: null`, como el de §6, rompe la vista. `CyclesPage.tsx:260,269` lee `.sentAt` y `.budgetBalance` sin revisar `null`.

## 8. Tests

Corren con un Postgres desechable. Los tests no se conectan al broker.

Resultado al 2026-10-07 sobre `439677d`: **back 192 runs, 798 assertions, 0 fallos; connector 94 runs, 0 fallos** (`central_publisher` 9, `message_processor` 35, `message_validator` 38, `outbox_sender` 12). **[verificado]** Se ejecutó este mismo procedimiento sobre una copia hecha con `git archive`, en vez de montar el clon.

**bash** (en Git Bash anteponer `MSYS_NO_PATHCONV=1` al `docker run`), desde la raíz del back:

```bash
docker network create guia-tests
docker run -d --name guia-tests-pg --network guia-tests -e POSTGRES_PASSWORD=solo_tests postgres:15-alpine
docker run --rm --network guia-tests -v "$PWD:/app" -w /app \
  -e RAILS_ENV=test -e CITY_ID=TK3 \
  -e DATABASE_URL=postgres://postgres:solo_tests@guia-tests-pg:5432/e0_test \
  ruby:3.3-slim bash -c 'apt-get update -qq && apt-get install -y -qq build-essential libpq-dev libyaml-dev git >/dev/null \
    && bundle install --quiet && bin/rails db:create db:schema:load && bin/rails test \
    && cd connector && bundle install --quiet && for t in test/*_test.rb; do ruby -Ilib -Itest "$t" || exit 1; done'
docker rm -f -v guia-tests-pg
docker network rm guia-tests
```

**PowerShell**: es lo mismo, cambiando el montaje y las continuaciones de línea:

```powershell
docker network create guia-tests
docker run -d --name guia-tests-pg --network guia-tests -e POSTGRES_PASSWORD=solo_tests postgres:15-alpine
docker run --rm --network guia-tests -v "${PWD}:/app" -w /app -e RAILS_ENV=test -e CITY_ID=TK3 -e DATABASE_URL=postgres://postgres:solo_tests@guia-tests-pg:5432/e0_test ruby:3.3-slim bash -c 'apt-get update -qq && apt-get install -y -qq build-essential libpq-dev libyaml-dev git >/dev/null && bundle install --quiet && bin/rails db:create db:schema:load && bin/rails test && cd connector && bundle install --quiet && for t in test/*_test.rb; do ruby -Ilib -Itest "$t" || exit 1; done'
docker rm -f -v guia-tests-pg
docker network rm guia-tests
```

La red no es `--internal` porque `bundle install` necesita descargar gemas. `-v` en `docker rm` borra también el volumen anónimo de Postgres.

Front: no tiene suite de tests. `npm run build` compila (exit 0). `npm run lint` reporta 7 errores (`react-hooks/set-state-in-effect`, `no-explicit-any`). **[verificado]**

## 9. Problemas posibles

Problemas posibles que se pueden dar al levantar el código. Las causas marcadas **[verificado]** se confirmaron en el código.

- **`GemNotFound` (thruster, net-ssh) al levantar `master1`.** El `Dockerfile.dev` del repo copia solo `Gemfile` (`COPY Gemfile ./`), sin `Gemfile.lock`, y Docker reutiliza una capa cacheada de `bundle install`. **[verificado]** Solución: `docker compose build --no-cache master1`, o copiar también `Gemfile.lock` en `Dockerfile.dev` (`COPY Gemfile Gemfile.lock ./`).
- **`master1` sale con código 1 y desaparece de `docker compose ps`.** Mira el motivo con `docker compose logs --tail=60 master1` (o `docker compose ps -a`). Pueden haber problemas si usuario ya tiene un container levantado.
- **El front llama a producción en vez de local.** No se tomó `.env.local`: reinicia `npm run dev` y guárdalo en ASCII, no en UTF-8 con BOM (§7.3).
- **`/cycles/current` da 404.** Es lo normal sin ciclos cargados (§5).
- **Puertos ocupados.** `master1` usa el 3001, `master2` el 3002 y Vite el 5173. El `db` de `docker-compose.yml` **no publica el 5432**; solo choca si tu override lo publica. Para ver quién ocupa un puerto: `netstat -ano | findstr :3001` (PowerShell) o `lsof -i :3001` (bash).
- **Clon dentro de OneDrive.** Los directorios pueden quedar de solo lectura al construir la imagen de producción desde ahí (`Permission denied` en `/rails/tmp/sockets`). Construye desde una copia limpia (`git archive HEAD | tar -x -C <carpeta>`) o clona fuera de OneDrive. **[verificado]**
- **Reiniciar la base local:** `docker compose down -v`. Borra el volumen `pgdata` del proyecto y con él todos los datos locales.

## 10. Qué NO hacer

- No levantes el `connector` con credenciales reales del broker. Tampoco con `ENABLE_PUBLISHER=true` en local.
- No commitees `.env`, `frontend/.env`, `frontend/.env.local` ni `docker-compose.override.yml`.
- No publiques imágenes a ECR desde un clon dentro de OneDrive (§9).

---

## Resumen de verificación (2026-10-07)

| Paso | Estado |
|---|---|
| 1. Docker/Compose, Node 22 en contenedor | [verificado]. Otras versiones de Node: [no probado] |
| 2. `.gitattributes` con LF en scripts | [verificado]. Comandos de clonación: [no probado] |
| 3. `.env` no requerido para db + master1; uso de cada variable | [verificado] (dry-run y grep) |
| 3. Tests sin `CITY_ID` | [no probado] |
| 4. Migración automática y arranque de la API | [verificado]. `docker compose up -d --build db master1` literal: [no probado] |
| 5. Respuestas con la base vacía | [verificado] |
| 6. Los 7 ejemplos de `POST /events` y el resultado en `/cycles` y `/audit-logs` | [verificado] |
| 7. `.env.local` en ASCII, prioridad sobre `.env`, `npm ci` y `npm run dev`, CORS, build con `.env.local` | [verificado] |
| 7. Login con Auth0 y URLs permitidas | [no probado] |
| 8. Back 192/192, connector 94/94, build y lint del front | [verificado] (sobre una copia `git archive`) |
| 9. Causa del `GemNotFound` (`Dockerfile.dev` sin `Gemfile.lock`), `db` sin el 5432 | [verificado]. El resto, reportado por el equipo |
