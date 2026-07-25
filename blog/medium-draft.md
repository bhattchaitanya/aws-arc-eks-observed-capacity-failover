# When Observability Fails: How AWS ARC Remembers EKS Capacity for Regional Recovery

## A measured AWS ARC Region Switch experiment showing how stored EKS replica history determines recovery capacity and live Kubernetes readiness gates traffic movement

## TL;DR

A recovery Region creates a difficult business tradeoff. Keeping it at full production capacity is expensive; keeping it at one pod is economical but dangerous if traffic arrives before the platform catches up. Scaling every service to its HPA ceiling can be just as problematic because that ceiling is a safety limit, not evidence of demand.

Amazon Application Recovery Controller (ARC) Region Switch offers a more deliberate compromise. In this experiment, Oregon was serving on 20 EKS pods while Ohio held one. ARC used stored replica-count history from the previous 24 hours to calculate a 20-pod recovery target, waited until the destination’s live Kubernetes readiness state satisfied the EKS step, and only then started the Route 53 traffic step.

The design separates two decisions: remembered history answers **how much capacity**, while live Kubernetes status answers **whether it is ready**. The recovery path did not need a live CloudWatch or Prometheus utilization lookup to calculate the pod target.

![Capacity-first two-Region EKS recovery architecture](../diagrams/architecture-medium.png)

*ARC applies policy, restores demonstrated EKS capacity, waits for readiness, and then changes routing. DynamoDB Global Tables keeps the data tier active/active.*

## Why this recovery model matters

The HPA for this service allowed 1–40 replicas. Oregon (`us-west-2`) had demonstrated a peak of 20 ready pods; Ohio (`us-east-2`) began with one. With `targetPercent: 100`, ARC recovered Ohio to the observed 20—not the one-pod standby state and not the 40-pod HPA ceiling.

That makes the recovery target evidence-based. It reduces idle standby capacity without turning failover into an uncontrolled autoscaling race or consuming capacity the application has never shown it needs. Organizations may still add headroom for growth, retry storms, or correlated failures, but an observed peak is a more defensible baseline than the HPA maximum.

The Region Switch workflow enforced three sequential steps:

1. An optional availability-policy block.
2. EKS capacity recovery.
3. Route 53 traffic movement.

![Live ARC plan workflow with three annotated execution blocks](../evidence/screenshots/arc-plan-annotated.png)

*The retained ARC plan shows the governing sequence: optional policy, EKS capacity, then traffic.*

The application existed in both Regions and used the local replica of a DynamoDB Global Table. Ingress began active/passive: Oregon had the serving Route 53 state and Ohio was the recovery Region.

## How ARC knows the standby can take traffic

This is really two questions with two different signals.

### How much capacity is required?

The EKS execution block used `sampledMaxInLast24Hours`. AWS describes this as the maximum running capacity sampled over 24 hours. ARC collects and stores the Kubernetes `ReplicaCount` for the configured resource; it is not querying pod CPU, pod memory, Prometheus, or `maxReplicas` from the HPA during recovery.

ARC calculates:

```text
desired replicas =
ceil((targetPercent / 100) × sampled source replica maximum)

ceil((100 / 100) × 20) = 20
```

The exact EKS block from the retained plan is below. Only the AWS account ID is replaced:

```json
{
  "name": "Pre-scale EKS to observed 24-hour maximum",
  "description": "Match 100 percent of ARC sampled max; do not use HPA max as the recovery target.",
  "executionBlockType": "EKSResourceScaling",
  "executionBlockConfiguration": {
    "eksResourceScalingConfig": {
      "kubernetesResourceType": {
        "apiVersion": "apps/v1",
        "kind": "Deployment"
      },
      "timeoutMinutes": 25,
      "scalingResources": [
        {
          "arc-transaction-api": {
            "us-east-2": {
              "namespace": "arc-lab",
              "name": "arc-transaction-api",
              "hpaName": "arc-transaction-api"
            },
            "us-west-2": {
              "namespace": "arc-lab",
              "name": "arc-transaction-api",
              "hpaName": "arc-transaction-api"
            }
          }
        }
      ],
      "eksClusters": [
        {
          "clusterArn": "arn:aws:eks:us-west-2:ACCOUNT_ID:cluster/arc-eks-24h-west"
        },
        {
          "clusterArn": "arn:aws:eks:us-east-2:ACCOUNT_ID:cluster/arc-eks-24h-east"
        }
      ],
      "ungraceful": {
        "minimumSuccessPercentage": 99
      },
      "targetPercent": 100,
      "capacityMonitoringApproach": "sampledMaxInLast24Hours"
    }
  }
}
```

