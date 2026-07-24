# Gatling verification

This simulation independently verifies that the pre-scaled destination can
serve the intended open arrival rate. It does not participate in ARC plan
execution.

```bash
npm ci
npm run test:load -- \
  target=http://YOUR_DESTINATION_NLB \
  rate=1000 \
  ramp=15 \
  duration=45
```

The target is supplied at runtime so an ephemeral load-balancer hostname is
never committed. Gatling writes the report beneath `target/gatling/`.
