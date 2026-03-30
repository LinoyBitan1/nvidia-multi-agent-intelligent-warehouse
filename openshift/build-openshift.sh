#!/usr/bin/env bash
#
# Builds backend and frontend images into the OpenShift internal registry.
# Usage: NAMESPACE=wosa ./openshift/build-openshift.sh
set -euo pipefail

: "${NAMESPACE:?NAMESPACE is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SOURCE_DIR:-${SCRIPT_DIR}/..}"

build_image() {
  local name=$1 dockerfile=$2
  echo ""
  echo "Building ${name}..."
  if ! oc get buildconfig "${name}" -n "${NAMESPACE}" &>/dev/null; then
    oc new-build --name="${name}" --binary --strategy=docker -n "${NAMESPACE}"
    oc patch buildconfig "${name}" -n "${NAMESPACE}" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/strategy/dockerStrategy/dockerfilePath\",\"value\":\"${dockerfile}\"}]"
  fi
  oc start-build "${name}" --from-dir="${SOURCE_DIR}" --follow -n "${NAMESPACE}"
}

build_image "wosa-backend"  "openshift/Dockerfile.backend"
build_image "wosa-frontend" "openshift/Dockerfile.frontend"

echo ""
echo "Build complete!"
echo "  Backend : image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/wosa-backend:latest"
echo "  Frontend: image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/wosa-frontend:latest"
