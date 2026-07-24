#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
assert_account
prime_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for command_name in aws jq kubectl; do
  require_command "${command_name}"
done

aws eks update-kubeconfig \
  --region "${PRIMARY_REGION}" \
  --name "${PRIMARY_CLUSTER}" \
  --alias arc-west
aws eks update-kubeconfig \
  --region "${STANDBY_REGION}" \
  --name "${STANDBY_CLUSTER}" \
  --alias arc-east

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
load_job="arc-observed-capacity-load"
if [[ "${REUSE_VALID_LOAD:-false}" == "true" ]] \
  && [[ -s "${STATE_DIR}/west-load-test.txt" ]] \
  && jq -e \
    '(.totalAttempts // .total) > 0
      and .successes > 0
      and .availabilityPercent >= 97' \
    "${STATE_DIR}/west-availability.json" \
    >/dev/null 2>&1; then
  echo "Reusing the prior valid West load evidence while 20 replicas remain ready"
else
kubectl --context arc-west \
  -n "${NAMESPACE}" \
  delete job "${load_job}" \
  --ignore-not-found=true \
  --wait=true \
  >/dev/null
jq -n \
  --arg namespace "${NAMESPACE}" \
  --arg job "${load_job}" \
  --arg duration "${LOAD_TEST_DURATION}" \
  --arg endpoint "http://${west_lb}/" \
  '{
    apiVersion:"batch/v1",
    kind:"Job",
    metadata:{name:$job,namespace:$namespace},
    spec:{
      backoffLimit:0,
      ttlSecondsAfterFinished:600,
      template:{
        metadata:{labels:{app:$job}},
        spec:{
          restartPolicy:"Never",
          nodeSelector:{"node.kubernetes.io/instance-type":"m7i.xlarge"},
          containers:[{
            name:"hey",
            image:"alpine:3.22",
            command:["/bin/sh","-c"],
            args:[(
              "set -eu; " +
              "wget -q https://storage.googleapis.com/hey-releases/hey_linux_amd64 -O /tmp/hey; " +
              "chmod +x /tmp/hey; " +
              "/tmp/hey -z " + $duration + " -c 100 -q 10 " + $endpoint
            )],
            resources:{
              requests:{cpu:"1",memory:"512Mi"},
              limits:{cpu:"2",memory:"1Gi"}
            }
          }]
        }
      }
    }
  }' > "${STATE_DIR}/load-job.json"
kubectl --context arc-west apply -f "${STATE_DIR}/load-job.json"
if ! kubectl --context arc-west \
  -n "${NAMESPACE}" \
  wait \
  --for=condition=complete \
  "job/${load_job}" \
  --timeout=10m; then
  kubectl --context arc-west -n "${NAMESPACE}" logs "job/${load_job}" >&2 || true
  exit 1
fi
kubectl --context arc-west \
  -n "${NAMESPACE}" \
  logs "job/${load_job}" \
  | tee "${STATE_DIR}/west-load-test.txt"

west_successes="$(awk '
  /Status code distribution:/ {capture=1; next}
  capture && $1 == "[200]" {print $2; exit}
' "${STATE_DIR}/west-load-test.txt")"
west_total_responses="$(awk '
  /Status code distribution:/ {capture=1; next}
  /Error distribution:/ {capture=0}
  capture && $1 ~ /^\[[0-9]+\]$/ {sum += $2}
  END {print sum + 0}
' "${STATE_DIR}/west-load-test.txt")"
west_transport_errors="$(awk '
  /Error distribution:/ {capture=1; next}
  capture && $1 ~ /^\[[0-9]+\]$/ {
    count=$1
    gsub(/[][]/, "", count)
    sum += count
  }
  END {print sum + 0}
' "${STATE_DIR}/west-load-test.txt")"
if [[ -z "${west_successes}" || "${west_total_responses}" -eq 0 ]]; then
  echo "The 1,000 TPS West load test did not report HTTP 200 responses" >&2
  exit 1
fi
west_total_attempts="$((west_total_responses + west_transport_errors))"
west_availability="$(awk -v ok="${west_successes}" -v total="${west_total_attempts}" \
  'BEGIN {printf "%.4f", (ok / total) * 100}')"
west_requests_per_second="$(awk '/Requests\/sec:/ {print $2; exit}' "${STATE_DIR}/west-load-test.txt")"
aws cloudwatch put-metric-data \
  --region "${PRIMARY_REGION}" \
  --namespace ArcEks24hLab \
  --metric-data \
  "MetricName=AvailabilityPercent,Dimensions=[{Name=Service,Value=${APP_NAME}},{Name=Region,Value=${PRIMARY_REGION}}],Value=${west_availability},Unit=Percent"
