#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
assert_account

for state_file in load-balancers.json arc-resources.json; do
  [[ -f "${STATE_DIR}/${state_file}" ]] || {
    echo "Missing ${STATE_DIR}/${state_file}; run deploy.sh first" >&2
    exit 1
  }
done

kubectl --context arc-west \
  -n "${NAMESPACE}" \
  patch hpa "${APP_NAME}" \
  --type merge \
  -p "{\"spec\":{\"minReplicas\":${OBSERVED_PEAK_REPLICAS},\"maxReplicas\":${HPA_MAX_REPLICAS}}}"
kubectl --context arc-west \
  -n "${NAMESPACE}" \
  scale "deployment/${APP_NAME}" \
  --replicas="${OBSERVED_PEAK_REPLICAS}"
kubectl --context arc-west \
  -n "${NAMESPACE}" \
  rollout status "deployment/${APP_NAME}" \
  --timeout=30m

ready_replicas="$(kubectl --context arc-west \
  -n "${NAMESPACE}" \
  get deployment "${APP_NAME}" \
  -o jsonpath='{.status.readyReplicas}')"
if [[ "${ready_replicas}" -lt "${OBSERVED_PEAK_REPLICAS}" ]]; then
  echo "West has only ${ready_replicas} ready replicas; refusing to create the ARC plan" >&2
  exit 1
fi

west_lb="$(jq -r '.west' "${STATE_DIR}/load-balancers.json")"
if ! command -v hey >/dev/null 2>&1; then
  machine_arch="$(uname -m)"
  case "${machine_arch}" in
    x86_64) hey_arch="amd64" ;;
    aarch64|arm64) hey_arch="arm64" ;;
    *) echo "Unsupported architecture: ${machine_arch}" >&2; exit 1 ;;
  esac
  curl --silent --location \
    "https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_${hey_arch}" \
    --output "${STATE_DIR}/hey"
  chmod +x "${STATE_DIR}/hey"
  export PATH="${STATE_DIR}:${PATH}"
fi

hey \
  -z "${LOAD_TEST_DURATION}" \
  -c 100 \
  -q 10 \
  "http://${west_lb}/" \
  | tee "${STATE_DIR}/west-load-test.txt"

west_successes="$(awk '
  /Status code distribution:/ {capture=1; next}
  capture && $1 == "[200]" {print $2; exit}
' "${STATE_DIR}/west-load-test.txt")"
west_total_responses="$(awk '
  /Status code distribution:/ {capture=1; next}
  capture && $1 ~ /^\[[0-9]+\]$/ {sum += $2}
  END {print sum + 0}
' "${STATE_DIR}/west-load-test.txt")"
if [[ -z "${west_successes}" || "${west_total_responses}" -eq 0 ]]; then
  echo "The 1,000 TPS West load test did not report HTTP 200 responses" >&2
  exit 1
fi
west_availability="$(awk -v ok="${west_successes}" -v total="${west_total_responses}" \
  'BEGIN {printf "%.4f", (ok / total) * 100}')"
aws cloudwatch put-metric-data \
  --region "${PRIMARY_REGION}" \
  --namespace ArcEks24hLab \
  --metric-data \
  "MetricName=AvailabilityPercent,Dimensions=[{Name=Service,Value=${APP_NAME}},{Name=Region,Value=${PRIMARY_REGION}}],Value=${west_availability},Unit=Percent"
jq -n \
  --argjson successes "${west_successes}" \
  --argjson total "${west_total_responses}" \
  --argjson availability "${west_availability}" \
  '{successes:$successes,total:$total,availabilityPercent:$availability}' \
  > "${STATE_DIR}/west-availability.json"

west_cluster_arn="$(jq -r '.westClusterArn' "${STATE_DIR}/arc-resources.json")"
east_cluster_arn="$(jq -r '.eastClusterArn' "${STATE_DIR}/arc-resources.json")"
west_lambda_arn="$(jq -r '.westLambdaArn' "${STATE_DIR}/arc-resources.json")"
east_lambda_arn="$(jq -r '.eastLambdaArn' "${STATE_DIR}/arc-resources.json")"
execution_role_arn="$(jq -r '.executionRole' "${STATE_DIR}/arc-resources.json")"
east_lb="$(jq -r '.east' "${STATE_DIR}/load-balancers.json")"

