#!/usr/bin/env bash
# Installs Istio (base, istiod, ingress gateway), Bitnami Redis, then applies the local kustomize overlay.
# Args: KUBECONFIG_PATH ISTIO_CHART_VERSION REDIS_CHART_VERSION OVERLAY_DIR
set -euo pipefail

KUBECONFIG_PATH="${1:?kubeconfig path required}"
ISTIO_VER="${2:?istio chart version required}"
REDIS_CHART_VER="${3:?redis chart version required}"
OVERLAY_DIR="${4:?overlay dir required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
MONITORING_DIR="${REPO_ROOT}/infrastructure/deploy/kubernetes/monitoring/local"

export KUBECONFIG="$KUBECONFIG_PATH"

for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: '$cmd' not found — install Helm and kubectl" >&2
    exit 1
  }
done

# Helm 4 defaults to server-side apply; upgrading istio-base then fights the live
# ValidatingWebhookConfiguration (fields owned by istiod / "pilot-discovery").
# Local KinD: always remove prior Istio Helm releases + webhooks, then install fresh.
echo "[istio] Clean slate before install (Helm 4 / webhook field-manager safe)"
helm uninstall istio-ingressgateway -n istio-system 2>/dev/null || true
helm uninstall istiod -n istio-system 2>/dev/null || true
helm uninstall istio-base -n istio-system 2>/dev/null || true
kubectl delete validatingwebhookconfiguration istiod-default-validator --ignore-not-found
kubectl delete mutatingwebhookconfiguration istio-sidecar-injector --ignore-not-found 2>/dev/null || true
kubectl wait --for=delete pod -l app=istiod -n istio-system --timeout=120s 2>/dev/null || true
kubectl get ns istio-system >/dev/null 2>&1 || kubectl create namespace istio-system

echo "[istio] Helm: base / istiod / gateway (chart version ${ISTIO_VER})"
helm upgrade --install istio-base base \
  --namespace istio-system --create-namespace \
  --version "${ISTIO_VER}" \
  --repo https://istio-release.storage.googleapis.com/charts \
  --wait --timeout 10m

helm upgrade --install istiod istiod \
  --namespace istio-system \
  --version "${ISTIO_VER}" \
  --repo https://istio-release.storage.googleapis.com/charts \
  --wait --timeout 10m

# Helm 4 merges a top-level "defaults" key into values; Istio's gateway chart schema
# rejects it ("additional properties 'defaults' not allowed"). Skip values schema when supported (Helm 3.14+).
GATEWAY_SCHEMA_FLAGS=()
if helm upgrade -h 2>/dev/null | grep -qF 'skip-schema-validation'; then
  GATEWAY_SCHEMA_FLAGS=(--skip-schema-validation)
fi

helm upgrade --install istio-ingressgateway gateway \
  --namespace istio-system \
  --version "${ISTIO_VER}" \
  --repo https://istio-release.storage.googleapis.com/charts \
  --wait --timeout 10m \
  "${GATEWAY_SCHEMA_FLAGS[@]}"

echo "[redis] Bitnami Redis standalone, no auth, no PVC (chart ${REDIS_CHART_VER})"
# docker.io/bitnami/* often hits Hub rate limits or policy; bitnamilegacy/redis keeps the same
# entrypoint/layout the chart expects and usually pulls without extra registry auth (local KinD).
helm upgrade --install redis redis \
  --namespace trading --create-namespace \
  --version "${REDIS_CHART_VER}" \
  --repo https://charts.bitnami.com/bitnami \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/redis \
  --set architecture=standalone \
  --set auth.enabled=false \
  --set master.persistence.enabled=false \
  --set master.resources.requests.cpu=50m \
  --set master.resources.requests.memory=64Mi \
  --set master.resources.limits.cpu=250m \
  --set master.resources.limits.memory=128Mi \
  --set master.podSecurityContext.enabled=true \
  --set master.podSecurityContext.fsGroup=1001 \
  --set master.podSecurityContext.runAsUser=1001 \
  --set master.podSecurityContext.runAsNonRoot=true \
  --set master.podSecurityContext.seccompProfile.type=RuntimeDefault \
  --set master.containerSecurityContext.enabled=true \
  --set master.containerSecurityContext.runAsUser=1001 \
  --set master.containerSecurityContext.runAsNonRoot=true \
  --set master.containerSecurityContext.allowPrivilegeEscalation=false \
  --set master.containerSecurityContext.capabilities.drop={ALL} \
  --set master.containerSecurityContext.seccompProfile.type=RuntimeDefault \
  --wait --timeout 10m

echo "[orderbook] kubectl apply -k ${OVERLAY_DIR}"
kubectl apply -k "${OVERLAY_DIR}"
kubectl rollout status deployment/orderbook -n trading --timeout=300s

echo "[monitoring] Prometheus + Grafana (kubectl apply -k ${MONITORING_DIR})"
kubectl delete deployment,service redis-exporter -n monitoring --ignore-not-found 2>/dev/null || true
kubectl apply -k "${MONITORING_DIR}"
kubectl rollout status deployment/redis-exporter -n trading --timeout=120s
kubectl rollout status deployment/prometheus -n monitoring --timeout=120s
kubectl rollout status deployment/grafana -n monitoring --timeout=120s

echo ""
echo "Local URLs (KinD extraPortMappings):"
echo "  Orderbook API: http://127.0.0.1:8001/healthz"
echo "  Grafana:       http://127.0.0.1:3000  (anonymous Admin; login admin/admin)"
echo "done."
