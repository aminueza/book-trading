# CI/CD and Production Safety

## Pipeline Architecture

Two workflows, split by concern:

![CI Pipelines](images/ci-pipelines-diagram.svg)

**`ci-infrastructure.yml`** triggers on `infrastructure/terraform/**` changes. Manages VPC, EKS, ElastiCache, monitoring.

![Infrastructure pipeline](images/infra-pipeline.svg)

**`ci-application.yml`** triggers on `application/**`, `Dockerfile`, `go.mod` changes. Builds and deploys the orderbook service.

![Application pipeline](images/app-pipeline.svg)

Infrastructure deploys first. If both change in the same PR cycle, merge infra first. The app deploy assumes the cluster exists.

## Reusable Actions

All CI logic lives in composite actions under `.github/workflows/actions/`:

| Action | What it does |
|--------|-------------|
| `lint` | gofmt, go vet, golangci-lint, gosec, govulncheck |
| `build` | Docker BuildKit, Cosign signing, SBOM (SPDX), SLSA provenance |
| `security` | Trivy container CVE scan with SARIF upload |
| `infra-security` | tfsec, checkov, optional conftest (OPA policies) |
| `deploy` | Terraform fmt/init/validate/plan/apply, AWS OIDC |
| `rollout` | Kustomize apply, rollout wait, readiness + liveness + smoke test, auto-rollback, Slack notify |

## Security Gates

### Application

gosec does SAST (hardcoded credentials, injection patterns). govulncheck checks Go dependencies against the vulnerability database. Trivy scans the built container image for OS and binary CVEs. Cosign signs the image so we can verify it hasn't been tampered with after build. Every image also gets an SPDX SBOM and SLSA provenance attestation attached as registry attestations.

### Infrastructure

tfsec catches Terraform misconfigs (open security groups, public buckets, disabled encryption, overly permissive IAM). checkov runs CIS benchmarks. Both analyze the HCL files statically, no cloud credentials needed. Problems show up during code review, not after apply.

## How a Deploy Works

The rollout action pins the kustomize overlay to the exact image digest from the build step. Tags are mutable, digests are not.

It applies with `kubectl apply --server-side --field-manager=ci-deploy` which tracks field ownership between CI and manual changes.

The Deployment is configured with `maxSurge=1, maxUnavailable=0`. Kubernetes creates one new pod, waits for readiness, terminates one old pod. Repeat until done. No requests hit a terminating pod.

After the rollout completes, the pipeline runs three checks:

**Readiness.** Port-forwards to every pod, hits `/readyz`. This checks Redis connectivity and application state. One failure triggers rollback.

**Liveness.** Hits `/healthz` to confirm the process is alive, not just ready.

**Smoke test.** Places a real order via `POST /api/v1/orders` and cancels it. Validates the full path: JSON parsing, validation, matching engine, Redis persistence, cache invalidation, response serialization. If any of these are broken, we know before users do.

If any check fails, `kubectl rollout undo` restores the previous revision and Slack gets notified.

## What Prevents Bad Deploys

Manual approval via GitHub Environment `production` with required reviewers. No one can push to production without sign-off.

Concurrency group `deploy-production` ensures only one deploy runs at a time. A second push queues instead of running in parallel.

New PR pushes cancel in-progress CI for that branch so we don't waste runner time on superseded commits.

AWS OIDC federation for credentials. No long-lived access keys in GitHub Secrets. Session tokens expire in about an hour.

`revisionHistoryLimit: 5` keeps the last five revisions. `minReadySeconds: 10` means a pod must stay healthy for 10 seconds before the rollout progresses, which catches the startup race conditions that crash-loop after initial readiness.

## Rollback

Automatic on any verification failure. Manual when needed:

```bash
kubectl rollout undo deployment/orderbook -n trading
kubectl rollout undo deployment/orderbook -n trading --to-revision=3
kubectl rollout history deployment/orderbook -n trading
```

## Branching Model

![Branching model](images/branching-model.svg)

Trunk-based: short-lived feature branches, merge to main. No long-lived develop or release branches. The `develop` branch in the CI trigger exists for teams that want it, but deploys only run on `main`.

No staging environment in this implementation. Production is gated by manual approval and post-deploy verification. Adding staging means creating `infrastructure/terraform/environments/staging/` and a second deploy job. The modules and overlays already support it.

## Secrets

![Secrets flow](images/secrets-flow.svg)

CI never touches the Redis password. It's injected into pods via Kubernetes Secrets. AWS credentials are ephemeral OIDC tokens. Nothing is logged, echoed, or written to disk.

## Partial Deploys

If the pipeline fails mid-rollout, some pods run the new version and some run the old. `kubectl rollout undo` reverts everything. If the GitHub Actions runner itself crashes, Kubernetes continues the rollout independently. The next CI run detects the state and either verifies or rolls back.
