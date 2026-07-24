#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
assert_account

west_cluster_arn="$(aws eks describe-cluster \
  --region "${PRIMARY_REGION}" \
  --name "${PRIMARY_CLUSTER}" \
  --query 'cluster.arn' \
  --output text)"
east_cluster_arn="$(aws eks describe-cluster \
  --region "${STANDBY_REGION}" \
  --name "${STANDBY_CLUSTER}" \
  --query 'cluster.arn' \
  --output text)"

lambda_role_name="ArcEks24hAvailabilityGateRole"
lambda_role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${lambda_role_name}"
if ! aws iam get-role --role-name "${lambda_role_name}" >/dev/null 2>&1; then
  jq -n '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Service:"lambda.amazonaws.com"},
      Action:"sts:AssumeRole"
    }]
  }' > "${STATE_DIR}/lambda-trust.json"
  aws iam create-role \
    --role-name "${lambda_role_name}" \
    --assume-role-policy-document "file://${STATE_DIR}/lambda-trust.json" \
    >/dev/null
  aws iam attach-role-policy \
    --role-name "${lambda_role_name}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam put-role-policy \
    --role-name "${lambda_role_name}" \
    --policy-name DescribeAvailabilityAlarm \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"cloudwatch:DescribeAlarms","Resource":"*"}]}'
  sleep 10
fi

rm -f "${STATE_DIR}/availability-gate.zip"
(
  cd "${LAB_ROOT}/lambda"
  zip -q "${STATE_DIR}/availability-gate.zip" availability_gate.py
)

for region_name in "${PRIMARY_REGION}" "${STANDBY_REGION}"; do
  alarm_name="arc-eks-24h-availability-${region_name}"
  aws cloudwatch put-metric-alarm \
    --region "${region_name}" \
    --alarm-name "${alarm_name}" \
    --namespace ArcEks24hLab \
    --metric-name AvailabilityPercent \
    --dimensions Name=Service,Value="${APP_NAME}" Name=Region,Value="${region_name}" \
    --statistic Average \
    --period 60 \
    --evaluation-periods 3 \
    --datapoints-to-alarm 2 \
    --threshold 97 \
    --comparison-operator LessThanThreshold \
    --treat-missing-data missing

  aws cloudwatch put-metric-data \
    --region "${region_name}" \
    --namespace ArcEks24hLab \
    --metric-data "MetricName=AvailabilityPercent,Dimensions=[{Name=Service,Value=${APP_NAME}},{Name=Region,Value=${region_name}}],Value=100,Unit=Percent"

  function_name="arc-eks-24h-availability-gate"
  if aws lambda get-function --region "${region_name}" --function-name "${function_name}" >/dev/null 2>&1; then
    aws lambda update-function-code \
      --region "${region_name}" \
      --function-name "${function_name}" \
      --zip-file "fileb://${STATE_DIR}/availability-gate.zip" \
      >/dev/null
    aws lambda wait function-updated-v2 \
      --region "${region_name}" \
      --function-name "${function_name}"
    aws lambda update-function-configuration \
      --region "${region_name}" \
      --function-name "${function_name}" \
      --environment "Variables={ALARM_NAME=${alarm_name},FAIL_OPEN_ON_MISSING=true}" \
      >/dev/null
    aws lambda wait function-updated-v2 \
      --region "${region_name}" \
      --function-name "${function_name}"
  else
    aws lambda create-function \
      --region "${region_name}" \
      --function-name "${function_name}" \
      --runtime python3.13 \
      --handler availability_gate.handler \
      --role "${lambda_role_arn}" \
      --zip-file "fileb://${STATE_DIR}/availability-gate.zip" \
      --timeout 10 \
      --memory-size 128 \
      --environment "Variables={ALARM_NAME=${alarm_name},FAIL_OPEN_ON_MISSING=true}" \
      --tags Project="${EXPERIMENT_TAG}" \
      >/dev/null
    aws lambda wait function-active-v2 --region "${region_name}" --function-name "${function_name}"
  fi
