#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

for command_name in aws jq awk; do
  require_command "${command_name}"
done

assert_account

for region_name in "${PRIMARY_REGION}" "${STANDBY_REGION}"; do
  cluster_quota="$(aws service-quotas list-service-quotas \
    --service-code eks \
    --region "${region_name}" \
    --query "Quotas[?QuotaName=='Clusters'].Value | [0]" \
    --output text)"
  cluster_usage="$(aws eks list-clusters --region "${region_name}" --query 'length(clusters)' --output text)"
  vcpu_quota="$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-1216C47A \
    --region "${region_name}" \
    --query 'Quota.Value' \
    --output text)"
  running_instances="$(aws ec2 describe-instances \
    --region "${region_name}" \
    --filters Name=instance-state-name,Values=pending,running \
    --query 'length(Reservations[].Instances[])' \
    --output text)"
  vpc_usage="$(aws ec2 describe-vpcs --region "${region_name}" --query 'length(Vpcs)' --output text)"

  awk -v quota="${cluster_quota}" -v usage="${cluster_usage}" \
    'BEGIN { if (usage + 1 > quota) exit 1 }' || {
      echo "Insufficient EKS cluster quota in ${region_name}" >&2
      exit 1
    }

  # Four m7i.xlarge nodes is a 16-vCPU regional ceiling for this lab.
  awk -v quota="${vcpu_quota}" 'BEGIN { if (quota < 20) exit 1 }' || {
    echo "Insufficient Standard On-Demand vCPU quota in ${region_name}" >&2
    exit 1
  }

  awk -v usage="${vpc_usage}" 'BEGIN { if (usage + 1 > 5) exit 1 }' || {
    echo "Insufficient VPC quota in ${region_name}" >&2
    exit 1
  }

  jq -n \
    --arg region "${region_name}" \
    --argjson clusterQuota "${cluster_quota}" \
    --argjson clusterUsage "${cluster_usage}" \
    --argjson vcpuQuota "${vcpu_quota}" \
    --argjson runningInstances "${running_instances}" \
    --argjson vpcUsage "${vpc_usage}" \
    '{region:$region,clusterQuota:$clusterQuota,clusterUsage:$clusterUsage,vcpuQuota:$vcpuQuota,runningInstances:$runningInstances,vpcUsage:$vpcUsage}'
done

plan_quota="$(aws service-quotas get-service-quota \
  --service-code arc-region-switch \
  --quota-code L-74C86563 \
  --region "${GLOBAL_QUOTA_REGION}" \
  --query 'Quota.Value' \
  --output text)"
plan_usage="$(aws arc-region-switch list-plans \
  --region "${PLAN_CONTROL_REGION}" \
  --query 'length(plans)' \
  --output text)"

awk -v quota="${plan_quota}" -v usage="${plan_usage}" \
  'BEGIN { if (usage + 1 > quota) exit 1 }' || {
    echo "Insufficient ARC Region Switch plan quota" >&2
    exit 1
  }

aws route53 get-hosted-zone --id "${HOSTED_ZONE_ID}" >/dev/null

jq -n \
  --arg account "${ACCOUNT_ID}" \
  --arg primary "${PRIMARY_REGION}" \
  --arg standby "${STANDBY_REGION}" \
  --argjson planQuota "${plan_quota}" \
  --argjson planUsage "${plan_usage}" \
  --arg budgetStatus "PASS" \
  '{
    account:$account,
    regions:[$primary,$standby],
    arcPlans:{quota:$planQuota,current:$planUsage,afterLab:($planUsage+1)},
    budgetGate:$budgetStatus,
    estimatedReadyUsdPerHour:1.35,
    estimatedFailoverPeakUsdPerHour:2.10,
    variableDynamoDbAndLoadBalancerTrafficExcluded:false
  }' | tee "${STATE_DIR}/preflight.json"
