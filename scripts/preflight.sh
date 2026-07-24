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
  target_cluster="$(cluster_name "${region_name}")"
  cluster_quota="$(aws service-quotas list-service-quotas \
    --service-code eks \
    --region "${region_name}" \
    --query "Quotas[?QuotaName=='Clusters'].Value | [0]" \
    --output text)"
  cluster_usage="$(aws eks list-clusters --region "${region_name}" --query 'length(clusters)' --output text)"
  cluster_needed=1
  if aws eks describe-cluster --region "${region_name}" --name "${target_cluster}" >/dev/null 2>&1; then
    cluster_needed=0
  fi
  vcpu_quota="$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-1216C47A \
    --region "${region_name}" \
    --query 'Quota.Value' \
    --output text)"
  running_instances_json="$(aws ec2 describe-instances \
    --region "${region_name}" \
    --filters Name=instance-state-name,Values=pending,running \
    --output json)"
  running_instances="$(jq '[.Reservations[].Instances[]] | length' <<<"${running_instances_json}")"
  running_vcpus="$(jq '[.Reservations[].Instances[] | (.CpuOptions.CoreCount * .CpuOptions.ThreadsPerCore)] | add // 0' <<<"${running_instances_json}")"
  vpc_usage="$(aws ec2 describe-vpcs --region "${region_name}" --query 'length(Vpcs)' --output text)"
  vpc_needed=1
  if aws eks describe-cluster --region "${region_name}" --name "${target_cluster}" >/dev/null 2>&1; then
    vpc_needed=0
  fi

  eip_quota="$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-0263D0A3 \
    --region "${region_name}" \
    --query 'Quota.Value' \
    --output text)"
  eip_usage="$(aws ec2 describe-addresses --region "${region_name}" --query 'length(Addresses)' --output text)"
  lab_nat_count="$(aws ec2 describe-nat-gateways \
    --region "${region_name}" \
    --filter Name=tag:Project,Values="${EXPERIMENT_TAG}" Name=state,Values=pending,available \
    --query 'length(NatGateways)' \
    --output text)"
  eip_needed=1
  [[ "${lab_nat_count}" -gt 0 ]] && eip_needed=0

  nat_quota="$(aws service-quotas get-service-quota \
    --service-code vpc \
    --quota-code L-FE5A380F \
    --region "${region_name}" \
    --query 'Quota.Value' \
    --output text)"
  nlb_quota="$(aws service-quotas get-service-quota \
    --service-code elasticloadbalancing \
    --quota-code L-69A177A2 \
    --region "${region_name}" \
    --query 'Quota.Value' \
    --output text)"
  nlb_usage="$(aws elbv2 describe-load-balancers \
    --region "${region_name}" \
    --query "length(LoadBalancers[?Type=='network'])" \
    --output text)"
  nlb_needed=1

  awk -v quota="${cluster_quota}" -v usage="${cluster_usage}" -v needed="${cluster_needed}" \
    'BEGIN { if (usage + needed > quota) exit 1 }' || {
      echo "Insufficient EKS cluster quota in ${region_name}" >&2
      exit 1
    }

  # Four m7i.xlarge nodes are 16 vCPUs; reserve four more for managed surge.
  awk -v quota="${vcpu_quota}" -v usage="${running_vcpus}" \
    'BEGIN { if (usage + 20 > quota) exit 1 }' || {
      echo "Insufficient Standard On-Demand vCPU quota in ${region_name}" >&2
      exit 1
    }

  awk -v usage="${vpc_usage}" -v needed="${vpc_needed}" \
    'BEGIN { if (usage + needed > 5) exit 1 }' || {
      echo "Insufficient VPC quota in ${region_name}" >&2
      exit 1
    }

  awk -v quota="${eip_quota}" -v usage="${eip_usage}" -v needed="${eip_needed}" \
    'BEGIN { if (usage + needed > quota) exit 1 }' || {
      echo "Insufficient Elastic IP quota for the lab NAT gateway in ${region_name}" >&2
      exit 1
    }

  awk -v quota="${nat_quota}" 'BEGIN { if (quota < 1) exit 1 }' || {
    echo "NAT gateway quota is unavailable in ${region_name}" >&2
    exit 1
  }

  awk -v quota="${nlb_quota}" -v usage="${nlb_usage}" -v needed="${nlb_needed}" \
    'BEGIN { if (usage + needed > quota) exit 1 }' || {
      echo "Insufficient Network Load Balancer quota in ${region_name}" >&2
      exit 1
    }

  jq -n \
    --arg region "${region_name}" \
    --argjson clusterQuota "${cluster_quota}" \
    --argjson clusterUsage "${cluster_usage}" \
    --argjson clusterNeeded "${cluster_needed}" \
    --argjson vcpuQuota "${vcpu_quota}" \
    --argjson runningVcpus "${running_vcpus}" \
    --argjson runningInstances "${running_instances}" \
    --argjson vpcUsage "${vpc_usage}" \
    --argjson eipQuota "${eip_quota}" \
    --argjson eipUsage "${eip_usage}" \
    --argjson eipNeeded "${eip_needed}" \
    --argjson natGatewaysPerAzQuota "${nat_quota}" \
    --argjson nlbQuota "${nlb_quota}" \
    --argjson nlbUsage "${nlb_usage}" \
    '{
      region:$region,
      eks:{quota:$clusterQuota,current:$clusterUsage,additionalNeeded:$clusterNeeded},
      ec2:{standardVcpuQuota:$vcpuQuota,runningVcpus:$runningVcpus,runningInstances:$runningInstances,targetSurgeVcpus:20},
      networking:{
        vpcUsage:$vpcUsage,
        elasticIpQuota:$eipQuota,
        elasticIpUsage:$eipUsage,
        elasticIpAdditionalNeeded:$eipNeeded,
        natGatewaysPerAzQuota:$natGatewaysPerAzQuota,
        networkLoadBalancerQuota:$nlbQuota,
        networkLoadBalancerUsage:$nlbUsage
      }
    }'
done

health_check_limit="$(aws route53 get-account-limit \
  --type MAX_HEALTH_CHECKS_BY_OWNER \
  --query 'Limit.Value' \
  --output text)"
health_check_usage="$(aws route53 list-health-checks --query 'length(HealthChecks)' --output text)"
awk -v quota="${health_check_limit}" -v usage="${health_check_usage}" \
  'BEGIN { if (usage + 2 > quota) exit 1 }' || {
    echo "Insufficient Route 53 health-check quota" >&2
    exit 1
  }

iam_summary="$(aws iam get-account-summary --query 'SummaryMap' --output json)"
iam_roles="$(jq -r '.Roles' <<<"${iam_summary}")"
iam_role_quota="$(jq -r '.RolesQuota' <<<"${iam_summary}")"
awk -v quota="${iam_role_quota}" -v usage="${iam_roles}" \
  'BEGIN { if (usage + 3 > quota) exit 1 }' || {
    echo "Insufficient IAM role quota" >&2
    exit 1
  }

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
    route53HealthChecks:{quota:'"${health_check_limit}"',current:'"${health_check_usage}"',afterLab:('"${health_check_usage}"'+2)},
    iamRoles:{quota:'"${iam_role_quota}"',current:'"${iam_roles}"',afterLab:('"${iam_roles}"'+3)},
    estimatedReadyUsdPerHour:1.45,
    estimatedFailoverPeakUsdPerHour:2.20,
    variableDynamoDbAndLoadBalancerTrafficExcluded:false
  }' | tee "${STATE_DIR}/preflight.json"
