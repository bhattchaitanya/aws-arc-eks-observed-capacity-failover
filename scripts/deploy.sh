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

ensure_nat_egress() {
  local region_name="$1"
  local cluster_id vpc_id nat_id allocation_id public_subnet_id
  local private_subnet_id route_table_id
  cluster_id="$(cluster_name "${region_name}")"
  vpc_id="$(aws eks describe-cluster \
    --region "${region_name}" \
    --name "${cluster_id}" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)"
  nat_id="$(aws ec2 describe-nat-gateways \
    --region "${region_name}" \
    --filter \
      Name=vpc-id,Values="${vpc_id}" \
      Name=tag:Project,Values="${EXPERIMENT_TAG}" \
      Name=state,Values=pending,available \
    --query 'NatGateways[0].NatGatewayId' \
    --output text)"

  if [[ "${nat_id}" == "None" || -z "${nat_id}" ]]; then
    public_subnet_id="$(aws ec2 describe-subnets \
      --region "${region_name}" \
      --filters \
        Name=vpc-id,Values="${vpc_id}" \
        Name=tag:kubernetes.io/role/elb,Values=1 \
      --query 'Subnets | sort_by(@,&AvailabilityZone)[0].SubnetId' \
      --output text)"
    [[ "${public_subnet_id}" != "None" && -n "${public_subnet_id}" ]] || {
      echo "No public subnet found for NAT gateway in ${region_name}" >&2
      exit 1
    }
    allocation_id="$(aws ec2 allocate-address \
      --region "${region_name}" \
      --domain vpc \
      --tag-specifications \
        "ResourceType=elastic-ip,Tags=[{Key=Project,Value=${EXPERIMENT_TAG}},{Key=Name,Value=${cluster_id}-nat-eip}]" \
      --query 'AllocationId' \
      --output text)"
    nat_id="$(aws ec2 create-nat-gateway \
      --region "${region_name}" \
      --subnet-id "${public_subnet_id}" \
      --allocation-id "${allocation_id}" \
      --tag-specifications \
        "ResourceType=natgateway,Tags=[{Key=Project,Value=${EXPERIMENT_TAG}},{Key=Name,Value=${cluster_id}-nat}]" \
      --query 'NatGateway.NatGatewayId' \
      --output text)"
  else
    allocation_id="$(aws ec2 describe-nat-gateways \
      --region "${region_name}" \
      --nat-gateway-ids "${nat_id}" \
      --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' \
      --output text)"
  fi

  aws ec2 wait nat-gateway-available \
    --region "${region_name}" \
    --nat-gateway-ids "${nat_id}"

  for private_subnet_id in $(aws ec2 describe-subnets \
    --region "${region_name}" \
    --filters \
      Name=vpc-id,Values="${vpc_id}" \
      Name=tag:kubernetes.io/role/internal-elb,Values=1 \
    --query 'Subnets[].SubnetId' \
    --output text); do
    route_table_id="$(aws ec2 describe-route-tables \
      --region "${region_name}" \
      --filters Name=association.subnet-id,Values="${private_subnet_id}" \
      --query 'RouteTables[0].RouteTableId' \
      --output text)"
    [[ "${route_table_id}" != "None" && -n "${route_table_id}" ]] || {
      echo "No route table found for private subnet ${private_subnet_id}" >&2
      exit 1
    }
    aws ec2 create-route \
      --region "${region_name}" \
      --route-table-id "${route_table_id}" \
      --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "${nat_id}" \
      >/dev/null 2>&1 || \
    aws ec2 replace-route \
      --region "${region_name}" \
      --route-table-id "${route_table_id}" \
      --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "${nat_id}" \
      >/dev/null
  done

  jq -n \
    --arg region "${region_name}" \
    --arg vpcId "${vpc_id}" \
    --arg natGatewayId "${nat_id}" \
    --arg allocationId "${allocation_id}" \
    '{region:$region,vpcId:$vpcId,natGatewayId:$natGatewayId,allocationId:$allocationId}'
}

ensure_nat_egress "${PRIMARY_REGION}" > "${STATE_DIR}/nat-west.json"
ensure_nat_egress "${STANDBY_REGION}" > "${STATE_DIR}/nat-east.json"
jq -s '{natGateways:.}' \
  "${STATE_DIR}/nat-west.json" \
  "${STATE_DIR}/nat-east.json" \
  > "${STATE_DIR}/nat-egress.json"

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

app_role_name="ArcEks24hAppPodRole"
app_role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${app_role_name}"
if ! aws iam get-role --role-name "${app_role_name}" >/dev/null 2>&1; then
  jq -n '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Service:"pods.eks.amazonaws.com"},
      Action:["sts:AssumeRole","sts:TagSession"]
    }]
  }' > "${STATE_DIR}/pod-role-trust.json"
  aws iam create-role \
    --role-name "${app_role_name}" \
    --assume-role-policy-document "file://${STATE_DIR}/pod-role-trust.json" \
    --tags Key=Project,Value="${EXPERIMENT_TAG}" \
    >/dev/null
fi
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
  }' > "${STATE_DIR}/pod-dynamodb-policy.json"
aws iam put-role-policy \
  --role-name "${app_role_name}" \
  --policy-name ArcEks24hDynamoDBAccess \
  --policy-document "file://${STATE_DIR}/pod-dynamodb-policy.json"

ensure_pod_identity_association() {
  local region_name="$1"
  local cluster_id association_count
  cluster_id="$(cluster_name "${region_name}")"
  association_count="$(aws eks list-pod-identity-associations \
    --region "${region_name}" \
    --cluster-name "${cluster_id}" \
    --namespace "${NAMESPACE}" \
    --service-account "${APP_NAME}" \
    --query 'length(associations)' \
    --output text)"
  if [[ "${association_count}" -gt 0 ]]; then
    return 0
  fi
  aws eks create-pod-identity-association \
    --region "${region_name}" \
    --cluster-name "${cluster_id}" \
    --role-arn "${app_role_arn}" \
    --namespace "${NAMESPACE}" \
    --service-account "${APP_NAME}" \
    >/dev/null
}

for region_name in "${PRIMARY_REGION}" "${STANDBY_REGION}"; do
  wait_for_command 24 5 ensure_pod_identity_association "${region_name}"
  node_role_arn="$(aws eks describe-cluster \
    --region "${region_name}" \
    --name "$(cluster_name "${region_name}")" \
    --query 'cluster.computeConfig.nodeRoleArn' \
    --output text)"
  aws iam delete-role-policy \
    --role-name "${node_role_arn##*/}" \
    --policy-name ArcEks24hDynamoDBAccess \
    >/dev/null 2>&1 || true
done

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
