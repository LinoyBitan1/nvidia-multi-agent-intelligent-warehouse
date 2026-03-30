#!/usr/bin/env bash
#
# WOSA OpenShift Uninstall Script
#
# Usage:
#   NAMESPACE=wosa ./openshift/uninstall-openshift.sh
#
# Optional env vars:
#   HELM_RELEASE  - Helm release name (default: wosa)
#   KEEP_PVCS     - true/false (default: false); keeps persistent data
set -euo pipefail

: "${NAMESPACE:?Error: NAMESPACE is required}"
RELEASE="${HELM_RELEASE:-wosa}"

echo "=== Uninstalling WOSA from namespace: ${NAMESPACE} ==="

echo "Removing Grafana CRs..."
oc delete grafanas,grafanadatasources,grafanadashboards --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "Removing Grafana Operator Subscription..."
oc delete subscription grafana-operator -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "Running helm uninstall..."
helm uninstall "$RELEASE" -n "$NAMESPACE" || true

echo "Removing Grafana Operator CSV..."
oc get csv -n "$NAMESPACE" -o name 2>/dev/null | grep grafana-operator | xargs -r oc delete -n "$NAMESPACE" --ignore-not-found || true

echo "Removing OLM leftovers..."
oc get secret -n "$NAMESPACE" -o name 2>/dev/null | grep grafana | xargs -r oc delete -n "$NAMESPACE" --ignore-not-found || true

echo "Removing cluster-scoped resources..."
oc delete clusterrolebinding "${RELEASE}-grafana-monitoring-view" --ignore-not-found 2>/dev/null || true

echo "Removing build resources..."
oc delete buildconfig,imagestream wosa-backend wosa-frontend -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

if [[ "${KEEP_PVCS:-false}" != "true" ]]; then
  echo "Removing PVCs..."
  oc delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
fi

echo ""
echo "=== Uninstall complete ==="
echo "Remaining resources:"
oc get all,pvc -n "$NAMESPACE" 2>/dev/null || true
