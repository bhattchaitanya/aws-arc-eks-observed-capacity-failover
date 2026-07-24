#!/usr/bin/env python3
"""Operate and verify the ARC experiment through AWS and Kubernetes SDKs."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from botocore.signers import RequestSigner
from kubernetes import client as kubernetes_client


ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / ".state"
CREDENTIALS_FILE = STATE_DIR / "sdk-credentials.json"
EXPECTED_ACCOUNT = "345882051641"
PRIMARY_REGION = "us-west-2"
STANDBY_REGION = "us-east-2"
PRIMARY_CLUSTER = "arc-eks-24h-west"
STANDBY_CLUSTER = "arc-eks-24h-east"
NAMESPACE = "arc-lab"
APPLICATION = "arc-transaction-api"
TABLE_NAME = "arc-eks-24h-transactions"
PLAN_NAME = "arc-eks-24h-observed-capacity"
PLAN_REGION = STANDBY_REGION
HOSTED_ZONE_ID = "Z07811951AS9O1UJW9VDX"
RECORD_NAME = "arc-eks-24h.arc-demo.example."
OBSERVED_PEAK = 20
HPA_MAXIMUM = 40


def json_default(value: Any) -> str:
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    return str(value)


def write_json(name: str, payload: Any) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path = STATE_DIR / name
    path.write_text(
        json.dumps(payload, indent=2, default=json_default) + "\n",
        encoding="utf-8",
    )
    return path


def load_key() -> dict[str, str]:
    if not CREDENTIALS_FILE.exists():
        raise RuntimeError(
            "Temporary SDK credential is absent or has already been destroyed."
        )
    mode = CREDENTIALS_FILE.stat().st_mode & 0o777
    if mode != 0o600:
        raise RuntimeError(
            f"Refusing to use credential file with mode {oct(mode)}; expected 0o600."
        )
    payload = json.loads(CREDENTIALS_FILE.read_text(encoding="utf-8"))
    key = payload["AccessKey"]
    return {
        "user_name": key["UserName"],
        "access_key_id": key["AccessKeyId"],
        "secret_access_key": key["SecretAccessKey"],
    }


def aws_session(key: dict[str, str]) -> boto3.Session:
    return boto3.Session(
        aws_access_key_id=key["access_key_id"],
        aws_secret_access_key=key["secret_access_key"],
        region_name=PLAN_REGION,
    )


def assert_identity(session: boto3.Session) -> dict[str, str]:
    identity = session.client("sts", region_name=PLAN_REGION).get_caller_identity()
    if identity["Account"] != EXPECTED_ACCOUNT:
        raise RuntimeError(
            f"Refusing account {identity['Account']}; expected {EXPECTED_ACCOUNT}."
        )
    return {"Account": identity["Account"], "Arn": identity["Arn"]}


def find_plan(arc: Any) -> dict[str, Any]:
    token = None
    while True:
        request = {"maxResults": 20}
        if token:
            request["nextToken"] = token
        response = arc.list_plans(**request)
        for plan in response.get("plans", []):
            if plan["name"] == PLAN_NAME:
                return arc.get_plan(arn=plan["arn"])["plan"]
        token = response.get("nextToken")
        if not token:
            break
    raise RuntimeError(f"ARC plan {PLAN_NAME} was not found.")


def eks_token(
    session: boto3.Session,
    region: str,
    cluster_name: str,
) -> str:
    credentials = session.get_credentials()
    if credentials is None:
        raise RuntimeError("AWS SDK session has no credentials.")
    sts = session.client("sts", region_name=region)
    signer = RequestSigner(
        sts.meta.service_model.service_id,
        region,
        "sts",
        "v4",
        credentials,
        session.events,
    )
    request = {
        "method": "GET",
        "url": (
            f"https://sts.{region}.amazonaws.com/"
            "?Action=GetCallerIdentity&Version=2011-06-15"
        ),
        "body": {},
        "headers": {"x-k8s-aws-id": cluster_name},
        "context": {},
    }
    url = signer.generate_presigned_url(
        request,
        region_name=region,
        expires_in=60,
        operation_name="",
    )
    encoded = base64.urlsafe_b64encode(url.encode("utf-8")).decode("utf-8")
    return "k8s-aws-v1." + encoded.rstrip("=")


def kubernetes_apis(
    session: boto3.Session,
    region: str,
    cluster_name: str,
) -> tuple[Any, Any]:
    cluster = session.client("eks", region_name=region).describe_cluster(
        name=cluster_name
    )["cluster"]
    ca_path = STATE_DIR / f"eks-ca-{region}.crt"
    ca_path.write_bytes(
        base64.b64decode(cluster["certificateAuthority"]["data"].encode("ascii"))
    )
    os.chmod(ca_path, 0o600)

    configuration = kubernetes_client.Configuration()
    configuration.host = cluster["endpoint"]
    configuration.ssl_ca_cert = str(ca_path)
    configuration.api_key["authorization"] = eks_token(
        session,
        region,
        cluster_name,
    )
    configuration.api_key_prefix["authorization"] = "Bearer"
    api_client = kubernetes_client.ApiClient(configuration)
    return (
        kubernetes_client.AppsV1Api(api_client),
        kubernetes_client.AutoscalingV2Api(api_client),
    )


def workload_status(
    session: boto3.Session,
    region: str,
    cluster_name: str,
) -> dict[str, Any]:
    apps, autoscaling = kubernetes_apis(session, region, cluster_name)
    deployment = apps.read_namespaced_deployment(APPLICATION, NAMESPACE)
    hpa = autoscaling.read_namespaced_horizontal_pod_autoscaler(
        APPLICATION,
        NAMESPACE,
    )
    return {
        "region": region,
        "cluster": cluster_name,
        "desiredReplicas": deployment.spec.replicas or 0,
        "readyReplicas": deployment.status.ready_replicas or 0,
        "availableReplicas": deployment.status.available_replicas or 0,
        "hpaMinReplicas": hpa.spec.min_replicas,
        "hpaMaxReplicas": hpa.spec.max_replicas,
    }


def plan_contract(plan: dict[str, Any]) -> dict[str, Any]:
    east_workflow = next(
        workflow
        for workflow in plan["workflows"]
        if workflow.get("workflowTargetAction") == "activate"
        and workflow.get("workflowTargetRegion") == STANDBY_REGION
    )
    block_types = [step["executionBlockType"] for step in east_workflow["steps"]]
    expected = [
        "CustomActionLambda",
        "EKSResourceScaling",
        "Route53HealthCheck",
    ]
    if block_types != expected:
        raise RuntimeError(f"Unexpected execution-block order: {block_types}")

    custom = east_workflow["steps"][0]["executionBlockConfiguration"][
        "customActionLambdaConfig"
    ]
    scaling = east_workflow["steps"][1]["executionBlockConfiguration"][
        "eksResourceScalingConfig"
    ]
    routing = east_workflow["steps"][2]["executionBlockConfiguration"][
        "route53HealthCheckConfig"
    ]
    if custom.get("regionToRun") != "activatingRegion":
        raise RuntimeError("Custom Lambda block is not isolated to the activating Region.")
    if custom.get("ungraceful", {}).get("behavior") != "skip":
        raise RuntimeError("Custom Lambda block is not skippable in ungraceful mode.")
    if scaling.get("capacityMonitoringApproach") != "sampledMaxInLast24Hours":
        raise RuntimeError("ARC is not using the sampled 24-hour replica maximum.")
    if scaling.get("targetPercent") != 100:
        raise RuntimeError("ARC targetPercent is not 100.")
    if scaling.get("ungraceful", {}).get("minimumSuccessPercentage") != 99:
        raise RuntimeError("ARC ungraceful minimum success is not the API maximum, 99.")

    return {
        "workflowTargetRegion": STANDBY_REGION,
        "executionBlockOrder": block_types,
        "customLambda": {
            "regionToRun": custom["regionToRun"],
            "ungracefulBehavior": custom["ungraceful"]["behavior"],
            "retryIntervalMinutes": custom["retryIntervalMinutes"],
            "timeoutMinutes": custom["timeoutMinutes"],
            "lambdaArns": [item["arn"] for item in custom["lambdas"]],
        },
        "eksScaling": {
            "capacityMonitoringApproach": scaling["capacityMonitoringApproach"],
            "targetPercent": scaling["targetPercent"],
            "minimumSuccessPercentage": scaling["ungraceful"][
                "minimumSuccessPercentage"
            ],
            "timeoutMinutes": scaling["timeoutMinutes"],
        },
        "route53": {
            "hostedZoneId": routing["hostedZoneId"],
            "recordName": routing["recordName"],
            "recordSets": routing["recordSets"],
        },
    }


def route53_records(session: boto3.Session) -> list[dict[str, Any]]:
    route53 = session.client("route53")
    response = route53.list_resource_record_sets(
        HostedZoneId=HOSTED_ZONE_ID,
        StartRecordName=RECORD_NAME,
        StartRecordType="CNAME",
        MaxItems="10",
    )
    records = []
    for record in response["ResourceRecordSets"]:
        if record["Name"] != RECORD_NAME or record["Type"] != "CNAME":
            continue
        records.append(
            {
                "setIdentifier": record.get("SetIdentifier"),
                "weight": record.get("Weight"),
                "healthCheckId": record.get("HealthCheckId"),
                "value": record["ResourceRecords"][0]["Value"],
            }
        )
    return sorted(records, key=lambda item: item["setIdentifier"])


def alarm_status(session: boto3.Session, region: str) -> dict[str, Any]:
    name = f"arc-eks-24h-availability-{region}"
    response = session.client("cloudwatch", region_name=region).describe_alarms(
        AlarmNames=[name]
    )
    alarm = response["MetricAlarms"][0]
    return {
        "region": region,
        "name": name,
        "state": alarm["StateValue"],
        "threshold": alarm["Threshold"],
        "comparison": alarm["ComparisonOperator"],
        "treatMissingData": alarm["TreatMissingData"],
    }


def lambda_status(session: boto3.Session, region: str) -> dict[str, Any]:
    function = session.client("lambda", region_name=region).get_function_configuration(
        FunctionName="arc-eks-24h-availability-gate"
    )
    variables = function.get("Environment", {}).get("Variables", {})
    return {
        "region": region,
        "functionArn": function["FunctionArn"],
        "state": function["State"],
        "runtime": function["Runtime"],
        "alarmName": variables.get("ALARM_NAME"),
        "failOpenOnMissing": variables.get("FAIL_OPEN_ON_MISSING"),
    }


def dynamodb_status(session: boto3.Session) -> dict[str, Any]:
    table = session.client("dynamodb", region_name=PRIMARY_REGION).describe_table(
        TableName=TABLE_NAME
    )["Table"]
    return {
        "tableArn": table["TableArn"],
        "status": table["TableStatus"],
        "billingMode": table.get("BillingModeSummary", {}).get("BillingMode"),
        "replicas": sorted(
            [
                {
                    "region": replica["RegionName"],
                    "status": replica.get("ReplicaStatus"),
                }
                for replica in table.get("Replicas", [])
            ],
            key=lambda item: item["region"],
        ),
    }


def collect_status(session: boto3.Session) -> dict[str, Any]:
    identity = assert_identity(session)
    arc = session.client("arc-region-switch", region_name=PLAN_REGION)
    plan = find_plan(arc)
    evaluation = arc.get_plan_evaluation_status(planArn=plan["arn"])
    contract = plan_contract(plan)
    workloads = [
        workload_status(session, PRIMARY_REGION, PRIMARY_CLUSTER),
        workload_status(session, STANDBY_REGION, STANDBY_CLUSTER),
    ]
    return {
        "capturedAt": datetime.now(timezone.utc),
        "identity": identity,
        "plan": {
            "arn": plan["arn"],
            "name": plan["name"],
            "version": plan["version"],
            "recoveryApproach": plan["recoveryApproach"],
            "primaryRegion": plan["primaryRegion"],
            "regions": plan["regions"],
            "contract": contract,
        },
        "evaluation": {
            "state": evaluation["evaluationState"],
            "lastEvaluationTime": evaluation.get("lastEvaluationTime"),
            "warnings": evaluation.get("warnings", []),
        },
        "workloads": workloads,
        "route53Records": route53_records(session),
        "arcHealthChecks": arc.list_route53_health_checks(
            arn=plan["arn"],
            hostedZoneId=HOSTED_ZONE_ID,
            recordName=RECORD_NAME.rstrip("."),
        ).get("healthChecks", []),
        "availabilityAlarms": [
            alarm_status(session, PRIMARY_REGION),
            alarm_status(session, STANDBY_REGION),
        ],
        "lambdaExecutionBlocks": [
            lambda_status(session, PRIMARY_REGION),
            lambda_status(session, STANDBY_REGION),
        ],
        "dynamoDbGlobalTable": dynamodb_status(session),
    }


def print_status_summary(status: dict[str, Any]) -> None:
    workloads = {item["region"]: item for item in status["workloads"]}
    print(
        json.dumps(
            {
                "planArn": status["plan"]["arn"],
                "planVersion": status["plan"]["version"],
                "evaluation": status["evaluation"]["state"],
                "warningCount": len(status["evaluation"]["warnings"]),
                "westReady": workloads[PRIMARY_REGION]["readyReplicas"],
                "eastReady": workloads[STANDBY_REGION]["readyReplicas"],
                "targetPercent": status["plan"]["contract"]["eksScaling"][
                    "targetPercent"
                ],
                "capacityMonitoringApproach": status["plan"]["contract"][
                    "eksScaling"
                ]["capacityMonitoringApproach"],
                "customLambdaUngracefulBehavior": status["plan"]["contract"][
                    "customLambda"
                ]["ungracefulBehavior"],
            },
            indent=2,
        )
    )


def list_execution_events(arc: Any, plan_arn: str, execution_id: str) -> list[Any]:
    items: list[Any] = []
    token = None
    while True:
        request = {
            "planArn": plan_arn,
            "executionId": execution_id,
            "maxResults": 100,
        }
        if token:
            request["nextToken"] = token
        response = arc.list_plan_execution_events(**request)
        items.extend(response.get("items", []))
        token = response.get("nextToken")
        if not token:
            return items


def request_destination(records: list[dict[str, Any]]) -> dict[str, Any]:
    east = next(
        record for record in records if record["setIdentifier"] == "us-east-2-standby"
    )
    with urllib.request.urlopen(f"http://{east['value']}/", timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if payload.get("region") != STANDBY_REGION or not payload.get("ddb_key"):
        raise RuntimeError(f"Unexpected Ohio application response: {payload}")
    return payload


def run_failover(session: boto3.Session) -> dict[str, Any]:
    before = collect_status(session)
    if before["evaluation"]["state"] != "passed":
        raise RuntimeError("ARC plan evaluation has not passed.")
    if before["evaluation"]["warnings"]:
        raise RuntimeError("ARC plan evaluation still has warnings.")
    workloads = {item["region"]: item for item in before["workloads"]}
    if workloads[PRIMARY_REGION]["readyReplicas"] < OBSERVED_PEAK:
        raise RuntimeError("Oregon is not holding the 20-replica observed peak.")
    if workloads[STANDBY_REGION]["readyReplicas"] >= OBSERVED_PEAK:
        raise RuntimeError("Ohio is already at the target; pre-scale proof would be invalid.")
    if workloads[PRIMARY_REGION]["hpaMaxReplicas"] != HPA_MAXIMUM:
        raise RuntimeError("Oregon HPA maximum does not match the documented ceiling.")

    write_json("sdk-status-before.json", before)
    arc = session.client("arc-region-switch", region_name=PLAN_REGION)
    started_at = datetime.now(timezone.utc)
    start = arc.start_plan_execution(
        planArn=before["plan"]["arn"],
        targetRegion=STANDBY_REGION,
        action="activate",
        mode="ungraceful",
        latestVersion=before["plan"]["version"],
        comment=(
            "SDK experiment: skip the optional CloudWatch Lambda dependency, "
            "pre-scale EKS from ARC sampled history, then switch Route 53."
        ),
    )
    execution_id = start["executionId"]
    print(f"ARC execution started: {execution_id}")

    successful = {
        "completed",
        "completedWithExceptions",
        "completedMonitoringApplicationHealth",
    }
    failed = {
        "failed",
        "canceled",
        "planExecutionTimedOut",
        "pausedByFailedStep",
    }
    last_state = None
    execution = None
    deadline = time.monotonic() + 45 * 60
    while time.monotonic() < deadline:
        execution = arc.get_plan_execution(
            planArn=before["plan"]["arn"],
            executionId=execution_id,
            maxResults=100,
        )
        state = execution["executionState"]
        if state != last_state:
            print(f"ARC execution state: {state}")
            last_state = state
        if state in successful:
            break
        if state in failed:
            raise RuntimeError(f"ARC execution stopped in state {state}.")
        time.sleep(10)
    else:
        raise RuntimeError("ARC execution exceeded the 45-minute SDK polling window.")

    ready_deadline = time.monotonic() + 15 * 60
    east = workload_status(session, STANDBY_REGION, STANDBY_CLUSTER)
    while east["readyReplicas"] < OBSERVED_PEAK and time.monotonic() < ready_deadline:
        time.sleep(10)
        east = workload_status(session, STANDBY_REGION, STANDBY_CLUSTER)
    if east["readyReplicas"] < OBSERVED_PEAK:
        raise RuntimeError(
            f"Ohio has {east['readyReplicas']} ready replicas; expected {OBSERVED_PEAK}."
        )

    records_after = route53_records(session)
    destination_response = request_destination(records_after)
    completed_at = datetime.now(timezone.utc)
    result = {
        "executionId": execution_id,
        "planArn": before["plan"]["arn"],
        "planVersion": start["planVersion"],
        "mode": "ungraceful",
        "startedAt": started_at,
        "completedAt": completed_at,
        "elapsedMinutes": round(
            (completed_at - started_at).total_seconds() / 60,
            2,
        ),
        "executionState": execution["executionState"],
        "cloudWatchLambdaBehavior": "skipped by ARC ungraceful configuration",
        "before": {
            "workloads": before["workloads"],
            "route53Records": before["route53Records"],
            "arcHealthChecks": before["arcHealthChecks"],
        },
        "after": {
            "eastWorkload": east,
            "route53Records": records_after,
            "arcHealthChecks": arc.list_route53_health_checks(
                arn=before["plan"]["arn"],
                hostedZoneId=HOSTED_ZONE_ID,
                recordName=RECORD_NAME.rstrip("."),
            ).get("healthChecks", []),
            "destinationResponse": destination_response,
        },
        "execution": execution,
        "events": list_execution_events(
            arc,
            before["plan"]["arn"],
            execution_id,
        ),
    }
    write_json("sdk-failover-result.json", result)
    print(
        json.dumps(
            {
                "executionState": result["executionState"],
                "elapsedMinutes": result["elapsedMinutes"],
                "eastReady": east["readyReplicas"],
                "validatedRegion": destination_response["region"],
                "validatedDynamoDbKey": destination_response["ddb_key"],
            },
            indent=2,
        )
    )
    return result


def destroy_temporary_key(session: boto3.Session, key: dict[str, str]) -> None:
    identity = assert_identity(session)
    if not identity["Arn"].endswith(f":user/{key['user_name']}"):
        raise RuntimeError("The active identity does not own the temporary access key.")
    marker = {
        "destroyedAt": datetime.now(timezone.utc),
        "userName": key["user_name"],
        "accessKeyIdSuffix": key["access_key_id"][-4:],
        "arcPlanRetained": PLAN_NAME,
        "lambdaFunctionsRetained": [
            f"arn:aws:lambda:{PRIMARY_REGION}:{EXPECTED_ACCOUNT}:function:"
            "arc-eks-24h-availability-gate",
            f"arn:aws:lambda:{STANDBY_REGION}:{EXPECTED_ACCOUNT}:function:"
            "arc-eks-24h-availability-gate",
        ],
    }
    session.client("iam").delete_access_key(
        UserName=key["user_name"],
        AccessKeyId=key["access_key_id"],
    )
    write_json("sdk-key-destroyed.json", marker)
    CREDENTIALS_FILE.unlink()
    print(
        "Temporary SDK access key deleted. ARC plan and Lambda functions were retained."
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=("status", "failover", "destroy-key"),
    )
    args = parser.parse_args()

    key = load_key()
    session = aws_session(key)
    if args.command == "status":
        status = collect_status(session)
        write_json("sdk-status.json", status)
        print_status_summary(status)
    elif args.command == "failover":
        run_failover(session)
    else:
        destroy_temporary_key(session, key)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise
