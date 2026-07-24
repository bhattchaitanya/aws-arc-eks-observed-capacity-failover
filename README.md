# ARC EKS 24-hour observed-capacity lab

This experiment demonstrates an Amazon Application Recovery Controller Region Switch plan that:

- Runs one EKS Auto Mode cluster in `us-west-2` and one in `us-east-2`.
- Keeps 100% of application traffic in Oregon before failover.
- Uses a DynamoDB Global Table with local reads and writes in each Region.
- Configures an HPA range of 1–40 pods.
- Deliberately exercises 20 ready pods in Oregon at 1,000 transactions per second.
- Creates one ARC active/passive plan only after the 20-pod source state exists.
- Uses the EKS `sampledMaxInLast24Hours` capacity monitoring approach with `targetPercent: 100`.
- Blocks failover until ARC plan evaluation confirms that replica history was collected.
- Executes failover in ungraceful mode so the optional CloudWatch availability gate is skipped.
- Uses ARC-vended Route 53 health checks attached to weighted records.

## Cost envelope

The modeled ready-state cost is about **$1.35/hour** and the temporary failover peak is about **$2.10/hour**, including two EKS control planes, EKS Auto Mode compute and management fees, one ARC plan, two NLBs, Route 53 health checks, and the 1,000 TPS test mix of eventually consistent reads plus 1% replicated writes. Data transfer and unusually large responses would add variable cost.

The design is intentionally below the requested $5–$10/hour ceiling. It does not use NAT gateways or Container Insights.

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
