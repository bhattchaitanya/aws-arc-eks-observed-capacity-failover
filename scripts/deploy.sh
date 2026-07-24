#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

"${SCRIPT_DIR}/preflight.sh"
assert_account

for command_name in aws curl jq kubectl zip; do
  require_command "${command_name}"
done

machine_arch="$(uname -m)"
case "${machine_arch}" in
  x86_64) tool_arch="amd64" ;;
  aarch64|arm64) tool_arch="arm64" ;;
  *) echo "Unsupported architecture: ${machine_arch}" >&2; exit 1 ;;
esac

if ! command -v eksctl >/dev/null 2>&1; then
  curl --silent --location \
    "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${tool_arch}.tar.gz" \
    | tar xz -C "${STATE_DIR}"
  export PATH="${STATE_DIR}:${PATH}"
fi

eksctl create cluster --dry-run -f "${LAB_ROOT}/infra/cluster-west.yaml" >/dev/null
eksctl create cluster --dry-run -f "${LAB_ROOT}/infra/cluster-east.yaml" >/dev/null

create_cluster_if_missing() {
  local region_name="$1"
  local cluster_config="$2"
  local cluster_id
  cluster_id="$(cluster_name "${region_name}")"
  if ! aws eks describe-cluster --region "${region_name}" --name "${cluster_id}" >/dev/null 2>&1; then
    eksctl create cluster -f "${cluster_config}"
  fi
}

create_cluster_if_missing "${PRIMARY_REGION}" "${LAB_ROOT}/infra/cluster-west.yaml" &
west_pid=$!
create_cluster_if_missing "${STANDBY_REGION}" "${LAB_ROOT}/infra/cluster-east.yaml" &
east_pid=$!
wait "${west_pid}"
wait "${east_pid}"

if ! aws dynamodb describe-table --region "${PRIMARY_REGION}" --table-name "${TABLE_NAME}" >/dev/null 2>&1; then
  aws dynamodb create-table \
    --region "${PRIMARY_REGION}" \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value="${EXPERIMENT_TAG}"
  aws dynamodb wait table-exists --region "${PRIMARY_REGION}" --table-name "${TABLE_NAME}"
fi

if ! aws dynamodb describe-table \
  --region "${PRIMARY_REGION}" \
  --table-name "${TABLE_NAME}" \
  --query 'Table.Replicas[].RegionName' \
  --output text | grep -q "${STANDBY_REGION}"; then
  aws dynamodb update-table \
    --region "${PRIMARY_REGION}" \
    --table-name "${TABLE_NAME}" \
    --replica-updates "Create={RegionName=${STANDBY_REGION}}"
fi

wait_for_command 60 20 bash -c \
  "aws dynamodb describe-table --region '${STANDBY_REGION}' --table-name '${TABLE_NAME}' --query 'Table.TableStatus' --output text 2>/dev/null | grep -q ACTIVE"

for item_number in $(seq 0 99); do
  aws dynamodb put-item \
    --region "${PRIMARY_REGION}" \
    --table-name "${TABLE_NAME}" \
    --item "{\"pk\":{\"S\":\"item-${item_number}\"},\"payload\":{\"S\":\"ARC observed-capacity lab\"}}" \
    >/dev/null
done

attach_node_policy() {
  local region_name="$1"
  local cluster_id node_role_arn node_role_name
  cluster_id="$(cluster_name "${region_name}")"
  node_role_arn="$(aws eks describe-cluster \
    --region "${region_name}" \
    --name "${cluster_id}" \
    --query 'cluster.computeConfig.nodeRoleArn' \
    --output text)"
  node_role_name="${node_role_arn##*/}"
  jq -n \
    --arg account "${ACCOUNT_ID}" \
    --arg table "${TABLE_NAME}" \
    --arg primary "${PRIMARY_REGION}" \
    --arg standby "${STANDBY_REGION}" \
    '{
      Version:"2012-10-17",
      Statement:[{
        Effect:"Allow",
        Action:["dynamodb:GetItem","dynamodb:UpdateItem","dynamodb:PutItem","dynamodb:DescribeTable"],
        Resource:[
          ("arn:aws:dynamodb:"+$primary+":"+$account+":table/"+$table),
          ("arn:aws:dynamodb:"+$standby+":"+$account+":table/"+$table)
        ]
      }]
    }' > "${STATE_DIR}/node-dynamodb-policy.json"
  aws iam put-role-policy \
    --role-name "${node_role_name}" \
    --policy-name ArcEks24hDynamoDBAccess \
    --policy-document "file://${STATE_DIR}/node-dynamodb-policy.json"
}

attach_node_policy "${PRIMARY_REGION}"
attach_node_policy "${STANDBY_REGION}"

aws eks update-kubeconfig \
  --region "${PRIMARY_REGION}" \
  --name "${PRIMARY_CLUSTER}" \
  --alias arc-west
aws eks update-kubeconfig \
  --region "${STANDBY_REGION}" \
  --name "${STANDBY_CLUSTER}" \
  --alias arc-east

for region_name in "${PRIMARY_REGION}" "${STANDBY_REGION}"; do
  context_name="$(cluster_context "${region_name}")"
  kubectl --context "${context_name}" \
    -n kube-system \
    rollout status deployment/metrics-server \
    --timeout=10m

  sed \
    -e "s|\${NAMESPACE}|${NAMESPACE}|g" \
    -e "s|\${EXPERIMENT_TAG}|${EXPERIMENT_TAG}|g" \
    -e "s|\${APP_NAME}|${APP_NAME}|g" \
    -e "s|\${DEPLOY_REGION}|${region_name}|g" \
    -e "s|\${TABLE_NAME}|${TABLE_NAME}|g" \
    -e "s|\${HPA_MAX_REPLICAS}|${HPA_MAX_REPLICAS}|g" \
    "${LAB_ROOT}/k8s/application.yaml.tpl" \
    | kubectl --context "${context_name}" apply -f -

  kubectl --context "${context_name}" \
    -n "${NAMESPACE}" \
    rollout status "deployment/${APP_NAME}" \
    --timeout=25m
done

get_load_balancer() {
  local context_name="$1"
  kubectl --context "${context_name}" \
    -n "${NAMESPACE}" \
    get service "${APP_NAME}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
}

load_balancer_is_ready() {
  [[ -n "$(get_load_balancer "$1")" ]]
}

wait_for_command 80 15 load_balancer_is_ready arc-west
wait_for_command 80 15 load_balancer_is_ready arc-east

west_lb="$(get_load_balancer arc-west)"
east_lb="$(get_load_balancer arc-east)"
jq -n \
  --arg west "${west_lb}" \
  --arg east "${east_lb}" \
  '{west:$west,east:$east}' | tee "${STATE_DIR}/load-balancers.json"

"${SCRIPT_DIR}/prepare-arc.sh"