jq -n \
  --arg zone "${HOSTED_ZONE_ID}" \
  --arg name "${RECORD_NAME}" \
  --arg west "${west_lb}" \
  --arg east "${east_lb}" \
  '{
    Comment:"Create ARC lab weighted records before attaching ARC health checks",
    Changes:[
      {
        Action:"UPSERT",
        ResourceRecordSet:{
          Name:$name,
          Type:"CNAME",
          SetIdentifier:"us-west-2-primary",
          Weight:100,
          TTL:30,
          ResourceRecords:[{Value:$west}]
        }
      },
      {
        Action:"UPSERT",
        ResourceRecordSet:{
          Name:$name,
          Type:"CNAME",
          SetIdentifier:"us-east-2-standby",
          Weight:0,
          TTL:30,
          ResourceRecords:[{Value:$east}]
        }
      }
    ]
  }' > "${STATE_DIR}/route53-before-plan.json"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${STATE_DIR}/route53-before-plan.json" \
  >/dev/null

jq -n \
  --arg description "ARC EKS observed-capacity lab: 24-hour replica maximum, 100 percent match" \
  --arg role "${execution_role_arn}" \
  --arg name "${PLAN_NAME}" \
  --arg primary "${PRIMARY_REGION}" \
  --arg standby "${STANDBY_REGION}" \
  --arg westCluster "${west_cluster_arn}" \
  --arg eastCluster "${east_cluster_arn}" \
  --arg westLambda "${west_lambda_arn}" \
  --arg eastLambda "${east_lambda_arn}" \
  --arg namespace "${NAMESPACE}" \
  --arg app "${APP_NAME}" \
  --arg zone "${HOSTED_ZONE_ID}" \
  --arg record "${RECORD_NAME}" \
  --argjson targetPercent "${TARGET_PERCENT}" \
  '{
    description:$description,
    workflows:[{
      steps:[
        {
          name:"Availability signal gate",
          description:"Graceful mode checks CloudWatch; missing data fails open. Ungraceful mode skips this dependency.",
          executionBlockConfiguration:{
            customActionLambdaConfig:{
              timeoutMinutes:2,
              lambdas:[{arn:$westLambda},{arn:$eastLambda}],
              retryIntervalMinutes:0.5,
              regionToRun:"activatingRegion",
              ungraceful:{behavior:"skip"}
            }
          },
          executionBlockType:"CustomActionLambda"
        },
        {
          name:"Pre-scale EKS to observed 24-hour maximum",
          description:"Match 100 percent of ARC sampled max; do not use HPA max as the recovery target.",
          executionBlockConfiguration:{
            eksResourceScalingConfig:{
              timeoutMinutes:25,
              kubernetesResourceType:{apiVersion:"apps/v1",kind:"Deployment"},
              scalingResources:[
                {
                  ($app):{
                    ($primary):{namespace:$namespace,name:$app,hpaName:$app},
                    ($standby):{namespace:$namespace,name:$app,hpaName:$app}
                  }
                }
              ],
              eksClusters:[{clusterArn:$westCluster},{clusterArn:$eastCluster}],
              ungraceful:{minimumSuccessPercentage:100},
              targetPercent:$targetPercent,
              capacityMonitoringApproach:"sampledMaxInLast24Hours"
            }
          },
          executionBlockType:"EKSResourceScaling"
        },
        {
          name:"Shift Route 53 traffic to Ohio",
          description:"ARC changes highly available health-check state; weighted records remain 100 West and 0 East.",
          executionBlockConfiguration:{
            route53HealthCheckConfig:{
              timeoutMinutes:5,
              hostedZoneId:$zone,
              recordName:$record,
              recordSets:[
                {recordSetIdentifier:"us-west-2-primary",region:$primary},
                {recordSetIdentifier:"us-east-2-standby",region:$standby}
              ]
            }
          },
          executionBlockType:"Route53HealthCheck"
        }
      ],
      workflowTargetAction:"activate",
      workflowTargetRegion:$standby,
      workflowDescription:"Activate Ohio from Oregon"
    }],
    executionRole:$role,
    recoveryTimeObjectiveMinutes:30,
    name:$name,
    regions:[$primary,$standby],
    recoveryApproach:"activePassive",
    primaryRegion:$primary,
    tags:{Project:"arc-eks-24h-lab",Environment:"experiment"}
  }' > "${STATE_DIR}/create-plan.json"

