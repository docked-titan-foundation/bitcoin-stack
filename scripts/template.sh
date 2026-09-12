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
# only one this chart emits is ExternalSecret, and it is vendored under
# tests/schemas rather than fetched.
#
# Vendoring is not only about the network being flaky. kubeconform tries schema
# locations IN ORDER, so with a remote CRD catalog second, every ExternalSecret
# validation first asks the core-Kubernetes schema repo for a CRD it cannot have
# — a guaranteed 404, which caches nothing and therefore repeats on every single
# run forever. Putting a local location first ends that: the file is found
# immediately and nothing is requested. A missing local file costs one stat, so
# core kinds fall through to `default` as before.
#
# Refresh it from the upstream catalog when external-secrets ships a new version:
#   curl -sSL -o tests/schemas/external-secrets.io/externalsecret_v1.json \
#     https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/external-secrets.io/externalsecret_v1.json
SCHEMA_LOCAL='tests/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# `default` is a remote location too — it resolves to yannh/kubernetes-json-schema
# on raw.githubusercontent.com, so EVERY resource kind is fetched, not just the
# CRD above. Uncached that is 18 validate calls x up to 12 resources per run, and
# any blip on that host surfaces as a random chart check "failing" for a reason
# that has nothing to do with the chart. Cache the fetches instead: the schemas
# are immutable for a pinned Kubernetes version.
SCHEMA_CACHE="${SCHEMA_CACHE:-.cache/kubeconform}"
mkdir -p "$SCHEMA_CACHE"

# Pin what `default` validates against. Without this it tracks master, so the
# same commit can pass today and fail tomorrow because upstream published a new
# Kubernetes release.
#
# This is the FLOOR from the charts' kubeVersion (">=1.25.0-0"), not the newest
# release, and deliberately so: validating against the oldest cluster the charts
# claim to support is what proves the claim. Raise both together or neither.
KUBE_VERSION="${KUBE_VERSION:-1.25.0}"

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

