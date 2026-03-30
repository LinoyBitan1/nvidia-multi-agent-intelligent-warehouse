#!/usr/bin/env bash
#
# WOSA OpenShift Deployment Script
#
# Usage:
#   NVIDIA_API_KEY=nvapi-... NAMESPACE=wosa ./openshift/deploy-openshift.sh
#
# Optional env vars:
#   LLM_MODEL              - override LLM model (default: nvidia/llama-3.3-nemotron-super-49b-v1)
#   LLM_NIM_URL            - override LLM NIM URL
#   STORAGE_CLASS           - override storage class for PVCs
#   DEMO_DATA_ENABLED       - true/false (default: false); seeds demo inventory/tasks/incidents
#   DEMAND_HISTORY_ENABLED  - true/false (default: false); seeds 180-day demand data
#   MONITORING_ENABLED      - true/false (default: false); deploys ServiceMonitor, PrometheusRule, Grafana Operator
#   GRAFANA_ADMIN_PASSWORD  - override Grafana admin password (default: changeme)
#   MILVUS_GPU_ENABLED     - true/false (default: false); enables GPU-accelerated Milvus (requires NVIDIA GPU node)
#   MILVUS_GPU_TOLERATIONS - comma-separated GPU node taint keys (e.g. "g6-gpu,p4-gpu"); adds tolerations for scheduling
#   DEFAULT_ADMIN_PASSWORD   - override admin password (default: changeme)
#   SKIP_BUILD=true         - skip image build (deploy only, uses existing images)
#   BACKEND_IMAGE           - override backend image (e.g. quay.io/myorg/wosa-backend:1.0.0)
#   FRONTEND_IMAGE          - override frontend image (e.g. quay.io/myorg/wosa-frontend:1.0.0)
#   LLM_CLIENT_TIMEOUT      - LLM API call timeout in seconds (default: 120)
#   GUARDRAILS_TIMEOUT      - NeMo Guardrails API timeout (default: 10)
set -euo pipefail

: "${NVIDIA_API_KEY:?Error: NVIDIA_API_KEY is required}"
: "${NAMESPACE:?Error: NAMESPACE is required}"

HELM_RELEASE="${HELM_RELEASE:-wosa}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm"

oc get namespace "$NAMESPACE" &>/dev/null || oc create namespace "$NAMESPACE"

if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
  NAMESPACE="$NAMESPACE" "${SCRIPT_DIR}/build-openshift.sh"
else
  echo "Skipping image build (SKIP_BUILD=true)"
fi

# DB init SQL scripts
DB_INIT_ARGS=()
SQL_DIR="${SCRIPT_DIR}/../data/postgres"
if [[ -d "${SQL_DIR}" ]]; then
  for f in "${SQL_DIR}"/[0-9]*.sql; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    escaped=$(echo "$fname" | sed 's/\./\\./g')
    DB_INIT_ARGS+=(--set-file "dbInit.scripts.${escaped}=${f}")
  done
fi
MODEL_TRACKING_SQL="${SCRIPT_DIR}/../scripts/setup/create_model_tracking_tables.sql"
if [[ -f "${MODEL_TRACKING_SQL}" ]]; then
  DB_INIT_ARGS+=(--set-file "dbInit.scripts.create_model_tracking_tables\\.sql=${MODEL_TRACKING_SQL}")
fi

# Monitoring dashboard JSON files
MONITORING_ARGS=()
if [[ "${MONITORING_ENABLED:-false}" == "true" ]]; then
  DASHBOARD_DIR="${SCRIPT_DIR}/grafana/dashboards"
  if [[ -d "${DASHBOARD_DIR}" ]]; then
    for f in "${DASHBOARD_DIR}"/*.json; do
      [[ -f "$f" ]] || continue
      dash_name=$(basename "$f" .json)
      MONITORING_ARGS+=(--set-file "monitoring.grafana.dashboards.files.${dash_name}=${f}")
    done
  fi
fi

IMAGE_ARGS=()
if [[ -n "${BACKEND_IMAGE:-}" ]]; then
  IMAGE_ARGS+=(--set "image.repository=${BACKEND_IMAGE%:*}" --set "image.tag=${BACKEND_IMAGE##*:}")
fi
if [[ -n "${FRONTEND_IMAGE:-}" ]]; then
  IMAGE_ARGS+=(--set "frontend.image.repository=${FRONTEND_IMAGE%:*}" --set "frontend.image.tag=${FRONTEND_IMAGE##*:}")
fi

# Build GPU toleration args for Milvus (comma-separated taint keys)
MILVUS_TOLERATION_ARGS=()
if [[ -n "${MILVUS_GPU_TOLERATIONS:-}" ]]; then
  IFS=',' read -ra TKEYS <<< "$MILVUS_GPU_TOLERATIONS"
  for i in "${!TKEYS[@]}"; do
    MILVUS_TOLERATION_ARGS+=(
      --set "milvus.gpu.tolerations[${i}].key=${TKEYS[$i]}"
      --set "milvus.gpu.tolerations[${i}].effect=NoSchedule"
      --set "milvus.gpu.tolerations[${i}].operator=Exists"
    )
  done
fi

helm upgrade --install "$HELM_RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --timeout 15m \
  --set "secrets.nvidiaApiKey=${NVIDIA_API_KEY}" \
  ${LLM_MODEL:+--set "backend.env.llmModel=${LLM_MODEL}"} \
  ${LLM_NIM_URL:+--set "backend.env.llmNimUrl=${LLM_NIM_URL}"} \
  ${STORAGE_CLASS:+--set "storageClass=${STORAGE_CLASS}"} \
  ${DEFAULT_ADMIN_PASSWORD:+--set "backend.env.defaultAdminPassword=${DEFAULT_ADMIN_PASSWORD}"} \
  "${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"}" \
  ${DEMO_DATA_ENABLED:+--set "demoData.enabled=${DEMO_DATA_ENABLED}"} \
  ${DEMAND_HISTORY_ENABLED:+--set "demoDemand.enabled=${DEMAND_HISTORY_ENABLED}"} \
  ${MONITORING_ENABLED:+--set "monitoring.enabled=${MONITORING_ENABLED}"} \
  ${GRAFANA_ADMIN_PASSWORD:+--set "monitoring.grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD}"} \
  ${LLM_CLIENT_TIMEOUT:+--set "backend.env.llmClientTimeout=${LLM_CLIENT_TIMEOUT}"} \
  ${GUARDRAILS_TIMEOUT:+--set "backend.env.guardrailsTimeout=${GUARDRAILS_TIMEOUT}"} \
  ${MILVUS_GPU_ENABLED:+--set "milvus.gpu.enabled=${MILVUS_GPU_ENABLED}"} \
  "${MILVUS_TOLERATION_ARGS[@]+"${MILVUS_TOLERATION_ARGS[@]}"}" \
  "${MONITORING_ARGS[@]+"${MONITORING_ARGS[@]}"}" \
  "${DB_INIT_ARGS[@]+"${DB_INIT_ARGS[@]}"}"

echo "Waiting for deployments to be ready..."
for resource in $(oc get deploy,statefulset -n "$NAMESPACE" -o name); do
  echo "  Waiting for ${resource#*/}..."
  oc rollout status "$resource" -n "$NAMESPACE" --timeout=10m || \
    echo "  Warning: ${resource#*/} not ready - check: oc get pods -n $NAMESPACE"
done

ROUTE=$(oc get route "$HELM_RELEASE" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo ""
echo "=== Done ==="
[[ -n "$ROUTE" ]] && echo "Application URL: https://$ROUTE"
oc get pods -n "$NAMESPACE"
