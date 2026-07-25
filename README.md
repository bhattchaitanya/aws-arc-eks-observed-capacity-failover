# ARC EKS 24-hour observed-capacity lab

This experiment demonstrates an Amazon Application Recovery Controller Region Switch plan that:

- Runs one EKS Auto Mode cluster in `us-west-2` and one in `us-east-2`.
- Keeps 100% of application traffic in Oregon before failover.
- Uses a DynamoDB Global Table with local reads and writes in each Region.
- Configures an HPA range of 1–40 pods.
- Deliberately exercises 20 ready pods in Oregon with a 1,000-transactions-per-second target.
- Creates one ARC active/passive plan only after the 20-pod source state exists.
- Uses the EKS `sampledMaxInLast24Hours` capacity monitoring approach with `targetPercent: 100`.
- Blocks failover until ARC plan evaluation confirms that replica history was collected.
- Executes failover in ungraceful mode so the optional CloudWatch availability gate is skipped.
- Uses ARC-vended Route 53 health checks attached to weighted records.

![Capacity-first two-Region architecture](diagrams/architecture-medium.png)

![ARC EKS sampling and destination-readiness flow](diagrams/eks-sampling-readiness.png)

## Cost envelope

The modeled ready-state cost is about **$1.45/hour** and the temporary failover peak is about **$2.20/hour**, including two EKS control planes, EKS Auto Mode compute and management fees, one NAT gateway per Region, one ARC plan, two NLBs, Route 53 health checks, and the 1,000 TPS test mix of eventually consistent reads plus 1% replicated writes. Data transfer and unusually large responses would add variable cost.

The design is intentionally below the requested $5–$10/hour ceiling. It uses one NAT gateway per Region for private-node egress and does not enable the more expensive Container Insights stack.

## Run order

```bash
cp config.env.example config.env
./scripts/preflight.sh
./scripts/deploy.sh
./scripts/prime-and-create-plan.sh
./scripts/failover.sh
```

Teardown is explicit:

```bash
./scripts/teardown.sh
```

The failover script refuses to start unless `.state/history-gate.json` records a passed ARC plan evaluation.

## SDK-driven execution and evidence

The live experiment was executed and verified with the AWS and Kubernetes
SDKs. The console screenshots in `evidence/screenshots/` were captured
afterward as read-only, annotated proof for the accompanying article:

```bash
python3 -m venv .state/venv
.state/venv/bin/pip install -r requirements-sdk.txt
.state/venv/bin/python scripts/arc_experiment_sdk.py status
.state/venv/bin/python scripts/arc_experiment_sdk.py failover
.state/venv/bin/python scripts/arc_experiment_sdk.py destroy-key
```

The SDK driver validates the exact three-block ARC contract—including both
cluster ARNs, the per-Region Kubernetes resource map, the HPA names, and the
sampling configuration—obtains
short-lived EKS authentication tokens, reads Deployments and HPAs through the
Kubernetes SDK, starts and polls the ARC execution, verifies the destination
application and DynamoDB path, and writes evidence below `.state/`.

The completed run reached 811.40 requests/second against a 1,000-TPS target,
with 146,791 successes out of 146,793 attempts (99.9986% availability). ARC
scaled Ohio from 1 to 20 ready pods and completed the full execution in 2.76
minutes.

The temporary SDK access key has been deleted. The ARC plan and both
`arc-eks-24h-availability-gate` Lambda functions are intentionally retained for
review. Do not fail back, scale down, or tear down without explicit approval.

## Reproducible artifacts

- `arc/as-deployed-workflows.sanitized.json` is the exact two-workflow JSON
  shown by the retained plan's code view, with only account and DNS identifiers
  replaced by explicit placeholders.
- `lambda/availability_gate.py` is the custom Lambda policy gate.
- `load-test/gatling/src/arc-failover.gatling.js` is the parameterized Gatling
  verification.
- `evidence/experiment-result.json` is the sanitized SDK-run result.
- `evidence/gatling-summary.json` is the sanitized Gatling result.
- `evidence/screenshots/` contains annotated, publication-safe evidence images.

The Gatling verification ramps from 100 to 1,000 arrivals/second over 15
seconds, then holds 1,000 for 45 seconds. The captured run completed 53,250
requests with 53,248 successes and two premature closes. Its overall 858.87
requests/second includes the ramp period.
