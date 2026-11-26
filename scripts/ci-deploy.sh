#!/usr/bin/env bash
#
# ci-deploy.sh <environment> <image>
# Runs in GitHub Actions: finds the tagged EC2 instance, asks SSM to run deploy-app.sh there,
# waits for the result and prints the command output. Exits non-zero if the deploy (or its
# automatic rollback path) did not end in success.
set -euo pipefail

ENVIRONMENT="${1:?usage: ci-deploy.sh <environment> <image>}"
IMAGE="${2:?usage: ci-deploy.sh <environment> <image>}"
PROJECT="${PROJECT_TAG:-devops-task}"
TIMEOUT_S="${DEPLOY_TIMEOUT_S:-420}"

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT}" "Name=tag:Environment,Values=${ENVIRONMENT}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "No running instance found for ${PROJECT}/${ENVIRONMENT}" >&2
  exit 1
fi
echo "Deploying ${IMAGE} to ${ENVIRONMENT} (${INSTANCE_ID})"

COMMAND_ID="$(aws ssm send-command \
  --instance-ids "${INSTANCE_ID}" \
  --document-name AWS-RunShellScript \
  --comment "deploy ${IMAGE}" \
  --parameters "commands=[\"/usr/local/bin/deploy-app.sh ${IMAGE}\"]" \
  --query 'Command.CommandId' --output text)"

deadline=$((SECONDS + TIMEOUT_S))
status="Pending"
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  status="$(aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "${status}" in
    Success|Failed|Cancelled|TimedOut) break ;;
    *) sleep 5 ;;
  esac
done

echo "----- remote output -----"
aws ssm get-command-invocation --command-id "${COMMAND_ID}" --instance-id "${INSTANCE_ID}" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text || true
echo "-------------------------"
echo "SSM status: ${status}"
[[ "${status}" == "Success" ]]
