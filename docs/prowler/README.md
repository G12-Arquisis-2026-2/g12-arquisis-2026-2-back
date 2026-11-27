# Prowler: revisión de seguridad de la cuenta AWS (RNF03)

Cuenta: 624005845126 · Región: us-east-2 · Herramienta: Prowler CLI v5.53.0

### Cómo se corrió
Desde AWS CloudShell, limitado a la región del proyecto y a severidad media o superior:

```bash
pip install prowler
prowler aws -f us-east-2 --severity medium high critical -M html csv
```

### Reporte inicial (27/11/2026, 19:45 UTC)
Archivo: `reporte-inicial.html`

| Checks ejecutados | Resultados | Fallidos | Críticos | Altos | Medios |
|---|---|---|---|---|---|
| 602 | 167 | 79 | 2 | 19 | 58 |

### Hallazgos reparados

| # | Check | Severidad | Riesgo que cierra | Qué se hizo | Estado |
|---|---|---|---|---|---|
| 1 | `ec2_instance_account_imdsv2_enabled` | High | La cuenta no exigía IMDSv2 por defecto. Una instancia nueva podía quedar expuesta a que, mediante un SSRF en la aplicación, se roben las credenciales temporales de su rol desde el servicio de metadatos. | Se configuró IMDSv2 obligatorio y hop limit 2 como valor por defecto de la cuenta en us-east-2. La instancia del backend ya tenía IMDSv2 obligatorio; el hop limit 2 permite que los contenedores Docker sigan obteniendo credenciales del rol. | Reparado 27/11 |
| 2 | `ecr_repository_image_no_secrets` | High | La imagen de `web` en ECR contenía respaldos del `.env` (`.env.bak-*`, `.env.save`) con credenciales de producción. Cualquiera con lectura sobre ECR o con una copia de la imagen podía obtenerlas. | Se movieron los respaldos fuera de la carpeta del build en el EC2, el `.dockerignore` pasó de excluir `.env` a excluir `.env*` (salvo `.env.example`), se reconstruyó la imagen y se borraron las imágenes antiguas de ECR. Se verificó que el historial de git nunca contuvo un `.env` real. | En curso |
| 3 | `cloudtrail_multi_region_enabled` | High | No había un registro de auditoría de las acciones en la cuenta en todas las regiones. Ante un incidente no se podría saber quién hizo qué ni cuándo. | Se creó un sendero de CloudTrail multi-región con eventos de administración, guardado en un bucket S3. | Pendiente |

Nota sobre el hallazgo 2: Prowler marcó como posibles secretos varios archivos del sistema y de la librería estándar de Ruby (por ejemplo `usr/local/lib/ruby/3.3.0/net/http.rb`), que son falsos positivos. Además, indicó que parte de la imagen no se alcanzó a escanear. Al revisar manualmente el contenido de la imagen (`ls -la /rails/.env*` dentro del contenedor) se encontraron los respaldos del `.env`, que sí eran un problema real.

### Hallazgos revisados y no reparados en esta entrega

| Check | Severidad | Por qué no se reparó ahora |
|---|---|---|
| `iam_root_hardware_mfa_enabled` | Critical | Exige una llave de MFA física, que el grupo no tiene. |
| `ec2_instance_port_ssh_exposed_to_internet` | Critical | Cerrar el puerto 22 sin una alternativa (Session Manager o IPs fijas) puede dejar sin acceso al grupo y al deploy. Se deja planificado. |
| `iam_user_mfa_enabled_console_access` (usuario `Correccion-E0`) | High | Es el usuario de los ayudantes para corregir; exigirle MFA les bloquearía el acceso. |
| `s3_account_level_public_access_blocks` | High | Hay que confirmar primero cómo CloudFront lee el bucket del frontend, para no dejar el sitio sin servir. |
| `iam_avoid_root_usage` | High | El escaneo se corrió con el usuario root. Para las próximas revisiones se usará un usuario IAM con las políticas SecurityAudit y ViewOnlyAccess. |

### Evidencia
Carpeta `evidencia/`:

- `imdsv2-antes.png`: `get-instance-metadata-defaults` sin valores configurados a nivel de cuenta.
- `imdsv2-despues.png`: `HttpTokens: required` y `HttpPutResponseHopLimit: 2` a nivel de cuenta.
- `ecr-env-antes.png`: respaldos del `.env` dentro de la imagen de `web`.
- `ecr-env-despues.png`: solo `.env.example` dentro de la imagen nueva.
- `cloudtrail-despues.png`: sendero multi-región activo.

### Reporte posterior
Archivo: `reporte-posterior.html` (se agrega al terminar las tres reparaciones).
