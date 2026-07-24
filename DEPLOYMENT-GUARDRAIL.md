# Deployment guardrail

This lab is authorized only in AWS account `345882051641`, using:

- `us-west-2`: EKS cluster `arc-eks-24h-west`
- `us-east-2`: EKS cluster `arc-eks-24h-east`
- one `arc-lab` namespace and one `arc-transaction-api` service per Region
- DynamoDB Global Table `arc-eks-24h-transactions`
- one new ARC plan `arc-eks-24h-observed-capacity`

The plan must use `sampledMaxInLast24Hours` at `targetPercent: 100`, and
failover remains blocked until ARC evaluation reports `passed` with no active
warnings. The source is deliberately held at 20 ready replicas long enough for
ARC to sample that state; the HPA maximum of 40 is a ceiling, not the failover
target.

Before deployment, the live quota/cost gate passed for the complete target
state. Re-run `scripts/preflight.sh` before any retry or expansion. Do not touch
the unrelated pre-existing ARC plan `arc-demo-region-switch`.

The modeled cost is approximately `$1.35/hour` ready and `$2.10/hour` during
the temporary failover peak, below the user's `$5–$10/hour` ceiling. ARC's
monthly plan price is prorated for a partial month; the hourly number is an
estimate, not a promise of exact per-second billing.

No automatic failback is allowed. Do not tear down the lab while the Medium
draft is being reviewed unless the user explicitly requests teardown.
