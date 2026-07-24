import json
import os

import boto3


def handler(event, context):
    alarm_name = os.environ["ALARM_NAME"]
    fail_open = os.environ.get("FAIL_OPEN_ON_MISSING", "true").lower() == "true"
    cloudwatch = boto3.client("cloudwatch")

    try:
        response = cloudwatch.describe_alarms(AlarmNames=[alarm_name])
        alarms = response.get("MetricAlarms", [])
        state = alarms[0]["StateValue"] if alarms else "INSUFFICIENT_DATA"
    except Exception as exc:
        if fail_open:
            return {
                "allowed": True,
                "reason": "CloudWatch API unavailable; fail-open policy applied",
                "errorType": type(exc).__name__,
            }
        raise

    if state == "ALARM":
        raise RuntimeError(f"Availability alarm {alarm_name} is ALARM")

    if state == "INSUFFICIENT_DATA" and not fail_open:
        raise RuntimeError(f"Availability alarm {alarm_name} has insufficient data")

    return {
        "allowed": True,
        "alarm": alarm_name,
        "state": state,
        "failOpenApplied": state == "INSUFFICIENT_DATA",
        "event": json.loads(json.dumps(event, default=str)),
    }
