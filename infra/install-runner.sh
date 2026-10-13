#!/usr/bin/env bash
set -euo pipefail

repo_url="${1:?Falta URL del repositorio}"
runner_token="${2:?Falta token temporal de registro}"
runner_label="${3:?Falta etiqueta frontend/backend}"
runner_name="${4:?Falta nombre del runner}"
runner_dir=/home/azureuser/actions-runner

timeout 900 cloud-init status --wait >/dev/null
systemctl is-active --quiet docker
id -nG azureuser | grep -qw docker

version="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/actions/runner/releases/latest | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
test -n "$version"
mkdir -p "$runner_dir"
if [[ ! -f "$runner_dir/config.sh" ]]; then
  curl -fsSL "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz" \
    -o /tmp/saludos-actions-runner.tar.gz
  tar -xzf /tmp/saludos-actions-runner.tar.gz -C "$runner_dir"
  rm -f /tmp/saludos-actions-runner.tar.gz
fi
chown -R azureuser:azureuser "$runner_dir"
cd "$runner_dir"
if [[ ! -f .runner ]]; then
  runuser -u azureuser -- ./config.sh --url "$repo_url" --token "$runner_token" \
    --labels "$runner_label" --name "$runner_name" --unattended --replace
fi
if ! systemctl list-unit-files 'actions.runner.*' --no-legend | grep -q .; then
  ./svc.sh install azureuser
fi
./svc.sh start
./svc.sh status
printf 'Runner %s listo con etiqueta %s y Docker activo\n' "$runner_name" "$runner_label"
