#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
assert_account

plan_arn="$(aws arc-region-switch list-plans \
  --region "${PLAN_CONTROL_REGION}" \
  --query "plans[?name=='${PLAN_NAME}'].arn | [0]" \
  --output text)"
if [[ "${plan_arn}" != "None" && -n "${plan_arn}" ]]; then
  aws arc-region-switch delete-plan \
    --region "${PLAN_CONTROL_REGION}" \
    --arn "${plan_arn}"
fi

jq -n \
  --arg name "${RECORD_NAME}" \
  --arg west "$(jq -r '.west' "${STATE_DIR}/load-balancers.json")" \
  --arg east "$(jq -r '.east' "${STATE_DIR}/load-balancers.json")" \
  --arg westHealth "$(jq -r --arg region "${PRIMARY_REGION}" '.healthChecks[] | select(.region==$region) | .healthCheckId' "${STATE_DIR}/arc-health-checks.json")" \
  --arg eastHealth "$(jq -r --arg region "${STANDBY_REGION}" '.healthChecks[] | select(.region==$region) | .healthCheckId' "${STATE_DIR}/arc-health-checks.json")" \
  '{
    Comment:"Delete ARC lab weighted records",
    Changes:[
      {Action:"DELETE",ResourceRecordSet:{Name:$name,Type:"CNAME",SetIdentifier:"us-west-2-primary",Weight:100,TTL:30,ResourceRecords:[{Value:$west}],HealthCheckId:$westHealth}},
      {Action:"DELETE",ResourceRecordSet:{Name:$name,Type:"CNAME",SetIdentifier:"us-east-2-standby",Weight:0,TTL:30,ResourceRecords:[{Value:$east}],HealthCheckId:$eastHealth}}
    ]
  }' > "${STATE_DIR}/route53-delete.json"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${STATE_DIR}/route53-delete.json" \
  >/dev/null 2>&1 || true

for region_name in "${PRIMARY_REGION}" "${STANDBY_REGION}"; do
  aws lambda delete-function \
    --region "${region_name}" \
    --function-name arc-eks-24h-availability-gate \
    >/dev/null 2>&1 || true
  aws cloudwatch delete-alarms \
    --region "${region_name}" \
    --alarm-names "arc-eks-24h-availability-${region_name}" \
    >/dev/null 2>&1 || true
done

eksctl delete cluster -f "${LAB_ROOT}/infra/cluster-west.yaml" --wait || true
eksctl delete cluster -f "${LAB_ROOT}/infra/cluster-east.yaml" --wait || true

aws dynamodb delete-table \
  --region "${PRIMARY_REGION}" \
  --table-name "${TABLE_NAME}" \
  >/dev/null 2>&1 || true

for role_name in ArcEks24hAvailabilityGateRole ArcEks24hRegionSwitchExecutionRole; do
  for policy_name in $(aws iam list-role-policies --role-name "${role_name}" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "${role_name}" --policy-name "${policy_name}"
  done
  for policy_arn in $(aws iam list-attached-role-policies --role-name "${role_name}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}"
  done
  aws iam delete-role --role-name "${role_name}" >/dev/null 2>&1 || true
done
