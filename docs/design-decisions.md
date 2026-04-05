# Design Decisions

## Container

Distroless base image (`gcr.io/distroless/static-debian12:nonroot`). No shell, no package manager, minimal CVE surface. The tradeoff is you can't exec into the container for debugging; use ephemeral containers instead.

Static Go binary with `CGO_ENABLED=0` so there's no libc dependency. Combined with `-trimpath` and stripped symbols for a small, reproducible artifact.

Read-only filesystem and all Linux capabilities dropped. Even if someone gets code execution inside the container, there's nothing to work with.

## Kubernetes

CPU request equals limit. This puts pods in the Guaranteed QoS class, which avoids CFS throttling on latency-sensitive workloads and gives them priority during node pressure. The downside is you can't burst above the limit, but for a trading service, predictable latency matters more than occasional burst capacity.

Rolling updates with `maxSurge=1, maxUnavailable=0`. New pods must pass readiness before old ones terminate. Slower than allowing unavailability, but no requests hit a terminating pod.

Topology spread and pod anti-affinity set to "preferred" rather than "required". This distributes pods across zones and nodes for failure resilience, but doesn't block scheduling if the cluster is degraded. A required constraint on a 2-node cluster would make the third replica unschedulable.

NetworkPolicy starts from deny-all with explicit allowlist: Istio on 8080, Prometheus on 9090, Redis on 6379, DNS on 53. Everything else is blocked, including pod-to-pod traffic outside these rules.

HPA with 300s scale-down stabilization. Trading traffic is bursty; without stabilization the autoscaler would flap between 3 and 10 pods on every spike. Scale-up is 30s because responding to load quickly matters more than saving a pod.

## Infrastructure as Code

Terraform split into four modules (vpc, eks, redis, monitoring). Each can be reviewed, tested, and applied independently. During an incident you can change monitoring without touching the VPC.

Remote state in S3 with DynamoDB locking and encryption. Prevents concurrent applies that could corrupt state. State is versioned for rollback.

`prevent_destroy` on VPC, subnets, and Redis. A `terraform destroy` that would delete these resources fails and requires an explicit lifecycle override. This is the Terraform equivalent of a seatbelt.

Separate node groups for system workloads (m6i.large, tainted for CriticalAddonsOnly) and trading workloads (c6i.xlarge, compute-optimized). CoreDNS and kube-proxy run on their own nodes so application resource pressure can't starve cluster components.

tfsec and checkov run in CI before `terraform plan`. Catches open security groups, public buckets, disabled encryption during code review instead of after apply.

## What I'd Change for Real Production

1. **Write-ahead log.** Persist order events before acknowledging the client. Redis Streams or Kafka.
2. **Distributed rate limiting.** Istio EnvoyFilter with Redis backend, replacing the per-pod in-memory limiter.
3. **Binary protocol.** gRPC or FIX instead of JSON/HTTP for lower serialization overhead.
4. **Better data structures.** Skiplist or red-black tree for O(log n) insertion instead of the current O(n log n) sorted slice.
5. **Canary deploys.** Istio VirtualService traffic splitting for progressive rollout instead of rolling update.
6. **External Secrets Operator.** Sync from AWS Secrets Manager instead of manual `kubectl create secret`.
