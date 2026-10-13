#!/usr/bin/env bash
set -euo pipefail

image_name="${1:?Uso: deploy-backend.sh IMAGEN TAG ARCHIVO_ENV}"
image_tag="${2:?Falta el tag de la imagen}"
env_file="${3:?Falta el archivo de variables de la base de datos}"

if [[ ! -f "$env_file" ]]; then
  echo "No existe el archivo de variables: $env_file" >&2
  exit 1
fi

docker pull "$image_name:$image_tag"
docker rm -f saludos-backend 2>/dev/null || true
docker run --detach --name saludos-backend --restart unless-stopped \
  --publish 5000:5000 --env-file "$env_file" \
  "$image_name:$image_tag"

for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:5000/ready >/dev/null; then
    echo "Backend listo con imagen $image_name:$image_tag"
    exit 0
  fi
  sleep 2
done

docker logs --tail 50 saludos-backend >&2
echo "El backend no pasó la prueba de conexión a PostgreSQL" >&2
exit 1
