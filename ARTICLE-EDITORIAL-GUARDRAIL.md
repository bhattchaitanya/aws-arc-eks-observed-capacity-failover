# Technical article editorial guardrail

Use this guardrail for Medium articles aimed at business leaders, engineering leaders, SREs, and platform engineers.

## Core contract

The article must leave the reader with one repeatable sentence. Every section must explain it, prove it, or bound it.

For resilience experiments, separate:

- The business reason to use the design.
- The mechanism that makes it work.
- The evidence observed in the experiment.
- The boundary of what was not tested.

Do not turn the article into an implementation diary.

## Default editorial budget

- 1,800–2,500 narrative words, excluding code.
- A 120–180 word business-first TL;DR.
- Six to nine reader-facing sections.
- Three to five code or configuration blocks.
- Four to eight evidence-bearing figures.
- One compact result table.

Exceed a limit only when the extra material is required to make the central claim auditable.

## Canonical structure

1. One defensible title.
2. A subtitle that names the measured mechanism.
3. A business-first TL;DR.
4. The operational problem.
5. One or two questions that explain the mechanism.
6. The minimum exact configuration required as proof.
7. The observed execution and a compact result table.
8. What the experiment proves and does not prove.
9. A short takeaway.

## Keep-or-cut test

Keep content only when it:

- Explains the central mechanism.
- Supplies evidence required to trust the claim.
- Exposes a material failure mode or operational boundary.
- Prevents a likely technical misunderstanding.
- Gives the reader a reusable decision.

Cut or move to the repository:

- Cluster setup, cost, quota, IAM, credential, and teardown details unrelated to the thesis.
- Chronological command history.
- Load-generator and client troubleshooting.
- Repeated explanations.
- Repository file inventories.
- Raw logs better represented by one result.
- Incidental tools that do not affect interpretation.

## Evidence rules

Treat every technical statement as one of:

- **Documented:** supported by official vendor documentation.
- **Measured:** observed in the experiment and retained as evidence.
- **Inferred:** a reasoned interpretation.
- **Untested:** plausible but not exercised.

State the distinction when a reader might confuse the categories.

Never:

- Claim an outage was tested when a dependency was merely skipped.
- Claim observability is unnecessary when a live utilization lookup was removed.
- Claim compute capacity is guaranteed when the service only requests it.
- Invent polling intervals, QPS, private algorithms, or undocumented limits.
- Present reconstructed pseudocode as the vendor’s source code.

## Code and configuration

- Keep one complete core configuration block when exactness matters.
- Use short explanatory snippets for the rest.
- Introduce why each block matters.
- Label actual deployed code, reduced real responses, and conceptual pseudocode.
- Sanitize account IDs, access keys, tokens, internal hostnames, hosted-zone IDs, and record names.
- Link one immutable source commit for complete implementation details.

Avoid setup commands, boilerplate, full IAM policies, and multiple variants of the same configuration.

## Visuals

- Prefer one simplified, publication-quality architecture diagram.
- Use real, annotated screenshots for plan configuration, execution state, and measured results.
- Keep captions conclusion-oriented.
- Cover identifiers.
- Do not use Mermaid unless explicitly requested.
- Do not leave `[Image: ...]` production notes in the article.
- Do not use two screenshots to prove the same fact.

## Results

Report only the measurements needed by the thesis:

- Starting and ending capacity.
- Capacity-gate duration.
- Ordering of capacity and traffic.
- Relevant success or availability.
- End-to-end recovery duration.

Distinguish configured load from achieved load. Do not relabel client-tool failures as service failures.

## Publication and safety

- Scan for secrets and identifiers.
- Keep raw sensitive evidence private.
- Preserve unrelated working-tree changes.
- Save as a draft unless publication is explicitly authorized.
- Verify title, saved state, figures, code blocks, and claim boundaries after editing.

## Codex usage

Preferred:

> Use `$edit-technical-articles` to shorten this article for leadership and SRE readers. Preserve the exact configuration and measured evidence, remove setup history, and update the draft but do not publish it.

For a specific file:

> Use `$edit-technical-articles` on `/absolute/path/to/article.md`. Propose structural changes first and wait for my approval.

If the personal skill is unavailable:

> Read `/Users/bhattchaitanya/Documents/Codex/2026-07-23/cre/arc-eks-24h-lab/ARTICLE-EDITORIAL-GUARDRAIL.md` completely and apply it to the article.

## Final gate

- Can the takeaway be repeated in one sentence?
- Does the title promise exactly what the body proves?
- Does the business value appear before implementation detail?
- Are “how much capacity” and “is it ready” separate?
- Is traffic movement ordered after readiness?
- Is every core claim documented or measured?
- Is pseudocode labeled?
- Are undocumented internals acknowledged?
- Are setup diaries and petty tool details gone?
- Are visuals unique, annotated, and sanitized?
- Did the secret scan pass?
- Is the article still a draft unless publication was explicitly requested?
