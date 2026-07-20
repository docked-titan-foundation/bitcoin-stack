<p align="center">
  <img src="docs/images/bitcoin-stack-banner.svg" alt="Bitcoin Stack — your node, your rules, by Alberto Iglesias" />
</p>

[![CI_CD](https://github.com/docked-titan-foundation/bitcoin-stack/actions/workflows/pipeline.yml/badge.svg)](https://github.com/docked-titan-foundation/bitcoin-stack/actions/workflows/pipeline.yml)
![Release](https://img.shields.io/github/v/release/docked-titan-foundation/bitcoin-stack)
[![Renovate](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://renovatebot.com)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
![Stars](https://img.shields.io/github/stars/docked-titan-foundation/bitcoin-stack?style=social)

## 📝 Description

A hardened Helm chart for a **Bitcoin node** and a **mining pool that mines on it**.

```text
  miner ──stratum:3333──> mining-pool ──RPC + ZMQ──> bitcoin-node ──P2P──> the network
```

Pick your implementations with a value. Nothing else changes:

| | Options |
|---|---|
| 1.0.0-beta.4 (latest) | 29.3.knots20260508 | 31.1 | public-pool | 2026-07-19 |
| 1.0.0-beta.3 | 29.3.knots20260508 | 31.1 | public-pool | 2026-07-19 |
| 1.0.0-beta.2 | 29.3.knots20260508 | 31.1 | public-pool | 2026-07-19 |
| 1.0.0-beta.1 | 29.3.knots20260508 | 31.1 | public-pool | 2026-07-19 |
| Node | **Bitcoin Knots** or **Bitcoin Core** |
| Pool | **public-pool** or **ckpool** |

Miners speak Stratum. bitcoind does not — it only offers `getblocktemplate` over
JSON-RPC. The pool is the bridge, and in solo mining it is also the thing that
builds the coinbase output that pays out a block if you find one. That is why
this chart is careful about which images it will run, and refuses to run one it
cannot identify by digest.

## ✨ What this chart does differently

Most Bitcoin charts render fine and then destroy your datadir six weeks later.
This one refuses to install configurations that will do that.

| | Typical chart | This chart |
|---|---|---|
| `bitcoin.conf` | hardcoded template lines; unsupported options need a chart edit | **rendered from data** — any bitcoind option works from `values.yaml` |
| dbcache vs memory limit | your problem | **the install fails** if `dbcache + 2Gi > limits.memory`, because an OOM kill mid-flush corrupts the chainstate |
| Shutdown | default 30s grace | grace period is **validated against dbcache** — a flush that gets SIGKILLed is a reindex |
| Reindex | the startup probe kills it every 10 minutes, forever | `recovery.enabled` drops the probes so recovery can finish |
| Images | `:latest`, or a tag | **digest-pinned**, and it will not render otherwise |
| ckpool | pulls a random Docker Hub image | defaults to the org's **hardened, signed** ckpool build, and refuses an unpinned one |
| RPC credential | in `values.yaml` | generated, or from a Secret, or from Vault/OpenBao — never authored by you |
| Node ↔ pool wiring | typed twice, drifts | **derived once**; change the RPC port in one place and both halves follow |

Every one of those guards is a real way a node dies. They are documented, with
the incident that motivated each, in [docs/failure-modes.md](docs/failure-modes.md).

## 🚀 Usage

```bash
helm install btc oci://ghcr.io/docked-titan-foundation/bitcoin-stack \
  --namespace bitcoin --create-namespace \
  -f my-values.yaml
```

An ordinary Helm chart: `values.yaml` is the only interface.

```yaml
# my-values.yaml — a mainnet archival node with a solo pool
bitcoin-node:
  node:
    implementation: knots      # or: core
    config:
      dbcache: 4096            # MiB. The biggest lever on sync speed.
  storage:
    size: 900Gi                # mainnet is ~650-700GB today, growing ~60GB/year
  resources:
    limits:
      memory: 8Gi              # must be >= dbcache + 2Gi, or the install fails

mining-pool:
  pool:
    implementation: public-pool
  stratum:
    service:
      type: LoadBalancer       # stratum is raw TCP; it needs its own address
```

Then point a miner at the stratum service, using **the Bitcoin address you want a
found block to pay** as the username. That is set on the miner, not here.

### Common variations

A **pruned** node (~20GB instead of ~700GB — cannot serve historic blocks or
rescan old wallets):

```yaml
bitcoin-node:
  node:
    config:
      prune: 20000             # MiB of blocks to keep
  storage:
    size: 60Gi
```

**Signet** (a real test network, with real sync, and no real money):

```yaml
bitcoin-node:
  node:
    network: signet
mining-pool:
  pool:
    network: testnet           # signet shares testnet's address parameters
```

**Just the node**, no pool:

```yaml
mining-pool:
  enabled: false
```

Any bitcoind option at all, without touching the chart:

```yaml
bitcoin-node:
  node:
    config:
      maxmempool: 500
      blockfilterindex: 1
    configList:                # options bitcoind accepts more than once
      onlynet: [onion]
      addnode: [seed.example.com]
```

**Bring your own node image** — any bitcoind-compatible build, pinned by digest.
`custom` skips the Knots/Core dialect guard, so you own the config entirely:

```yaml
bitcoin-node:
  node:
    implementation: custom     # no preset, no dialect guard
  image:
    repository: ghcr.io/you/bitcoin   # registry URL + repo path
    tag: git-3f1a9c2                  # a version or commit reference
    digest: "sha256:…"               # the pin (required unless you opt out)
```

**Fast, node-local storage** — the biggest hardware lever on sync speed. Initial
block download is random-I/O bound; a replicated/network volume (Longhorn, Ceph,
NFS, cloud block) can stretch a ~1-day sync into weeks. The chain is fully
re-syncable with no wallet, so local disk is the right trade:

```yaml
bitcoin-node:
  storage:
    storageClass: local-path   # node-local NVMe, not a replicated volume
  nodeSelector:
    kubernetes.io/hostname: your-fast-node   # schedule where that disk lives
```

See [docs/failure-modes.md](docs/failure-modes.md) #7 for the data-locality trap
this avoids.

## 🔐 Verifying the chart

Every release is signed with cosign (keyless) and carries an SPDX SBOM
attestation and SLSA provenance. Nothing is published unsigned — if a signature
or an attestation is ever missing, the weekly rebuild notices and republishes.

```bash
cosign verify ghcr.io/docked-titan-foundation/bitcoin-stack:<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "https://github.com/docked-titan-foundation/bitcoin-stack"

cosign verify-attestation --type spdxjson \
  ghcr.io/docked-titan-foundation/bitcoin-stack:<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "https://github.com/docked-titan-foundation/bitcoin-stack"
```

## 📋 Version Matrix

### Stable Releases

| Chart | Knots | Core | Pool | Date |
|---|---|---|---|---|

## 🛠️ Development

```bash
mise install
mise run lint       # ct lint + yamllint + shellcheck
mise run template   # render the whole matrix through kubeconform, assert the guards fire
mise run test       # kind + a real regtest node and pool, end to end
```

`mise run test` is the one that matters. It installs the stack on a **regtest**
node — which is ready in seconds instead of days — and then asserts that bitcoind
answers RPC on the generated credential, that the pool authenticated to it and
pulled a block template, that a new block reaches the pool over ZMQ, and that the
stratum port accepts a miner. A chart that renders is not a chart that works.

## ⚠️ Before you run this for real

Read [docs/failure-modes.md](docs/failure-modes.md). The two that will cost you
the most:

1. **Never `kubectl delete pod --force` the node.** SIGKILL during a chainstate
   flush corrupts the datadir, and the repair is a multi-day reindex.
2. **Never change `storage.size` or `storage.storageClass` by editing values.**
   They live in the StatefulSet's `volumeClaimTemplates`, which Kubernetes forbids
   updating — the API server rejects the whole StatefulSet, keeps rejecting it, and
   every later change to the release silently stops landing while your GitOps tool
   still reports `Healthy`. The doc has the safe procedure.

## 📄 License

GPL-3.0