# -ignore-missing-schemas is deliberately NOT set. It used to be, because the CRD
# was fetched and a fetch can fail — but "could not check it" and "checked it and
# it is fine" then reported identically, which is the same trap the guard checks
# below exist to avoid. With the only CRD vendored, nothing is legitimately
# missing, so a missing schema now means someone added a resource kind without
# vendoring its schema, and that should fail rather than quietly skip.
validate() {
  render "$@" | kubeconform -strict -summary \
    -cache "$SCHEMA_CACHE" -kubernetes-version "$KUBE_VERSION" \
    -schema-location "$SCHEMA_LOCAL" -schema-location default >/dev/null
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
check "ckpool (org image, digest pinned)"  validate --set mining-pool.pool.implementation=ckpool \
                                             --set mining-pool.pool.ckpool.image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
check "custom node image (BYO, digest pinned)"  validate --set bitcoin-node.node.implementation=custom \
                                             --set bitcoin-node.image.repository=ghcr.io/example/bitcoin \
                                             --set bitcoin-node.image.tag=git-3f1a9c2 \
                                             --set bitcoin-node.image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
check "pool wait-for-sync disabled"        validate --set mining-pool.bitcoin.waitForSync.enabled=false
check "node RPC secret via externalSecret" validate --set bitcoin-node.secret.provider=externalSecret

# Publishing endpoints under hostnames. NET_* are the building blocks: a domain,
# then whichever scopes the case needs.
NET_BASE=(--set global.networking.baseDomain=example.com)
NET_INTERNAL=(--set global.networking.scopes.internal.publishDns=true
              --set global.networking.scopes.internal.issuer=internal-ca)
NET_EXTERNAL=(--set global.networking.scopes.external.publishDns=true
              --set global.networking.scopes.external.issuer=letsencrypt-prod)
NET_LB=(--set bitcoin-node.p2p.service.type=LoadBalancer)

check "networking: pool API, one scope" \
  validate "${NET_BASE[@]}" "${NET_INTERNAL[@]}" --set mining-pool.networking.api.scopes='{internal}'
check "networking: pool API, both scopes, different issuers" \
  validate "${NET_BASE[@]}" "${NET_INTERNAL[@]}" "${NET_EXTERNAL[@]}" \
    --set mining-pool.networking.api.scopes='{internal,external}'
check "networking: stratum + P2P records" \
  validate "${NET_BASE[@]}" "${NET_INTERNAL[@]}" "${NET_LB[@]}" \
    --set mining-pool.networking.stratum.scopes='{internal}' \
    --set bitcoin-node.networking.p2p.scopes='{internal}'
check "networking: pool API without TLS (plain HTTP on a LAN)" \
  validate "${NET_BASE[@]}" --set global.networking.scopes.internal.publishDns=true \
    --set mining-pool.networking.api.scopes='{internal}'
check "networking: bring-your-own TLS secret" \
  validate "${NET_BASE[@]}" --set global.networking.scopes.internal.publishDns=true \
    --set mining-pool.networking.api.tlsSecrets.internal=my-cert \
    --set mining-pool.networking.api.scopes='{internal}'
check "networking: a renamed scope is just a map key" \
  validate --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.lan.subdomain=lan \
    --set global.networking.scopes.lan.publishDns=true \
    --set global.networking.scopes.lan.issuer=internal-ca \
    --set mining-pool.networking.api.scopes='{lan}'
check "networking: explicit host override, no baseDomain" \
  validate --set global.networking.scopes.internal.publishDns=true \
    --set global.networking.scopes.internal.issuer=internal-ca \
    --set mining-pool.networking.api.hosts.internal=stats.example.net \
    --set mining-pool.networking.api.scopes='{internal}'
check "networking: node published, pool not (asymmetric)" \
  validate "${NET_BASE[@]}" "${NET_INTERNAL[@]}" "${NET_LB[@]}" \
    --set bitcoin-node.networking.p2p.scopes='{internal}'
check "networking: RPC published, deliberately" \
  validate "${NET_BASE[@]}" "${NET_INTERNAL[@]}" \
    --set bitcoin-node.rpc.allowSubnet=10.42.0.0/16 \
    --set bitcoin-node.networking.rpc.scopes='{internal}'

hr
echo "🔒 Hardening assertions on the rendered output"
hr
check "default: non-root, no caps, read-only root, digest-pinned" assert_hardened
check "core:    non-root, no caps, read-only root, digest-pinned" assert_hardened --set bitcoin-node.node.implementation=core --set bitcoin-node.node.config.consensusrules=null
check "custom:  non-root, no caps, read-only root, digest-pinned" assert_hardened --set bitcoin-node.node.implementation=custom \
  --set bitcoin-node.image.repository=ghcr.io/example/bitcoin --set bitcoin-node.image.tag=git-3f1a9c2 \
  --set bitcoin-node.image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000

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

check_guard "a custom implementation without an image is refused" \
  "image.repository is empty" \
  render --set bitcoin-node.node.implementation=custom

check_guard "a custom image without a digest is refused" \
  "not pinned by digest" \
  render --set bitcoin-node.node.implementation=custom \
    --set bitcoin-node.image.repository=ghcr.io/example/bitcoin --set bitcoin-node.image.tag=git-3f1a9c2

check_guard "ckpool with an unpinned image is refused" \
  "not pinned by digest" \
  render --set mining-pool.pool.implementation=ckpool --set mining-pool.pool.ckpool.image.digest=""

check_guard "a pool on the wrong network is refused" \
  "but the pool is configured for" \
  render --set bitcoin-node.node.network=regtest

check_guard "a pool with no node to mine on is refused" \
  "no external node was given" \
  render --set bitcoin-node.enabled=false

check_guard "disabling both subcharts is refused" \
  "there is nothing to install" \
  render --set bitcoin-node.enabled=false --set mining-pool.enabled=false

check_guard "an unknown scope name is refused" \
  "unknown scope 'typo'" \
  render --set global.networking.baseDomain=example.com \
    --set mining-pool.networking.api.scopes='{typo}'

check_guard "publishing with no baseDomain and no explicit host is refused" \
  "baseDomain" \
  render --set global.networking.scopes.internal.publishDns=true \
    --set mining-pool.networking.api.scopes='{internal}'

check_guard "a raw-TCP endpoint in a scope that publishes no record is refused" \
  "no scope in that list has publishDns" \
  render --set global.networking.baseDomain=example.com \
    --set mining-pool.networking.stratum.scopes='{internal}'

check_guard "publishing stratum from a ClusterIP is refused" \
  "stratum.service.type is ClusterIP" \
  render --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.publishDns=true \
    --set mining-pool.stratum.service.type=ClusterIP \
    --set mining-pool.networking.stratum.scopes='{internal}'

check_guard "publishing P2P from a ClusterIP is refused" \
  "p2p.service.type is ClusterIP" \
  render --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.publishDns=true \
    --set bitcoin-node.networking.p2p.scopes='{internal}'

check_guard "the pool API under ckpool is refused" \
  "pool.implementation is 'ckpool'" \
  render --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.publishDns=true \
    --set mining-pool.pool.implementation=ckpool \
    --set mining-pool.pool.ckpool.image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
    --set mining-pool.networking.api.scopes='{internal}'

check_guard "publishing ZMQ is refused" \
  "networking.zmq is not supported" \
  render --set bitcoin-node.networking.zmq.scopes='{internal}'

# ── The RPC guards. This is the endpoint that can lose someone their node. ─────
check_guard "publishing RPC with allowSubnet still 0.0.0.0/0 is refused" \
  "allowSubnet is still 0.0.0.0/0" \
  render --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.issuer=internal-ca \
    --set bitcoin-node.networking.rpc.scopes='{internal}'

check_guard "publishing RPC without TLS is refused" \
  "resolves no TLS" \
  render --set global.networking.baseDomain=example.com \
    --set bitcoin-node.rpc.allowSubnet=10.42.0.0/16 \
    --set bitcoin-node.networking.rpc.scopes='{internal}'

check_guard "publishing RPC without TLS is refused on every scope, not just one" \
  "resolves no TLS" \
  render --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.issuer=internal-ca \
    --set bitcoin-node.rpc.allowSubnet=10.42.0.0/16 \
    --set bitcoin-node.networking.rpc.scopes='{internal,external}'

hr
echo "🌐 Hostnames: what the rendered objects actually say"
hr

# Two scopes must produce two Ingresses that share nothing: not the object name,
# not the issuer, and above all not the TLS Secret — one Secret written by two
# issuers means they overwrite each other's certificate forever.
assert_two_scopes() {
  local out
  out="$(render "${NET_BASE[@]}" "${NET_INTERNAL[@]}" "${NET_EXTERNAL[@]}" \
    --set mining-pool.networking.api.scopes='{internal,external}')"

  [ "$(grep -c 'kind: Ingress' <<<"$out")" = "2" ] || { echo "expected exactly 2 Ingresses"; return 1; }
  grep -q 'name: mining-pool-api-internal' <<<"$out" || { echo "missing internal Ingress"; return 1; }
  grep -q 'name: mining-pool-api-external' <<<"$out" || { echo "missing external Ingress"; return 1; }
  grep -q 'cluster-issuer: "internal-ca"' <<<"$out" || { echo "internal issuer missing"; return 1; }
  grep -q 'cluster-issuer: "letsencrypt-prod"' <<<"$out" || { echo "external issuer missing"; return 1; }

  local secrets
  secrets="$(grep 'secretName:' <<<"$out" | grep -c 'tls')"
  [ "$secrets" = "2" ] || { echo "expected 2 distinct TLS secrets, got ${secrets}"; return 1; }
  [ "$(grep 'secretName:.*tls' <<<"$out" | sort -u | wc -l)" = "2" ] || { echo "the two scopes share a TLS Secret"; return 1; }
}

# A raw TCP Service gets ONE annotation carrying every hostname, and must never
# get the HTTP-proxy options a scope may define — they cannot apply to a stream
# an ingress controller never sees.
assert_tcp_record() {
  local out
  out="$(render "${NET_BASE[@]}" \
    --set global.networking.scopes.internal.publishDns=true \
    --set global.networking.scopes.external.publishDns=true \
    --set-string 'global.networking.scopes.external.annotations.external-dns\.alpha\.kubernetes\.io/cloudflare-proxied=false' \
    --set mining-pool.networking.stratum.scopes='{internal,external}')"

  grep -q 'hostname: "stratum.internal.example.com,stratum.example.com"' <<<"$out" \
    || { echo "both hostnames not on one annotation"; return 1; }
  grep -q 'kind: Ingress' <<<"$out" && { echo "stratum produced an Ingress"; return 1; }
  grep -q 'cloudflare-proxied' <<<"$out" && { echo "an HTTP proxy option reached a TCP Service"; return 1; }
  return 0
}

# The whole feature is opt-in. With nothing published there must be no Ingress
# and no external-dns annotation anywhere in the output.
assert_inert_by_default() {
  local out
  out="$(render)"
  grep -q 'kind: Ingress' <<<"$out" && { echo "an Ingress rendered by default"; return 1; }
  grep -q 'external-dns' <<<"$out" && { echo "an external-dns annotation rendered by default"; return 1; }
  grep -q 'cert-manager' <<<"$out" && { echo "a cert-manager annotation rendered by default"; return 1; }
  return 0
}

check "default: nothing published, no Ingress, no annotations" assert_inert_by_default
check "two scopes: two Ingresses, two issuers, two TLS secrets"  assert_two_scopes
check "raw TCP: one record annotation, no Ingress, no proxy flag" assert_tcp_record

hr
echo "📦 The subcharts still stand alone"
hr

# Both subcharts are installable on their own, so the scope map has to resolve
# from their own values too — not only when merged from the umbrella.
check "bitcoin-node standalone, P2P published" \
  helm template bn charts/bitcoin-node \
    --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.publishDns=true \
    --set p2p.service.type=LoadBalancer \
    --set networking.p2p.scopes='{internal}'

check "mining-pool standalone, API published" \
  helm template mp charts/mining-pool \
    --set bitcoin.rpc.host=some-node --set bitcoin.existingSecret.name=some-secret \
    --set global.networking.baseDomain=example.com \
    --set global.networking.scopes.internal.issuer=internal-ca \
    --set networking.api.scopes='{internal}'

hr
if [ "$failures" -ne 0 ]; then
  echo "❌ ${failures} failed"
  exit 1
fi
echo "✅ All render, hardening and guard checks passed"
