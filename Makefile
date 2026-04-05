# Makefile — One-command workflows for the order book service.
#
# Quick start (matches infrastructure/terraform/environments/local):
#   make up        → docker build + TF apply + kubectl apply -k (overlay + monitoring)
#   make port-forward        → port-forward Istio ingress (keep running) → :8080
#   make validate     → validate.sh against http://127.0.0.1:8001 (direct NodePort)
#   make redis-cli    → Redis CLI in-cluster (trading/redis-master)
#   make down         → terraform destroy + kind delete
#
# KinD cluster name defaults to orderbook-local (override: make up CLUSTER_NAME=my-cluster).
#
# CLI prerequisites for `make up`:
#   make deps-info    → print install links / commands (any OS)
#   make install-deps → macOS: brew install kind kubernetes-cli helm opentofu (needs Homebrew)
#   Docker Desktop / engine must be installed separately (see deps-info).
#
# IaC: Homebrew deprecated the core `terraform` formula (BUSL). This Makefile uses
# `tofu` when available (brew install opentofu), else `terraform` if on PATH.

.PHONY: up down validate validate-istio test build lint clean status logs port-forward restart load-test chaos-node-failure chaos-drain _check-deps _check-go install-deps deps deps-info link-kubectl redis-cli redis-forward

CLUSTER_NAME ?= orderbook-local
# KinD local API: NodePort on host :8001 (Terraform extraPortMappings). Use LOADTEST_BASE=http://localhost:8080 with `make port-forward` for Istio.
LOADTEST_BASE ?= http://127.0.0.1:8001
# Host CPU → linux Go arch (KinD nodes usually match Docker host; avoids amd64 image on arm64 clusters).
TARGETARCH ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/arm64/arm64/')
# Prefer OpenTofu; fall back to HashiCorp Terraform if installed from releases / another tap.
TF := $(shell if command -v tofu >/dev/null 2>&1; then echo tofu; elif command -v terraform >/dev/null 2>&1; then echo terraform; else echo tofu; fi)
TF_LOCAL_DIR := infrastructure/terraform/environments/local
# Written by Terraform after apply; used by kubectl helpers below.
KUBECONFIG_FILE := $(TF_LOCAL_DIR)/kubeconfig.yaml
KUBECTL := kubectl --kubeconfig $(KUBECONFIG_FILE)
# IDE/launchd often run make with a minimal PATH; prepend typical Go locations.
GO := $(shell \
	PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:$${PATH}"; \
	if command -v go >/dev/null 2>&1; then command -v go; \
	elif [ -x /opt/homebrew/bin/go ]; then echo /opt/homebrew/bin/go; \
	elif [ -x /usr/local/go/bin/go ]; then echo /usr/local/go/bin/go; \
	else echo ""; fi)

# ============================================================
# Redis (Bitnami in namespace trading — no host port; needs kubectl + kubeconfig)
#   make redis-cli      → redis-cli inside the cluster (no local port)
#   make redis-forward  → localhost:16379 → redis:6379 (for desktop clients)
# ============================================================

redis-cli:
	@$(KUBECTL) exec -n trading -it svc/redis-master -- redis-cli

redis-forward:
	@echo "Redis → 127.0.0.1:16379 (no password in local Helm values) — Ctrl+C to stop"
	@$(KUBECTL) port-forward -n trading svc/redis-master 16379:6379

# ============================================================
# Primary workflows
# ============================================================

## Build image, init/apply local Terraform (KinD + workloads)
up: _check-deps build
	@echo ""
	@echo "Provisioning local cluster ($(CLUSTER_NAME)) via $(TF)..."
	@echo "  - Single-node KinD (see $(TF_LOCAL_DIR)/main.tf)"
	@echo "  - Bootstrap: Istio + Redis + kustomize (trading) + monitoring (Prometheus/Grafana/redis_exporter)"
	@echo ""
	cd $(TF_LOCAL_DIR) && \
		$(TF) init -input=false && \
		$(TF) apply -auto-approve \
			-var=cluster_name=$(CLUSTER_NAME)
	@echo ""
	@echo "Kustomize sync (idempotent; ensures overlay + monitoring match repo)..."
	@$(KUBECTL) apply -k infrastructure/deploy/kubernetes/overlays/local
	@$(KUBECTL) delete deployment,service redis-exporter -n monitoring --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) apply -k infrastructure/deploy/kubernetes/monitoring/local
	@echo "Restarting Prometheus to pick up scrape config changes..."
	@$(KUBECTL) rollout restart deployment/prometheus -n monitoring
	@$(KUBECTL) rollout status deployment/prometheus -n monitoring --timeout=60s
	@echo ""
	@echo "URLs:  API (NodePort)  http://127.0.0.1:8001"
	@echo "       Grafana         http://127.0.0.1:3000"
	@echo "Optional: make port-forward  →  http://localhost:8080 via Istio, then make validate-istio"

