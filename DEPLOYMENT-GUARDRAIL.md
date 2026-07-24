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

The modeled cost is approximately `$1.45/hour` ready and `$2.20/hour` during
the temporary failover peak, below the user's `$5–$10/hour` ceiling. ARC's
monthly plan price is prorated for a partial month; the hourly number is an
estimate, not a promise of exact per-second billing.

No automatic failback is allowed. Do not tear down the lab while the Medium
draft is being reviewed unless the user explicitly requests teardown.

The Oregon-to-Ohio execution completed successfully and both Regions currently
hold 20 ready pods. Treat the lab as being in its temporary peak-cost state
(about `$2.20/hour`) until the user explicitly approves scaling down, failback,
or teardown.

Do not delete or modify the ARC plan
`arc-eks-24h-observed-capacity` or either regional Lambda function named
`arc-eks-24h-availability-gate`. The user explicitly wants to inspect these
resources before any destruction.

The temporary local SDK access key was deleted after evidence collection; see
`.state/sdk-key-destroyed.json`. The credentialless IAM user and its
namespace-scoped EKS view access remain only as reviewable bootstrap metadata.
Never create another access key without an explicit in-scope operational need,
and always delete it before ending the experiment turn.
