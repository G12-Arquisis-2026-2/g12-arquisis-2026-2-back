# Declaración de uso de IA — Sofía Guerrero

## Entrega 1

> - **Modelo:** Claude Sonnet 5.5 (chat) y Claude Code

> - **Plataforma:** Claude (web) y Claude code

> - **Cómo se usó:** En primer lugar, se utilizó para explicar el enunciado y para ayudar a comprender conceptos que no se entendían totalmente. Luego, se usó para ayudar con el paso a paso para el despliegue y la documentación. Finalmente, usó Claude code para escribir (no se hizo ningún cambio sin que yo lo leyera y aprobara) y revisar código del back mediante testing. En cada uso se utilizaron promts propios. Yo definí cada tarea, revisé los cambios, corrí los tests, desplegué y verifiqué en la EC2. En cada promt (tanto en Claude code como web) se tomó la precaución de no subir claves personales ni que se accediera a los vales del .env

> - **Archivos/partes afectadas:** 
- Infraestructura y despliegue (Claude fue guiando el paso a paso pero todo lo hice yo): EC2, Nginx, API Gateway, Auth0, CloudFront y S3, ECR, New Relic (infraestructura y APM), build y publicación del front.
- Back (código escrito por Claude code y revisado por mí): limpieza del repo (se habían subido muchos archivos de caché), ENABLE_PUBLISHER, POST /events y manejo de errores (500/503/422), reintentos y validación del connector, orquestador de ciclos, ledger, negociación de propuestas, gema newrelic_rpm, /connectivity y /audit-logs reales con sus tests.
- Front: arreglo de errores cuando un ciclo no tiene reporte de negociación.
- Documentación (borradores de Claude/Claude Code, revisados y corregidos por mí): docs/guia-local.md, docs/arquitectura-y-despliegue.md, diagramas UML y  repo de contratos (OpenAPI y agents.md).

## Entrega 2

> - **Modelo:** Claude (chat) y Claude Code

> - **Plataforma:** Claude (web) y Claude Code en Ubuntu (WSL)

> - **Cómo se usó:** Usé Claude (chat) para distribuir el trabajo del grupo, escribir la spec y los milestones, y entender los conceptos nuevos de la E2 (wallet, idempotencia, swapToken con JWKS, las dos colas). También para guiarme paso a paso en el despliegue a producción y para diagnosticar errores en producción a partir de los logs y las consultas a la base que yo corría en la EC2. Usé Claude Code para auditar el estado del front, del back y del repo de contratos contra los requisitos de la entrega, y para aplicar un fix puntual que revisé antes del commit. Todos los cambios de código los pegué o revisé yo antes de cada commit, y los PRs pasaron por revisión del grupo. Yo corrí los comandos, desplegué y verifiqué en la EC2. Igual que en la E1, en ningún prompt compartí claves (API key de la wallet, credenciales del broker, `.env`), y las pruebas con la wallet desde local fueron solo de lectura.

> - **Archivos/partes afectadas:**
- Planificación: distribución de tareas entre los 5 integrantes y `docs/e2-spec-milestones.md`.
- Entorno local: migración de los repos desde OneDrive a Ubuntu (WSL), `Dockerfile.dev` (copiar `Gemfile.lock`), RabbitMQ local en el `docker-compose.yml` de desarrollo y separación de los `.env` del front (local y producción).
- Secretos: la API key de la wallet se carga solo en el `.env` de la EC2 y nunca en el repo; `.env.example` actualizado con las variables de la E2 (ciclo de 20 min, `WALLET_URL`, `CITY_API_KEY`) y solo placeholders; `.gitignore` del front. Se tuvo cuidado de nunca mandar ningún secreto o información privada al chat.
- Infraestructura y despliegue (Claude guió el paso a paso, yo lo ejecuté): build y push de imágenes a ECR desde la EC2, variables del ciclo, despliegues fuera de las ventanas de reporte, migraciones y rollback; CORS en API Gateway (orígenes, métodos PUT/PATCH); publicación del front en S3 y la invalidación en CloudFront.
- Back, fixes encontrados en producción (diagnóstico con Claude, código revisado por mí):
  - `WalletTokenValidator`: URL del JWKS en la raíz del dominio.
  - `NegotiationStrategyService`: la distancia viene en metros y el transporte se calcula en km.
  - `MarketCycleJob` y `CycleReconciliationJob`: lectura del saldo desde `assets` de `GET /balance`.
  - `MarketSwapEventService#rejected`: liberar la reserva del vendedor cuando falla el accept del comprador, y corrección de un NameError en ese mismo método.
  - `MarketApiController#span`: campos alineados con el front y cálculo del baseline y del costo efectivo (RF06).
- Front: normalización de las respuestas de `/cycles` y `/market/live` en `apiService.ts` (evita TypeError en RF01 y RF02) y validaciones del formulario de estrategia (RF04).
- CI: workflow de GitHub Actions con los tests del connector.
- Documentación (borradores de Claude revisados y corregidos por mí): `docs/deploy-e2.md`, el diagrama UML de componentes de la E2 con interfaces provistas y requeridas (`docs/diagrama_UML_E2.md`, `docs/uml/`), `docs/indices_ADRs.md` para explicar la confusión que hubo con la numeración de estos, README y `.env.example`.
- Auditorías con Claude Code (solo lectura): integración front ↔ back, requisitos de la entrega y repo de contratos. Con sus resultados repartí las tareas finales del grupo.
- Análisis del mercado en producción: revisión de bids, swaps y saldo de la wallet para verificar G04 y documentar por qué no se liquidaron swaps (los compradores no tenían crédito: `INSUFFICIENT_ASSET`).

> - **Link de chat con Claude:**
https://claude.ai/share/818734b3-2eaa-430b-a1af-21c0a799c1e3