## Tear down Terraform-managed KinD cluster
down:
	@echo "Tearing down $(CLUSTER_NAME)..."
	cd $(TF_LOCAL_DIR) && $(TF) destroy -auto-approve \
		-var=cluster_name=$(CLUSTER_NAME) || true
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@echo "Done."

## KinD host mapping: orderbook NodePort → 127.0.0.1:8001 (see terraform local extraPortMappings)
validate:
	@echo "Running validation against http://127.0.0.1:8001..."
	@./infrastructure/scripts/validate.sh http://127.0.0.1:8001

## Use after: make port-forward  (Istio ingress on localhost:8080)
validate-istio:
	@echo "Running validation against http://localhost:8080 (Istio)..."
	@./infrastructure/scripts/validate.sh http://localhost:8080

## Go unit tests + coverage summary (needs Go 1.24+ on PATH or under Homebrew /usr/local/go)
test: _check-go
	"$(GO)" test -race -v -coverprofile=coverage.out ./...
	@echo ""
	@"$(GO)" tool cover -func=coverage.out | tail -1

## Image tag must match terraform variable orderbook_image (default :latest)
build:
	docker build --build-arg TARGETARCH=$(TARGETARCH) -t orderbook-service:latest .

## Linters
lint: _check-go
	golangci-lint run --timeout=5m ./...
	$(TF) fmt -check -recursive infrastructure/terraform/

# ============================================================
# Operational helpers (need apply + kubeconfig file)
# ============================================================

status:
	@echo "=== Cluster ($(CLUSTER_NAME)) ==="
	@$(KUBECTL) cluster-info 2>/dev/null || echo "No kubeconfig at $(KUBECONFIG_FILE) — run make up first."
	@echo ""
	@echo "=== Pods ==="
	@$(KUBECTL) get pods -A 2>/dev/null || true
	@echo ""
	@echo "=== trading ==="
	@$(KUBECTL) get deployments,services -n trading 2>/dev/null || true

## Port-forward Istio ingress to localhost:8080 (used by validate-istio and load-test)
port-forward:
	@echo "Forwarding localhost:8080 -> istio-ingressgateway:80 ($(KUBECONFIG_FILE))"
	$(KUBECTL) port-forward -n istio-system svc/istio-ingressgateway 8080:80

## Tail orderbook logs
logs:
	$(KUBECTL) logs -n trading -l app.kubernetes.io/name=orderbook --follow --tail=80

restart:
	$(KUBECTL) rollout restart deployment/orderbook -n trading
	$(KUBECTL) rollout status deployment/orderbook -n trading --timeout=120s

# ============================================================
# Load testing (hey: installed via make install-deps / brew install hey)
# ============================================================

