#!/usr/bin/env bash
# End-to-end test: install the stack on a regtest node in a real cluster and prove
# the two halves actually work together.
#
# Not a smoke test. It asserts the things that would silently be wrong in a chart
# that "renders fine": that bitcoind comes up on the right chain, that the pool
# authenticates against its RPC with the generated password, that the stratum port
# accepts a miner, and that neither process is running as root.
#
# Expects a working cluster in the current kubectl context, and the charts already
# installed as the release named in RELEASE.
set -euo pipefail

RELEASE="${RELEASE:-bs}"
NAMESPACE="${NAMESPACE:-bitcoin-stack-test}"
DEBUG="${DEBUG:-0}"
failures=0

hr() { printf '━%.0s' {1..78}; echo; }

check() {
  local name="$1"; shift
  if "$@" >/tmp/bs-e2e.log 2>&1; then
    echo "✅ PASS  ${name}"
  else
    echo "❌ FAIL  ${name}"
    [ "$DEBUG" = "1" ] && sed 's/^/         /' /tmp/bs-e2e.log
    failures=$((failures + 1))
  fi
}

# Assert a command's OUTPUT contains something, not merely that it succeeded.
check_output() {
  local name="$1" expect="$2"; shift 2
  local out
  if ! out="$("$@" 2>&1)"; then
    echo "❌ FAIL  ${name} — command failed"
    [ "$DEBUG" = "1" ] && awk '{ print "         " $0 }' <<<"$out"
    failures=$((failures + 1))
    return
  fi
  if grep -qi -- "${expect}" <<<"$out"; then
    echo "✅ PASS  ${name}"
  else
    echo "❌ FAIL  ${name} — expected '${expect}' in output"
    [ "$DEBUG" = "1" ] && awk '{ print "         " $0 }' <<<"$out"
    failures=$((failures + 1))
  fi
}

k() { kubectl -n "$NAMESPACE" "$@"; }

# The StatefulSet is named by the chart, not by the release — deliberately, so the
# Service DNS a pool dials is stable across reinstalls.
NODE_POD="bitcoin-node-0"

hr
echo "⏳ Waiting for the stack to come up"
hr
check "bitcoin node becomes ready"  k wait --for=condition=ready pod/"$NODE_POD" --timeout=300s
check "mining pool becomes ready"   k wait --for=condition=available deploy/mining-pool --timeout=300s

hr
echo "🔗 The node"
hr
RPC_PASSWORD="$(k get secret bitcoin-node-rpc-credentials -o jsonpath='{.data.rpc-password}' | base64 -d)"

bcli() {
  k exec "$NODE_POD" -c bitcoind -- \
    bitcoin-cli -datadir=/home/bitcoin/.bitcoin \
    -rpcuser=bitcoin -rpcpassword="$RPC_PASSWORD" "$@"
}

check_output "bitcoind answers RPC on the generated credential" "regtest" \
  bcli getblockchaininfo

check_output "the node is on the chain the values asked for" '"chain": "regtest"' \
  bcli getblockchaininfo

check_output "bitcoind runs as a non-root user" "^101$" \
  k exec "$NODE_POD" -c bitcoind -- id -u

# The whole point of config-as-data: an option set in values.yaml must actually
# arrive in bitcoin.conf AND be parsed by bitcoind. Assert both links, not one:
# the ConfigMap could mount correctly and still be ignored.
check_output "values.yaml reached the mounted bitcoin.conf" "maxconnections=8" \
  k exec "$NODE_POD" -c bitcoind -- cat /home/bitcoin/.bitcoin/bitcoin.conf

check_output "bitcoind actually parsed that option" 'Config file arg: maxconnections="8"' \
  k logs "$NODE_POD" -c bitcoind

hr
echo "⛏️  The pool"
hr
POOL_POD="$(k get pod -l app.kubernetes.io/name=mining-pool -o jsonpath='{.items[0].metadata.name}')"

check_output "the pool runs as a non-root user" "^1000$" \
  k exec "$POOL_POD" -- id -u

# This is the assertion that matters. The pool can only serve this if it
# authenticated to bitcoind with the password the chart generated, over the Service
# the chart created, with the env the chart derived. Any broken link fails here.
check "the pool's API is up (it authenticated to the node)" \
  k exec "$POOL_POD" -- node -e '
    const http = require("http");
    http.get("http://127.0.0.1:3334/api/info", (r) => {
      if (r.statusCode !== 200) { console.error("api status " + r.statusCode); process.exit(1); }
      process.exit(0);
    }).on("error", (e) => { console.error(e.message); process.exit(1); });
  '

# Inverted check: these strings must NOT appear. `k` is a function, so this cannot
# go through `bash -c` — it would silently pass on "command not found".
if k logs "$POOL_POD" --tail=200 | grep -qiE 'ECONNREFUSED|401|unauthorized'; then
  echo "❌ FAIL  the pool reported an RPC failure against the node"
  failures=$((failures + 1))
else
  echo "✅ PASS  the pool reported no RPC failure"
fi

# bitcoind logs a rejected password attempt. If the chart wired the wrong
# credential across, it says so here.
if k logs "$NODE_POD" -c bitcoind | grep -qi "incorrect password attempt"; then
  echo "❌ FAIL  bitcoind rejected the pool's credentials"
  failures=$((failures + 1))
else
  echo "✅ PASS  bitcoind never rejected the pool's credentials"
fi

# A miner is just a TCP client. If this connects, a Bitaxe can connect.
check "the stratum port accepts a miner" \
  k exec "$POOL_POD" -- node -e '
    const net = require("net");
    const s = net.connect(3333, "127.0.0.1", () => { s.end(); process.exit(0); });
    s.on("error", () => process.exit(1));
    setTimeout(() => process.exit(1), 5000);
  '

# The end-to-end proof, and the reason ZMQ is wired at all: mine a block on the
# node and the pool must hear about it. Without this the pool would only learn of
# new blocks by polling, and miners would grind stale work for seconds after every
# block — time spent mining a block that can no longer be won.
hr
echo "📡 ZMQ: does a new block actually reach the pool?"
hr
ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
bcli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || true
sleep 5

if k logs "$POOL_POD" --tail=30 | grep -qiE "new block|block found|height|template"; then
  echo "✅ PASS  the pool saw the new block and rebuilt its template"
else
  echo "❌ FAIL  the pool never noticed a block the node mined"
  [ "$DEBUG" = "1" ] && k logs "$POOL_POD" --tail=15
  failures=$((failures + 1))
fi

hr
if [ "$failures" -ne 0 ]; then
  echo "❌ ${failures} failed"
  [ "$DEBUG" = "1" ] && k logs "$POOL_POD" --tail=40
  exit 1
fi
echo "✅ The node and the pool are talking to each other"
