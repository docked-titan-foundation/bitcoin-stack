#!/usr/bin/env bash
# Drive the end-to-end test: create a kind cluster (unless one is already in the
# context), install the stack on regtest, run the assertions, tear it down.
#
# CI runs the very same tests/integration script against a kind cluster it made
# itself, so a green run here means a green run there.
set -euo pipefail

CLUSTER="${CLUSTER:-bitcoin-stack-e2e}"
NAMESPACE="${NAMESPACE:-bitcoin-stack-test}"
RELEASE="${RELEASE:-bs}"
DEBUG="${DEBUG:-0}"
KEEP="${KEEP:-0}"
# Set REUSE_CLUSTER=1 to install into whatever kubectl context is already active
# instead of creating a kind cluster.
REUSE_CLUSTER="${REUSE_CLUSTER:-0}"

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$DEBUG" = "1" ]; then
    echo "── pods ──"
    kubectl -n "$NAMESPACE" get pods 2>/dev/null || true
    kubectl -n "$NAMESPACE" describe pods 2>/dev/null | tail -40 || true
    kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/name=mining-pool --tail=40 2>/dev/null || true
    kubectl -n "$NAMESPACE" logs bitcoin-node-0 --tail=40 2>/dev/null || true
  fi
  if [ "$KEEP" = "1" ]; then
    echo "ℹ️  KEEP=1 — leaving the cluster up. Tear it down with:"
    echo "     kind delete cluster --name ${CLUSTER}"
  elif [ "$REUSE_CLUSTER" != "1" ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  else
    helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || true
    kubectl delete namespace "$NAMESPACE" >/dev/null 2>&1 || true
  fi
  exit $rc
}
trap cleanup EXIT

if [ "$REUSE_CLUSTER" != "1" ]; then
  echo "🧪 Creating kind cluster '${CLUSTER}'"
  kind create cluster --name "$CLUSTER" --wait 120s >/dev/null 2>&1
fi

echo "📦 Installing the stack on regtest"
INSTALL_ARGS=(
  "$RELEASE" charts/bitcoin-stack
  --namespace "$NAMESPACE"
  --create-namespace
  --values tests/values/regtest.yaml
  --wait
  --timeout 10m
)
if [ "$DEBUG" = "1" ]; then
  helm install "${INSTALL_ARGS[@]}"
else
  helm install "${INSTALL_ARGS[@]}" >/dev/null
fi

RELEASE="$RELEASE" NAMESPACE="$NAMESPACE" DEBUG="$DEBUG" \
  ./tests/integration/test-bitcoin-stack.sh