load-test:
	@set -e; \
	PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH"; \
	command -v hey >/dev/null 2>&1 || { \
	  echo "Error: hey not on PATH — brew install hey   or   make install-deps"; \
	  exit 1; \
	}; \
	echo "Sending 1000 POSTs (50 concurrent) → $(LOADTEST_BASE)/api/v1/orders"; \
	echo "  (default: KinD NodePort :8001; Istio: make port-forward in another terminal, then LOADTEST_BASE=http://127.0.0.1:8080 make load-test)"; \
	hey -n 1000 -c 50 -m POST \
		-H "Content-Type: application/json" \
		-d '{"pair":"BTC-USD","side":"buy","price":50000,"quantity":0.1}' \
		"$(LOADTEST_BASE)/api/v1/orders"
	@echo ""
	@echo "Grafana (KinD NodePort): http://127.0.0.1:3000"

# ============================================================
# Chaos (single-node KinD has no workers — these are no-ops / hints)
# ============================================================

chaos-node-failure:
	@echo "This repo's Terraform KinD cluster is single-node only."
	@echo "To experiment: add a worker in infrastructure/terraform/environments/local/main.tf, or stop the"
	@echo "Docker container manually (will disrupt the whole API):"
	@echo "  docker stop $(CLUSTER_NAME)-control-plane"

chaos-drain:
	@echo "No worker node to drain. With a multi-node kind_config, use:"
	@echo "  kubectl drain <node> --ignore-daemonsets --kubeconfig=$(KUBECONFIG_FILE)"

# ============================================================
# Dependency checks & installing CLIs
# ============================================================

## Print required tools and official install links (use on Linux or without Homebrew)
deps-info:
	@echo "Required for \`make up\`:"
	@echo ""
	@echo "  Docker (engine or Desktop) — must be running"
	@echo "    https://docs.docker.com/get-docker/"
	@echo ""
	@echo "  kind (Kubernetes in Docker)"
	@echo "    macOS (Homebrew): brew install kind"
	@echo "    Other: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
	@echo ""
	@echo "  kubectl"
	@echo "    macOS (Homebrew): brew install kubernetes-cli"
	@echo "    If you see 'installed but not linked': brew link --overwrite kubernetes-cli  (or: make link-kubectl)"
	@echo "    Other: https://kubernetes.io/docs/tasks/tools/"
	@echo ""
	@echo "  Helm 3 or 4 (local bootstrap reinstalls Istio each run to avoid Helm 4 SSA webhook conflicts)"
	@echo "    macOS (Homebrew): brew install helm"
	@echo "    Other: https://helm.sh/docs/intro/install/"
	@echo ""
	@echo "  OpenTofu (recommended) or Terraform — same HCL; this repo uses whichever"
	@echo "  binary is found first: \`tofu\` then \`terraform\` (see TF in Makefile)."
	@echo "    OpenTofu (MPL, Homebrew): brew install opentofu   → run \`tofu init/apply\`"
	@echo "    HashiCorp Terraform (BUSL): https://developer.hashicorp.com/terraform/install"
	@echo "    Note: \`brew install terraform\` was removed from homebrew/core (license)."
	@echo ""
	@echo "Go (for \`make test\` / \`make lint\`):"
	@echo "  https://go.dev/dl/   or   macOS: brew install go"
	@echo ""
	@echo "  hey (HTTP load gen for \`make load-test\`)"
	@echo "    macOS: brew install hey   (included in \`make install-deps\`)"
	@echo "    Other: go install github.com/rakyll/hey@latest  (add GOPATH/bin to PATH)"
	@echo ""
	@echo "Optional:"
	@echo "  golangci-lint — \`make lint\`  https://golangci-lint.run/welcome/install/"

## macOS + Homebrew: kind, kubectl, helm, opentofu, hey (Docker: Docker Desktop separately)
install-deps:
	@set -e; \
	case "$$(uname -s)" in \
	Darwin) \
	  command -v brew >/dev/null 2>&1 || { echo "Homebrew not found. https://brew.sh — or: make deps-info"; exit 1; }; \
	  echo "Installing kind, kubernetes-cli (kubectl), helm, opentofu, hey via Homebrew..."; \
	  brew install kind kubernetes-cli helm opentofu hey; \
	  echo "Linking kubectl into PATH (fixes 'installed but not linked')..."; \
	  brew link --overwrite kubernetes-cli; \
	  echo ""; \
	  echo "Done. Install/start Docker Desktop if needed: https://www.docker.com/products/docker-desktop/"; \
	  ;; \
	*) \
	  echo "Automatic install is only wired for macOS + Homebrew."; \
	  echo "On this OS, use: make deps-info"; \
	  exit 1 ;; \
	esac

deps: install-deps

## macOS + Homebrew: put kubectl on PATH if kubernetes-cli is installed but unlinked
link-kubectl:
	@command -v brew >/dev/null 2>&1 || { echo "Homebrew required"; exit 1; }
	brew link --overwrite kubernetes-cli

_check-go:
	@[ -n "$(GO)" ] && [ -x "$(GO)" ] || { \
	  echo "Error: go not found (make saw a minimal PATH). Install Go 1.24+:"; \
	  echo "  https://go.dev/dl/   or   macOS: brew install go"; \
	  echo "Then ensure go is on PATH, or run: export PATH=\"/opt/homebrew/bin:/usr/local/go/bin:\$$PATH\""; \
	  exit 1; \
	}

_check-deps:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker not on PATH — https://docs.docker.com/get-docker/  (make deps-info)"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "Error: kind not on PATH — brew install kind   or   make install-deps"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { \
	  echo "Error: kubectl not on PATH (needed by the post-apply Helm/kubectl script)."; \
	  echo "  Install:   brew install kubernetes-cli"; \
	  echo "  If brew says 'installed but not linked':  brew link --overwrite kubernetes-cli   or   make link-kubectl"; \
	  echo "  Or:        make install-deps"; \
	  exit 1; \
	}
	@command -v helm >/dev/null 2>&1 || { echo "Error: helm not on PATH — brew install helm   or   make install-deps  (Helm 3/4 OK)"; exit 1; }
	@(command -v tofu >/dev/null 2>&1 || command -v terraform >/dev/null 2>&1) || { echo "Error: tofu/terraform not on PATH — brew install opentofu   or   make deps-info"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Error: Docker is not running — start Docker Desktop / engine"; exit 1; }

clean:
	rm -f coverage.out
	docker rmi orderbook-service:latest 2>/dev/null || true
