# Deploy de la E2 en producción

Pasos para desplegar el backend (web + connector) desde `development`. Todo se hace **dentro de la EC2**, igual que en la E1: la instancia tiene AWS CLI y el rol `energyshark-ec2-ecr`, que le da acceso a ECR sin credenciales guardadas.

Cuenta AWS `624005845126`, región `us-east-2` (Ohio). Repositorios ECR: `energyshark-back-web` y `energyshark-back-connector`.

## 0. Antes de empezar

- [ ] Pasó la hora de corte acordada y nadie tiene merges pendientes a `development`.
- [ ] El CI de `development` está en verde (pestaña Actions de GitHub).
- [ ] La EC2 tiene espacio y memoria para construir:
  ```bash
  df -h /          # al menos ~3 GB libres
  free -h          # revisar memoria libre y si hay swap
  ```
  Si falta disco: `docker image prune -f` (borra solo imágenes sin usar).

## 1. Conectarse y preparar variables

```bash
ssh -i ~/.ssh/clavesE0.pem ubuntu@18.218.169.51
cd ~/back

REGION=us-east-2
ACCOUNT=624005845126
REG=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
aws sts get-caller-identity --query Arn --output text   # debe mostrar assumed-role/energyshark-ec2-ecr
```

## 2. Respaldo para poder volver atrás

```bash
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REG

for img in energyshark-back-web energyshark-back-connector; do
  docker tag $REG/$img:latest $REG/$img:rollback
  docker push $REG/$img:rollback
done

cp .env .env.bak-$(date +%F-%H%M) && chmod 600 .env.bak-*
```

## 3. Traer el código de `development`

```bash
git status --short            # si hay cambios locales, revisarlos antes de seguir
git fetch && git switch development && git pull
SHA=$(git rev-parse --short HEAD); echo "Desplegando $SHA"
```

## 4. Construir y subir las imágenes

Los contenedores actuales siguen funcionando mientras se construye. En la prueba del 5 de noviembre, los reportes salieron normales con el build corriendo.

Tiempos medidos en la EC2 (5 de noviembre, código de `development`):

| Imagen | Sin caché | Con caché (sin cambios en `Gemfile.lock`) |
| --- | --- | --- |
| `energyshark-back-web` | ~16 min (13 de `bundle install`) | ~2 a 3 min |
| `energyshark-back-connector` | ~5 min | ~15 s |

Si el `Gemfile.lock` cambió desde la prueba, contar con los 16 minutos y empezar temprano. Durante el build, vigilar en otra terminal que el swap usado no pase de ~1,8 Gi y que los contenedores sigan `healthy`:

```bash
watch -n 5 'free -h | head -3; docker ps --format "{{.Names}}: {{.Status}}"'
```

```bash
docker build -t $REG/energyshark-back-web:latest -t $REG/energyshark-back-web:$SHA .
docker build -t $REG/energyshark-back-connector:latest -t $REG/energyshark-back-connector:$SHA ./connector

for img in energyshark-back-web energyshark-back-connector; do
  docker push $REG/$img:latest
  docker push $REG/$img:$SHA
done
```

La etiqueta `$SHA` deja cada versión identificada por su commit.

## 5. Variables del ciclo

```bash
grep -q '^CYCLE_LENGTH_MINUTES=' .env || printf '\n# --- Ciclo E2 (20 min) ---\nCYCLE_LENGTH_MINUTES=20\nNEGOTIATION_WINDOW_MINUTES=15\nREPORT_PERIOD_MINUTES=5\n' >> .env
grep -cE "^(WALLET_URL|CITY_API_KEY|CYCLE_LENGTH_MINUTES|NEGOTIATION_WINDOW_MINUTES|REPORT_PERIOD_MINUTES)=" .env   # debe dar 5
grep "^ENABLE_PUBLISHER=" .env   # debe ser true
```

## 6. Levantar

No reiniciar entre T+10 y T+15 del ciclo, que es la ventana del `negotiation-report`. El mejor momento es justo después de que se encole un reporte:

```bash
docker compose -f docker-compose.prod.yml logs web --since 20m | grep -i "negotiation-report" | tail -1
```

Entonces:

```bash
docker compose -f docker-compose.prod.yml up -d
```

## 7. Verificar

```bash
docker compose -f docker-compose.prod.yml ps                       # todo Up / healthy
docker compose -f docker-compose.prod.yml logs --tail 30 connector # "Escuchando en 'city.TK3.q'"
docker compose -f docker-compose.prod.yml logs --tail 50 web | grep -iE "error|migrat"
docker compose -f docker-compose.prod.yml exec web sh -c 'test -n "$WALLET_URL" && test -n "$CITY_API_KEY" && echo "Wallet configurada"'
curl -s https://api.sofiaguerrero.me/healthz                      # ok
```

En los ciclos siguientes:

```bash
# El reporte sigue saliendo
docker compose -f docker-compose.prod.yml logs web --since 25m | grep -i "negotiation-report" | tail -2
# Ya no hay NACK UNKNOWN_TYPE para mensajes v3
docker compose -f docker-compose.prod.yml logs connector --since 25m | grep -c "UNKNOWN_TYPE"
# G04: al menos un swap liquidado
docker compose -f docker-compose.prod.yml logs web --since 2h | grep -c "swap-settled"
```

Anotar en `/docs` (y en la sección "Estado actual" del `agents.md` de contratos) el commit desplegado (`$SHA`) y la hora.

## 8. Volver atrás

Si algo grave falla (el connector se reinicia en loop, no salen reportes):

```bash
for img in energyshark-back-web energyshark-back-connector; do
  docker tag $REG/$img:rollback $REG/$img:latest
done
docker compose -f docker-compose.prod.yml up -d
```

Si el problema es de configuración, restaurar también el `.env` desde el respaldo del paso 2.

Si el código nuevo agregó migraciones, volver a la imagen anterior no deshace los cambios en la base. Revisar con quien escribió la migración antes de hacer rollback.
