#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
assert_account

[[ -f "${STATE_DIR}/history-gate.json" ]] || {
  echo "ARC history gate has not passed; refusing failover" >&2
  exit 1
}

if [[ "$(jq -r '.evaluation.evaluationState' "${STATE_DIR}/history-gate.json")" != "passed" ]]; then
  echo "ARC evaluation is not passed; refusing failover" >&2
  exit 1
fi

plan_arn="$(cat "${STATE_DIR}/plan-arn.txt")"
execution_id="$(aws arc-region-switch start-plan-execution \
  --region "${STANDBY_REGION}" \
  --plan-arn "${plan_arn}" \
  --target-region "${STANDBY_REGION}" \
  --action activate \
  --mode ungraceful \
  --latest-version true \
  --comment "Blog experiment: CloudWatch-independent failover after ARC observed-capacity gate" \
  --query 'executionId' \
  --output text)"
printf '%s\n' "${execution_id}" > "${STATE_DIR}/execution-id.txt"

completed=false
for _ in $(seq 1 120); do
  aws arc-region-switch get-plan-execution \
    --region "${STANDBY_REGION}" \
    --plan-arn "${plan_arn}" \
    --execution-id "${execution_id}" \
    --output json > "${STATE_DIR}/plan-execution.json"
  execution_state="$(jq -r '.executionState' "${STATE_DIR}/plan-execution.json")"
  case "${execution_state}" in
    completed|completedWithExceptions|completedMonitoringApplicationHealth)
      completed=true
      break
      ;;
    failed|canceled|planExecutionTimedOut|pausedByFailedStep)
      jq . "${STATE_DIR}/plan-execution.json" >&2
      exit 1
      ;;
  esac
  sleep 15
done

if [[ "${completed}" != true ]]; then
  echo "ARC execution did not complete within the polling window" >&2
  exit 1
fi

east_ready="$(kubectl --context arc-east \
  -n "${NAMESPACE}" \
  get deployment "${APP_NAME}" \
  -o jsonpath='{.status.readyReplicas}')"
if [[ "${east_ready}" -lt "${OBSERVED_PEAK_REPLICAS}" ]]; then
  echo "ARC completed but only ${east_ready} Ohio replicas are ready" >&2
  exit 1
fi

east_lb="$(jq -r '.east' "${STATE_DIR}/load-balancers.json")"
response_region="$(curl --silent --fail "http://${east_lb}/" | jq -r '.region')"
if [[ "${response_region}" != "${STANDBY_REGION}" ]]; then
  echo "Ohio endpoint validation returned ${response_region}" >&2
  exit 1
fi

aws arc-region-switch list-plan-execution-events \
  --region "${STANDBY_REGION}" \
  --plan-arn "${plan_arn}" \
  --execution-id "${execution_id}" \
  --output json > "${STATE_DIR}/plan-execution-events.json"

jq -n \
  --arg executionId "${execution_id}" \
  --arg planArn "${plan_arn}" \
  --argjson eastReady "${east_ready}" \
  --arg responseRegion "${response_region}" \
  --slurpfile execution "${STATE_DIR}/plan-execution.json" \
  '{
    executionId:$executionId,
    planArn:$planArn,
    mode:"ungraceful",
    cloudWatchGateBehavior:"skipped by ARC",
    executionState:$execution[0].executionState,
    destinationReadyReplicas:$eastReady,
    validatedApplicationRegion:$responseRegion,
    execution:$execution[0]
  }' | tee "${STATE_DIR}/failover-result.json"