plan_arn="$(aws arc-region-switch list-plans \
  --region "${PLAN_CONTROL_REGION}" \
  --query "plans[?name=='${PLAN_NAME}'].arn | [0]" \
  --output text)"
if [[ "${plan_arn}" == "None" || -z "${plan_arn}" ]]; then
  plan_arn="$(aws arc-region-switch create-plan \
    --region "${PLAN_CONTROL_REGION}" \
    --cli-input-json "file://${STATE_DIR}/create-plan.json" \
    --query 'plan.arn' \
    --output text)"
fi
printf '%s\n' "${plan_arn}" > "${STATE_DIR}/plan-arn.txt"

wait_for_command 40 15 bash -c \
  "aws arc-region-switch list-route53-health-checks --region '${PLAN_CONTROL_REGION}' --arn '${plan_arn}' --hosted-zone-id '${HOSTED_ZONE_ID}' --record-name '${RECORD_NAME}' --query 'length(healthChecks)' --output text | grep -q '^2$'"

aws arc-region-switch list-route53-health-checks \
  --region "${PLAN_CONTROL_REGION}" \
  --arn "${plan_arn}" \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --record-name "${RECORD_NAME}" \
  --output json > "${STATE_DIR}/arc-health-checks.json"
west_health_check="$(jq -r --arg region "${PRIMARY_REGION}" '.healthChecks[] | select(.region==$region) | .healthCheckId' "${STATE_DIR}/arc-health-checks.json")"
east_health_check="$(jq -r --arg region "${STANDBY_REGION}" '.healthChecks[] | select(.region==$region) | .healthCheckId' "${STATE_DIR}/arc-health-checks.json")"

jq -n \
  --arg name "${RECORD_NAME}" \
  --arg west "${west_lb}" \
  --arg east "${east_lb}" \
  --arg westHealth "${west_health_check}" \
  --arg eastHealth "${east_health_check}" \
  '{
    Comment:"Attach ARC health checks to weighted records",
    Changes:[
      {
        Action:"UPSERT",
        ResourceRecordSet:{
          Name:$name,
          Type:"CNAME",
          SetIdentifier:"us-west-2-primary",
          Weight:100,
          TTL:30,
          ResourceRecords:[{Value:$west}],
          HealthCheckId:$westHealth
        }
      },
      {
        Action:"UPSERT",
        ResourceRecordSet:{
          Name:$name,
          Type:"CNAME",
          SetIdentifier:"us-east-2-standby",
          Weight:0,
          TTL:30,
          ResourceRecords:[{Value:$east}],
          HealthCheckId:$eastHealth
        }
      }
    ]
  }' > "${STATE_DIR}/route53-with-health-checks.json"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${STATE_DIR}/route53-with-health-checks.json" \
  >/dev/null

evaluation_passed=false
for _ in $(seq 1 80); do
  aws arc-region-switch get-plan-evaluation-status \
    --region "${PLAN_CONTROL_REGION}" \
    --plan-arn "${plan_arn}" \
    --output json > "${STATE_DIR}/plan-evaluation.json"
  evaluation_state="$(jq -r '.evaluationState' "${STATE_DIR}/plan-evaluation.json")"
  active_warnings="$(jq '[.warnings[]? | select(.warningStatus=="active")] | length' "${STATE_DIR}/plan-evaluation.json")"
  if [[ "${evaluation_state}" == "passed" && "${active_warnings}" == "0" ]]; then
    evaluation_passed=true
    break
  fi
  sleep 30
done

if [[ "${evaluation_passed}" != true ]]; then
  echo "ARC plan evaluation did not pass; failover is blocked" >&2
  jq . "${STATE_DIR}/plan-evaluation.json" >&2
  exit 1
fi

jq -n \
  --arg planArn "${plan_arn}" \
  --argjson observedPeak "${OBSERVED_PEAK_REPLICAS}" \
  --argjson hpaMax "${HPA_MAX_REPLICAS}" \
  --argjson targetPercent "${TARGET_PERCENT}" \
  --slurpfile evaluation "${STATE_DIR}/plan-evaluation.json" \
  '{
    planArn:$planArn,
    sourceReadyReplicas:$observedPeak,
    hpaMaximum:$hpaMax,
    targetPercent:$targetPercent,
    capacityMonitoringApproach:"sampledMaxInLast24Hours",
    precondition:"ARC evaluation passed with replica history collected",
    evaluation:$evaluation[0]
  }' | tee "${STATE_DIR}/history-gate.json"