`scalingResources` maps the corresponding Deployment and HPA in each Region. `targetPercent` chooses the percentage of observed capacity to recover. `timeoutMinutes` bounds the EKS step. The API describes `minimumSuccessPercentage` as the ungraceful success policy but does not publish its calculation granularity; I therefore do not reinterpret 99 as fractional-pod arithmetic. The independent validation confirmed all 20 destination replicas ready.

Plan evaluation verifies that ARC collected and stored the required replica history. That history must exist before an incident. AWS publishes the 24-hour window and the 30-minute plan-evaluation cadence, but not ARC’s internal replica-sampling interval.

[AWS documents the EKS block’s collection, calculation, HPA behavior, readiness wait, and evaluation checks](https://docs.aws.amazon.com/r53recovery/latest/dg/eks-resource-scaling-block.html). The [complete sanitized two-workflow plan](https://github.com/bhattchaitanya/aws-arc-eks-observed-capacity-failover/blob/8c82903c3cb755d54d7af4a8fcb031571ac4ddae/arc/as-deployed-workflows.sanitized.json) matches the live plan’s code view.

### How does ARC know the capacity is ready?

At execution time, ARC compares the destination’s ready replica count with the desired value. If the destination is already ready at that level, no scale-up is needed. Otherwise ARC updates the scale target and waits.

ARC does not execute every pod readiness probe. Kubelet runs the probes, Kubernetes aggregates their results into Deployment status, and ARC uses that aggregate ready-replica state. Twenty pods do not mean twenty ARC probe calls.

AWS does not publish the service’s private source code, exact Kubernetes request sequence, polling interval, or QPS. The documented decision can be represented by this conceptual pseudocode:

```python
# Documented-behavior pseudocode, not AWS implementation source.
desired = ceil(target_percent / 100 * sampled_24h_source_max)
ready = get_deployment_status(destination).readyReplicas

if ready < desired:
    disable_hpa_scale_down_if_configured()
    update_scale_subresource(destination, replicas=desired)

while not eks_block_completion_condition(ready, desired, execution_mode):
    fail_or_pause_if_timeout_reached()
    wait(ARC_INTERNAL_INTERVAL)  # AWS does not publish this value.
    ready = get_deployment_status(destination).readyReplicas

emit("stepSucceeded")
start_next_sequential_step()
```

While capacity is building, the EKS step remains in progress and the later Route 53 step cannot begin. When the EKS completion condition is satisfied, ARC emits `stepSucceeded`; if the timeout is reached, published event types include `stepFailed` and `stepPausedByError`.

![ARC EKS sampling and destination-readiness flow](../diagrams/eks-sampling-readiness.png)

*Stored history determines the target. Live Deployment status gates the traffic step.*

## The observability boundary

The first workflow block was a custom Lambda availability policy. In graceful mode it read a CloudWatch alarm built from the service’s `AvailabilityPercent` metric and rejected recovery when the alarm was in `ALARM`. The deployed code also had an explicit fail-open policy for missing telemetry:

```python
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
```

![Live Lambda editor showing the custom availability gate](../evidence/screenshots/lambda-code-annotated.png)

*The deployed Lambda distinguishes an availability-policy failure from missing observability.*

![Live CloudWatch availability alarm and threshold](../evidence/screenshots/cloudwatch-availability-annotated.png)

*The optional graceful policy used a 97% availability threshold.*

The actual recovery ran in `ungraceful` mode, where the plan configuration skipped this custom block. The critical capacity decision therefore did not depend on Lambda or a live CloudWatch utilization query.

This is narrower than saying “ARC does not need observability.” ARC still needed its stored pre-incident replica history and live EKS access, and normal monitoring remains essential before and after recovery. The experiment also did not make CloudWatch unavailable; it proved that this ungraceful capacity path did not require a live monitoring lookup to choose 20 pods.

## What the execution proved

The ARC event stream recorded this order:

```json
[
  {
    "type": "stepStarted",
    "stepName": "Pre-scale EKS to observed 24-hour maximum"
  },
  {
    "type": "stepUpdate",
    "description": "Found 20 source replicas using sampledMaxInLast24Hours."
  },
  {
    "type": "stepUpdate",
    "description": "Sending request to increase the destination Deployment from 1 replica to 20."
  },
  {
    "type": "stepSucceeded",
    "stepName": "Pre-scale EKS to observed 24-hour maximum"
  },
  {
    "type": "stepStarted",
    "stepName": "Shift Route 53 traffic to activating Region"
  }
]
```

The event API did not expose every internal readiness poll. The important evidence is the state transition: EKS `stepSucceeded` occurred before Route 53 `stepStarted`. The SDK independently read the Ohio Deployment after execution and confirmed `readyReplicas: 20`.

![Live ARC EKS scaling-step configuration](../evidence/screenshots/arc-execution-annotated.png)

*The completed execution shows the 100% target, sampled 24-hour maximum, and sequential steps.*

![Live ARC event log showing the observed 20-replica event](../evidence/screenshots/arc-execution-event-annotated.png)

*The event log records the stored 20-replica target and the scale request before traffic movement.*

| Evidence | Measured result |
|---|---:|
| Destination ready pods | 1 → 20 |
| EKS capacity step | 29.35 seconds |
| Route 53 health-state step | 120.88 seconds |
| End-to-end execution and validation | 2.76 minutes |
| Destination response | `region: us-east-2` |
| DynamoDB validation | Local Ohio replica returned a key |

Route 53 weights remained Oregon 100 and Ohio 0. ARC changed the associated health states so the standby took over only after the EKS step completed.

A separate Gatling verification reached and held a 1,000-arrivals/second plateau against the pre-scaled destination and recorded 53,248 successes out of 53,250 requests: **99.9962% success**.

![Real Gatling Community Edition report](../evidence/screenshots/gatling-report-annotated.png)

*The Gatling report shows the 1,000-arrivals/second plateau and measured success result.*

The implementation, SDK driver, sanitized plan, and publication-safe evidence are available in [the immutable experiment commit](https://github.com/bhattchaitanya/aws-arc-eks-observed-capacity-failover/commit/8c82903c3cb755d54d7af4a8fcb031571ac4ddae).

## What this proves—and what it does not

This experiment demonstrates that ARC can:

- Derive an EKS recovery target from stored replica history rather than a live utilization query.
- Recover a one-pod destination to the demonstrated 20-pod level.
- Use live Kubernetes readiness as a gate before starting the traffic step.
- Keep an optional CloudWatch-dependent policy in the graceful workflow without making it mandatory for ungraceful recovery.

It does not prove that 100% of the observed maximum is sufficient for every workload, that CloudWatch failed during the test, or that requested compute capacity will always be available. ARC orchestrates scaling; it does not reserve EC2 capacity. Workloads requiring a hard guarantee should combine recovery orchestration with deliberate capacity reservations and tested operational headroom.

## Takeaway

ARC separates capacity memory from capacity readiness.

The remembered 24-hour maximum supplies the number. Kubernetes readiness supplies the go-signal. Sequential workflow execution ensures traffic comes last.

That is the valuable business property: a smaller steady-state recovery footprint without making the first minutes of failover depend on a live utilization dashboard or an uncontrolled autoscaling race.