jq -n \
  --argjson successes "${west_successes}" \
  --argjson httpResponses "${west_total_responses}" \
  --argjson transportErrors "${west_transport_errors}" \
  --argjson total "${west_total_attempts}" \
  --argjson availability "${west_availability}" \
  --argjson requestsPerSecond "${west_requests_per_second}" \
  '{
    successes:$successes,
    httpResponses:$httpResponses,
    transportErrors:$transportErrors,
    totalAttempts:$total,
    availabilityPercent:$availability,
    requestsPerSecond:$requestsPerSecond
  }' \
  > "${STATE_DIR}/west-availability.json"
fi

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
  'def activationWorkflow($targetRegion; $workflowDescription):
    {
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
              ungraceful:{minimumSuccessPercentage:99},
              targetPercent:$targetPercent,
              capacityMonitoringApproach:"sampledMaxInLast24Hours"
            }
          },
          executionBlockType:"EKSResourceScaling"
        },
        {
          name:"Shift Route 53 traffic to activating Region",
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
      workflowTargetRegion:$targetRegion,
      workflowDescription:$workflowDescription
    };
  {
    description:$description,
    workflows:[
      activationWorkflow($standby; "Activate Ohio from Oregon"),
      activationWorkflow($primary; "Activate Oregon from Ohio")
    ],
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
plan_created_epoch="$(date +%s)"
plan_created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

arc_health_checks_are_ready() {
  aws arc-region-switch list-route53-health-checks \
    --region "${PLAN_CONTROL_REGION}" \
    --arn "${plan_arn}" \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --record-name "${RECORD_NAME}" \
    --output json \
  | jq -e \
    '(.healthChecks | length) == 2
      and all(.healthChecks[]; ((.healthCheckId // "") | length) > 0)' \
    >/dev/null
}
wait_for_command 40 15 arc_health_checks_are_ready

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

# Creating the plan starts an evaluation before the vended health checks can be
# attached. Updating the now-complete plan starts a fresh immediate evaluation
# instead of waiting for the next 30-minute steady-state cycle.
jq \
  --arg arn "${plan_arn}" \
  '. + {arn:$arn}
    | del(.name, .regions, .recoveryApproach, .primaryRegion, .tags)' \
  "${STATE_DIR}/create-plan.json" \
  > "${STATE_DIR}/update-plan.json"
aws arc-region-switch update-plan \
  --region "${PLAN_CONTROL_REGION}" \
  --cli-input-json "file://${STATE_DIR}/update-plan.json" \
  >/dev/null
plan_created_epoch="$(date +%s)"
plan_created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
evaluation_passed_epoch="$(date +%s)"
evaluation_passed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
plan_evaluation_minutes="$(awk \
  -v start="${plan_created_epoch}" \
  -v finish="${evaluation_passed_epoch}" \
  'BEGIN {printf "%.2f", (finish-start)/60}')"

jq -n \
  --arg planArn "${plan_arn}" \
  --arg primeStartedAt "${prime_started_at}" \
  --arg planCreatedAt "${plan_created_at}" \
  --arg evaluationPassedAt "${evaluation_passed_at}" \
  --argjson observedPeak "${OBSERVED_PEAK_REPLICAS}" \
  --argjson hpaMax "${HPA_MAX_REPLICAS}" \
  --argjson targetPercent "${TARGET_PERCENT}" \
  --argjson planEvaluationMinutes "${plan_evaluation_minutes}" \
  --slurpfile availability "${STATE_DIR}/west-availability.json" \
  --slurpfile evaluation "${STATE_DIR}/plan-evaluation.json" \
  '{
    planArn:$planArn,
    primeStartedAt:$primeStartedAt,
    planCreatedAt:$planCreatedAt,
    evaluationPassedAt:$evaluationPassedAt,
    planEvaluationMinutes:$planEvaluationMinutes,
    sourceReadyReplicas:$observedPeak,
    hpaMaximum:$hpaMax,
    targetPercent:$targetPercent,
    capacityMonitoringApproach:"sampledMaxInLast24Hours",
    precondition:"ARC evaluation passed with replica history collected",
    loadTest:$availability[0],
    evaluation:$evaluation[0]
  }' | tee "${STATE_DIR}/history-gate.json"
