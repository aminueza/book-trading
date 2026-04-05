# CI/CD and Production Safety

Two workflows split by concern. Infrastructure changes (`ci-infrastructure.yml`) deploy via Terraform. Application changes (`ci-application.yml`) build, scan, and deploy via kustomize. Infrastructure goes first; if both change, merge infra PR before the app PR.

## Security Gates

Application code goes through gosec (SAST), govulncheck (dependency CVEs), and Trivy (container image CVEs). Every image gets an SPDX SBOM and SLSA provenance attestation. Cosign signing is built into the pipeline but the key isn't configured yet, see Risk 4 in the security review.

Infrastructure code goes through tfsec and checkov before `terraform plan`. Both run statically against HCL files with no cloud credentials needed, so problems surface during code review.

## How a Deploy Works

The rollout action pins the kustomize overlay to the exact image digest from the build step. It applies with server-side apply, then waits for the rolling update to complete (`maxSurge=1, maxUnavailable=0`).

After rollout, three checks run in sequence: `/readyz` on every pod (verifies Redis connectivity), `/healthz` on one pod (confirms the process is alive), and a smoke test that places a real order and cancels it (validates the full request path end to end).

If any check fails, `kubectl rollout undo` restores the previous revision and Slack gets notified.

## What Prevents Bad Deploys

Production deploys require manual approval via GitHub Environments. A concurrency group ensures only one deploy runs at a time. AWS credentials use OIDC federation, no long-lived keys. `minReadySeconds: 10` catches pods that crash shortly after initial readiness. `revisionHistoryLimit: 5` keeps rollback targets available.

Rolling update over canary because each replica has its own in-memory order book, splitting traffic between two versions would give users inconsistent book state.
## Rollback

Automatic on verification failure. Manual:

```bash
kubectl rollout undo deployment/orderbook -n trading
kubectl rollout undo deployment/orderbook -n trading --to-revision=3
```

## Branching

Trunk-based. Short-lived feature branches, merge to main. Deploys only trigger on main. No staging environment in this implementation; production is gated by approval and post-deploy verification. Adding staging means creating another Terraform environment and a second deploy job.

## Secrets

CI never sees the Redis password. It's injected into pods via Kubernetes Secrets. AWS credentials are ephemeral OIDC tokens (~1h TTL). Nothing is logged or written to disk during CI.

