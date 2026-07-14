#!/usr/bin/env bash
# Render every supported combination and check it is (a) valid Kubernetes, (b)
# actually hardened, and (c) that the safety guards refuse the configurations
# they are supposed to refuse.
#
# The negative cases matter as much as the positive ones: a guard that does not
# fire is not a guard.
set -euo pipefail

DEBUG="${DEBUG:-0}"
failures=0
CHART=charts/bitcoin-stack

# kubeconform needs the CRD schemas for anything outside core Kubernetes. The
# only one this chart emits is ExternalSecret.
SCHEMA_CRD='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

hr() { printf '━%.0s' {1..78}; echo; }

check() {
  local name="$1"; shift
  if "$@" >/tmp/bs-check.log 2>&1; then
    echo "✅ PASS  ${name}"
  else
    echo "❌ FAIL  ${name}"
    [ "$DEBUG" = "1" ] && sed 's/^/         /' /tmp/bs-check.log
    failures=$((failures + 1))
  fi
}

# A guard is only useful if it FAILS the render. Invert the test: the command
# must exit non-zero, and the error must mention the expected reason.
check_guard() {
  local name="$1" expect="$2"; shift 2
  if "$@" >/tmp/bs-guard.log 2>&1; then
    echo "❌ FAIL  ${name} — the chart rendered when it should have refused"
    failures=$((failures + 1))
  elif grep -qi "${expect}" /tmp/bs-guard.log; then
    echo "✅ PASS  ${name}"
  else
    echo "❌ FAIL  ${name} — refused, but not for the expected reason"
    [ "$DEBUG" = "1" ] && sed 's/^/         /' /tmp/bs-guard.log
    failures=$((failures + 1))
  fi
}

render() { helm template bs "$CHART" "$@"; }

validate() {
  render "$@" | kubeconform -strict -summary -ignore-missing-schemas \
    -schema-location default -schema-location "$SCHEMA_CRD" >/dev/null
}

# Every rendered container must be non-root, drop all capabilities, and run a
# digest-pinned image. Asserted on the OUTPUT, so it holds no matter which
# template produced it.
assert_hardened() {
  local out
  out="$(render "$@")"

  grep -q 'runAsNonRoot: true' <<<"$out" || { echo "not runAsNonRoot"; return 1; }
  grep -q 'allowPrivilegeEscalation: false' <<<"$out" || { echo "privilege escalation allowed"; return 1; }
  grep -q 'readOnlyRootFilesystem: true' <<<"$out" || { echo "writable root filesystem"; return 1; }
  grep -q 'drop:' <<<"$out" || { echo "capabilities not dropped"; return 1; }
  grep -q 'automountServiceAccountToken: false' <<<"$out" || { echo "service account token mounted"; return 1; }

  # No image may be referenced without a digest.
  local unpinned
  unpinned="$(grep -E '^\s+image:' <<<"$out" | grep -v '@sha256:' || true)"
  if [ -n "$unpinned" ]; then
    echo "unpinned image: ${unpinned}"
    return 1
  fi
}

hr
echo "🔍 Rendering the matrix"
hr
check "knots + public-pool (default)"      validate
check "core  + public-pool"                validate --set bitcoin-node.node.implementation=core --set bitcoin-node.node.config.consensusrules=null
check "knots, pruned"                      validate --set bitcoin-node.node.config.prune=20000 --set bitcoin-node.storage.size=60Gi
check "knots, signet"                      validate --set bitcoin-node.node.network=signet --set mining-pool.pool.network=testnet
check "node only, no pool"                 validate --set mining-pool.enabled=false
check "ckpool (image supplied)"            validate --set mining-pool.pool.implementation=ckpool \
                                             --set mining-pool.pool.ckpool.image.repository=example/ckpool \
                                             --set mining-pool.pool.ckpool.image.tag=v1 \
                                             --set mining-pool.pool.ckpool.image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000

hr
echo "🔒 Hardening assertions on the rendered output"
hr
check "default: non-root, no caps, read-only root, digest-pinned" assert_hardened
check "core:    non-root, no caps, read-only root, digest-pinned" assert_hardened --set bitcoin-node.node.implementation=core --set bitcoin-node.node.config.consensusrules=null

hr
echo "🚧 The guards must refuse what they are there to refuse"
hr
check_guard "dbcache above the memory limit is refused" \
  "too small for node.config.dbcache" \
  render --set bitcoin-node.node.config.dbcache=8192

check_guard "a grace period too short for the flush is refused" \
  "below the minimum" \
  render --set bitcoin-node.terminationGracePeriodSeconds=60

check_guard "an unpinned node image is refused" \
  "not pinned by digest" \
  render --set bitcoin-node.images.knots.digest=""

check_guard "a Knots-only option under Core is refused" \
  "is a Bitcoin Knots option" \
  render --set bitcoin-node.node.implementation=core --set bitcoin-node.node.config.consensusrules=rdts

check_guard "ckpool without an explicit image is refused" \
  "no default image" \
  render --set mining-pool.pool.implementation=ckpool

check_guard "a pool on the wrong network is refused" \
  "but the pool is configured for" \
  render --set bitcoin-node.node.network=regtest

check_guard "a pool with no node to mine on is refused" \
  "no external node was given" \
  render --set bitcoin-node.enabled=false

hr
if [ "$failures" -ne 0 ]; then
  echo "❌ ${failures} failed"
  exit 1
fi
echo "✅ All render, hardening and guard checks passed"