done

execution_role_name="ArcEks24hRegionSwitchExecutionRole"
execution_role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${execution_role_name}"
if ! aws iam get-role --role-name "${execution_role_name}" >/dev/null 2>&1; then
  jq -n '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Service:"arc-region-switch.amazonaws.com"},
      Action:"sts:AssumeRole"
    }]
  }' > "${STATE_DIR}/arc-trust.json"
  aws iam create-role \
    --role-name "${execution_role_name}" \
    --assume-role-policy-document "file://${STATE_DIR}/arc-trust.json" \
    >/dev/null
fi

west_lambda_arn="arn:aws:lambda:${PRIMARY_REGION}:${ACCOUNT_ID}:function:arc-eks-24h-availability-gate"
east_lambda_arn="arn:aws:lambda:${STANDBY_REGION}:${ACCOUNT_ID}:function:arc-eks-24h-availability-gate"
jq -n \
  --arg role "${execution_role_arn}" \
  --arg westCluster "${west_cluster_arn}" \
  --arg eastCluster "${east_cluster_arn}" \
  --arg westLambda "${west_lambda_arn}" \
  --arg eastLambda "${east_lambda_arn}" \
  --arg zone "${HOSTED_ZONE_ID}" \
  '{
    Version:"2012-10-17",
    Statement:[
      {
        Effect:"Allow",
        Action:"iam:SimulatePrincipalPolicy",
        Resource:$role
      },
      {
        Effect:"Allow",
        Action:["eks:DescribeCluster"],
        Resource:[$westCluster,$eastCluster]
      },
      {
        Effect:"Allow",
        Action:["eks:ListAssociatedAccessPolicies"],
        Resource:"*"
      },
      {
        Effect:"Allow",
        Action:["lambda:GetFunction","lambda:InvokeFunction"],
        Resource:[$westLambda,$eastLambda]
      },
      {
        Effect:"Allow",
        Action:"route53:ListResourceRecordSets",
        Resource:("arn:aws:route53:::hostedzone/"+$zone)
      }
    ]
  }' > "${STATE_DIR}/arc-execution-policy.json"
aws iam put-role-policy \
  --role-name "${execution_role_name}" \
  --policy-name ArcEks24hExecution \
  --policy-document "file://${STATE_DIR}/arc-execution-policy.json"

ensure_access_entry() {
  local region_name="$1"
  local cluster_id="$2"
  local principal_arn="$3"
  if aws eks describe-access-entry \
    --region "${region_name}" \
    --cluster-name "${cluster_id}" \
    --principal-arn "${principal_arn}" \
    >/dev/null 2>&1; then
    return 0
  fi
  aws eks create-access-entry \
    --region "${region_name}" \
    --cluster-name "${cluster_id}" \
    --principal-arn "${principal_arn}" \
    --type STANDARD \
    >/dev/null
}

for region_name in "${PRIMARY_REGION}" "${STANDBY_REGION}"; do
  cluster_id="$(cluster_name "${region_name}")"
  wait_for_command 24 5 \
    ensure_access_entry \
    "${region_name}" \
    "${cluster_id}" \
    "${execution_role_arn}"
  aws eks associate-access-policy \
    --region "${region_name}" \
    --cluster-name "${cluster_id}" \
    --principal-arn "${execution_role_arn}" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonARCRegionSwitchScalingPolicy \
    --access-scope "type=namespace,namespaces=${NAMESPACE}" \
    >/dev/null
done

jq -n \
  --arg role "${execution_role_arn}" \
  --arg westCluster "${west_cluster_arn}" \
  --arg eastCluster "${east_cluster_arn}" \
  --arg westLambda "${west_lambda_arn}" \
  --arg eastLambda "${east_lambda_arn}" \
  '{
    executionRole:$role,
    westClusterArn:$westCluster,
    eastClusterArn:$eastCluster,
    westLambdaArn:$westLambda,
    eastLambdaArn:$eastLambda
  }' | tee "${STATE_DIR}/arc-resources.json"
