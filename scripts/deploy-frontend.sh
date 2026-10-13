#!/usr/bin/env bash
set -euo pipefail

image_name="${1:?Uso: deploy-frontend.sh IMAGEN TAG IP_BACKEND}"
image_tag="${2:?Falta el tag de la imagen}"
backend_host="${3:?Falta la IP privada del backend}"

docker pull "$image_name:$image_tag"
docker rm -f saludos-frontend 2>/dev/null || true
docker run --detach --name saludos-frontend --restart unless-stopped \
  --publish 8080:8080 \
  --env "BACKEND_HOST=$backend_host" --env BACKEND_PORT=5000 \
  "$image_name:$image_tag"

for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:8080/api/saludo >/dev/null; then
    echo "Frontend, backend y PostgreSQL conectados con imagen $image_name:$image_tag"
    exit 0
  fi
  sleep 2
done

docker logs --tail 50 saludos-frontend >&2
echo "El frontend no logró consultar el backend y PostgreSQL" >&2
exit 1
