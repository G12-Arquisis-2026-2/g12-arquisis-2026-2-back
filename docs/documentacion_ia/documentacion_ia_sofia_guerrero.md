# Declaración de uso de IA — Sofía Guerrero

> - **Modelo:** Claude Sonnet 5.5 (chat) y Claude Code

> - **Plataforma:** Claude (web) y Claude code

> - **Cómo se usó:** En primer lugar, se utilizó para explicar el enunciado y para ayudar a comprender conceptos que no se entendían totalmente. Luego, se usó para ayudar con el paso a paso para el despliegue y la documentación. Finalmente, usó Claude code para escribir (no se hizo ningún cambio sin que yo lo leyera y aprobara) y revisar código del back mediante testing. En cada uso se utilizaron promts propios. Yo definí cada tarea, revisé los cambios, corrí los tests, desplegué y verifiqué en la EC2. En cada promt (tanto en Claude code como web) se tomó la precaución de no subir claves personales ni que se accediera a los vales del .env

> - **Archivos/partes afectadas:** 
- Infraestructura y despliegue (Claude fue guiando el paso a paso pero todo lo hice yo): EC2, Nginx, API Gateway, Auth0, CloudFront y S3, ECR, New Relic (infraestructura y APM), build y publicación del front.
- Back (código escrito por Claude code y revisado por mí): limpieza del repo (se habían subido muchos archivos de caché), ENABLE_PUBLISHER, POST /events y manejo de errores (500/503/422), reintentos y validación del connector, orquestador de ciclos, ledger, negociación de propuestas, gema newrelic_rpm, /connectivity y /audit-logs reales con sus tests.
- Front: arreglo de errores cuando un ciclo no tiene reporte de negociación.
- Documentación (borradores de Claude/Claude Code, revisados y corregidos por mí): docs/guia-local.md, docs/arquitectura-y-despliegue.md, diagramas UML y  repo de contratos (OpenAPI y agents.md).