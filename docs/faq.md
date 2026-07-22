# FAQ

Practical answers for people deciding whether — and how — to run this. For the
"how a node dies" material, see [failure-modes.md](failure-modes.md).

## Do I need a full node? Can't I just point a miner at a public pool?

You can, and if you want steady income you probably should — that's *pooled*
mining against a third party. This project is for **solo** mining to **your own**
node: you validate the chain yourself, you build your own block templates, and if
you find a block the whole reward pays straight to your address with no operator
in between. The trade is sovereignty and the full-block lottery upside versus
long odds. If neither of those appeals to you, you don't need this.

## What are the odds of actually finding a block?

Long, with home-scale hardware. Solo mining is a lottery: a Bitaxe or a handful of
ASICs represents a tiny slice of the global hashrate, so *your* node winning a
block is rare and irregular. Treat it as a lottery ticket that also strengthens
the network — not as income. The upside is that when you do win, you win the
**entire** block reward, not a proportional share.

## How long does the initial sync (IBD) take?

It depends almost entirely on your **disk**, not your CPU or network. On fast,
node-local NVMe, a mainnet sync is on the order of a day. On replicated or
network-attached storage (Longhorn, Ceph, NFS, cloud block volumes) the same sync
can stretch into **weeks**, because initial block download is random-I/O bound and
every cache-missed read becomes a network round trip.

The single biggest hardware lever is giving the datadir fast, node-local disk. See
[failure mode #7](failure-modes.md) for the full explanation and the
`storageClass` + `nodeSelector` recipe.

## How much disk do I need?

| Node type | Disk | Can it serve history / rescan old wallets? |
|---|---|---|
| **Archival** (default) | ~900Gi (chain is ~650–700GB today, +~60GB/year) | Yes |
| **Pruned** | ~60Gi (set `node.config.prune`) | No |

Give an archival node real headroom — a volume that fills up at 3am can corrupt
the chainstate (see [failure mode #5](failure-modes.md)).

## Pruned vs archival — which should I pick?

Pruned keeps only recent blocks (~tens of GB) and is perfect if you just want to
validate and mine and disk is tight. The cost: a pruned node can't serve historic
blocks to peers or rescan old wallet history, and you can't cleanly switch a
pruned node back to archival without re-syncing. Archival keeps everything and is
the default. Solo mining works fine on either.

## How much memory does it need, and why does the install sometimes fail?

The chart enforces **`limits.memory` ≥ `dbcache` + 2Gi**. bitcoind's peak memory
sits well above `dbcache` (the block index, mempool and per-peer buffers stack on
top), and an OOM kill during a chainstate flush corrupts the datadir. So raising
`dbcache` without raising the memory limit in the same change is refused *at
install time* rather than allowed to destroy your node later. See
[failure mode #1](failure-modes.md).

## Can I run this on a single-node homelab / a Raspberry Pi?

A single-node cluster is fine — that's a common setup. Bitcoind is not
CPU-bound, so a modest machine works; the thing that matters is a **fast local
disk** and **enough RAM** for your chosen `dbcache`. A Raspberry Pi can run a
pruned node, but an SD card is the wrong disk — use an SSD/NVMe over USB3 at
minimum, or expect a painful sync.

## How do I point my miner at it?

Get the stratum service's external IP:

```bash
kubectl get svc mining-pool-stratum -n bitcoin
```

Then set your miner (Bitaxe, ASIC, `cgminer`, …) to:

- **URL:** `stratum+tcp://<that-IP>:3333`
- **Username / worker:** the **Bitcoin address you want a found block to pay**,
  optionally with a `.workername` suffix (e.g. `bc1q...abc.bitaxe1`)
- **Password:** anything (`x`) — solo pools ignore it

The payout address lives on the miner, not in this chart. If you find a block, the
coinbase pays that address — so double-check it's *yours*.

## Do I need a LoadBalancer? I don't have one

For real mining, yes — Stratum is raw TCP and needs its own address, not an HTTP
Ingress. On a homelab, [MetalLB](https://metallb.io/) provides one. For **regtest**
experimentation you can skip it: set `stratum.service.type: ClusterIP` and
`kubectl port-forward` to the service.

## Knots or Core? public-pool or ckpool?

Both node implementations are fully supported; pick with
`bitcoin-node.node.implementation`. Knots is the default. For the pool, public-pool
is the default and has a hardened, signed image; ckpool is supported but has **no
default image** on purpose — upstream ships source only and the Docker Hub images
are unaudited personal builds, so you must supply a digest-pinned image you trust
(the org publishes a hardened one). See
[failure mode #12](failure-modes.md).

## Is it safe to upgrade the node image?

Forward upgrades are the normal, safe path. Rolling an image **backwards** across a
major version is not safe — a newer chainstate format isn't readable by an older
bitcoind and forces a reindex. That's why Renovate never auto-merges a node image
bump; read the upstream diff first. See
[failure mode #10](failure-modes.md).

## What happens to my chain data if I `helm uninstall`?

It's kept on purpose. The PVC carries `helm.sh/resource-policy: keep` and the RPC
Secret is retained too, so an uninstall/re-install doesn't throw away weeks of sync
or silently break every consumer of the node. Deleting the data is a deliberate
manual step — see [Uninstall](../README.md#-uninstall) and
[failure mode #9](failure-modes.md).

## How do I verify the chart is really the one you published?

Every release is cosign-signed (keyless) and ships an SPDX SBOM attestation and
SLSA provenance. The [Verifying the chart](../README.md#-verifying-the-chart)
section has the exact `cosign verify` commands.
