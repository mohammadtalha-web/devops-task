#!/usr/bin/env bash
#
# deploy-app.sh <full-image-reference>
# Runs ON the EC2 instance (installed by Terraform user data, invoked by CI through SSM).
# Pulls the image, replaces the running container, smoke-tests /health and automatically
# rolls back to the previously deployed image if the smoke test fails.
set -euo pipefail

IMAGE="${1:?usage: deploy-app.sh <image-reference>}"
STATE_DIR="/opt/app"
# shellcheck source=/dev/null
source "${STATE_DIR}/deploy.conf"   # AWS_REGION, LOG_GROUP, APP_PORT, ENVIRONMENT
AWS_REGION="${AWS_REGION:?missing in deploy.conf}"
LOG_GROUP="${LOG_GROUP:?missing in deploy.conf}"
APP_PORT="${APP_PORT:?missing in deploy.conf}"
ENVIRONMENT="${ENVIRONMENT:?missing in deploy.conf}"
CONTAINER="app"
CURRENT_FILE="${STATE_DIR}/current_image"
PREVIOUS="$(cat "${CURRENT_FILE}" 2>/dev/null || true)"

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }

ecr_login() {
  local registry="${1%%/*}"
  [[ "${registry}" == *.dkr.ecr.*.amazonaws.com ]] || return 0
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${registry}" >/dev/null
}

run_container() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --name "${CONTAINER}" --restart unless-stopped \
    --env-file "${STATE_DIR}/app.env" \
    -p "${APP_PORT}:8080" \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 256m --cpus 0.5 \
    --log-driver awslogs \
    --log-opt "awslogs-region=${AWS_REGION}" \
    --log-opt "awslogs-group=${LOG_GROUP}" \
    --log-opt "awslogs-stream=${ENVIRONMENT}/${CONTAINER}" \
    --log-opt awslogs-create-group=false \
    "$1" >/dev/null
}

smoke_test() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS -m 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
      log "smoke test passed (attempt ${i})"
      return 0
    fi
    sleep 2
  done
  log "smoke test FAILED after 30 attempts"
  return 1
}

log "deploying ${IMAGE} (previous: ${PREVIOUS:-none})"
ecr_login "${IMAGE}"
docker pull "${IMAGE}"
run_container "${IMAGE}"

if smoke_test; then
  echo "${IMAGE}" >"${CURRENT_FILE}"
  docker image prune -f >/dev/null 2>&1 || true
  log "deploy succeeded"
  exit 0
fi

docker logs --tail 30 "${CONTAINER}" 2>&1 || true
if [[ -n "${PREVIOUS}" && "${PREVIOUS}" != "${IMAGE}" ]]; then
  log "rolling back to ${PREVIOUS}"
  ecr_login "${PREVIOUS}"
  docker pull "${PREVIOUS}" >/dev/null
  run_container "${PREVIOUS}"
  if smoke_test; then
    log "rollback succeeded; service is running ${PREVIOUS}"
  else
    log "ROLLBACK ALSO FAILED - manual intervention required"
  fi
else
  log "no previous image to roll back to"
fi
exit 1
