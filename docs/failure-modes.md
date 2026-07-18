# How a Bitcoin node dies, and what this chart does about it

The blockchain is public data, so nothing here is *irreplaceable*. But a broken
node means a `-reindex` (days) or a resync from zero (weeks), and for that whole
time anything depending on it — your mining pool, above all — is dead.

**The node's one fatal weakness: bitcoind must be allowed to shut down cleanly.**
It holds a large dirty UTXO cache in RAM (`dbcache`) and only writes it to disk on
a graceful stop. A `SIGKILL` mid-flush produces `Corrupted block database` and
forces a reindex. Most of what follows is a different route to that same SIGKILL.

Every failure below is real. Several are written down here because they already
happened to somebody.

Legend: **[chart guards this]** — the chart refuses to install the configuration,
or makes the failure impossible. **[you must guard this]** — outside what a chart
can control; know it anyway.

---

## 1. OOM kill — **[chart guards this]**

An OOM kill is a SIGKILL. There is no flush, and the chainstate is corrupted.

bitcoind's peak memory sits well *above* `dbcache`: the block index, the mempool
and per-peer buffers all stack on top of it. So the invariant is:

> `resources.limits.memory` ≥ `node.config.dbcache` + `safety.memoryHeadroom` (2Gi)

The chart **fails the render** if you violate it. Raising `dbcache` without raising
the memory limit in the same change is the single easiest way to destroy a node,
and it is exactly the kind of change that looks harmless in a diff.

Note that `kubectl top` will always show the pod sitting near its limit — most of
that is reclaimable page cache, not anonymous memory, and it is fine. The number
that actually matters is `oom_kill` in `/sys/fs/cgroup/memory.events`. It should
be 0.

## 2. A grace period shorter than the flush — **[chart guards this]**

If the grace period expires mid-flush, the kubelet sends SIGKILL. Flush time
scales with `dbcache`, and network-attached storage is slow. The chart computes a
minimum from your dbcache and refuses a `terminationGracePeriodSeconds` below it
(`safety.enforceGracePeriod`).

## 3. `kubectl delete pod --force` — **[you must guard this]**

`--force` / `--grace-period=0` **is** a SIGKILL, by definition. It is the classic
way an operator in a hurry destroys their own node.

There is never a good reason to force-delete bitcoind. A plain `kubectl delete
pod` and up to 15 minutes of patience is the correct move. Any restart, rollout or
node drain is **safe** as long as it goes through the normal SIGTERM path — confirm
it did by finding `Shutdown: done` in the logs before the new pod starts.

## 4. The startup probe killing a reindex — **[chart guards this]**

The startup probe allows bitcoind ~10 minutes to open its P2P port. A normal start
is comfortably inside that. **A `-reindex` takes days.**

So if the node ever does need to reindex, the probe kills it every 10 minutes,
forever. It can never finish recovering, and every kill deepens the damage. The
failure mode is a node that is trying to heal being murdered for it, on a loop.

Before any recovery run:

```yaml
bitcoin-node:
  recovery:
    enabled: true    # drops the startup and liveness probes
```

Let it finish, then turn it back off. (While it is on, a genuinely hung bitcoind
will not be restarted for you — that is the trade.)

## 5. The volume filling up — **[you must guard this]**

A mainnet archival node needs ~650–700GB today and grows ~60GB/year. When the
volume hits ENOSPC, bitcoind's own disk-space check normally aborts it cleanly —
but a hard ENOSPC in the middle of a LevelDB write can corrupt the chainstate
outright. This one happens unattended, at 3am.

Give it real headroom (`storage.size`), and watch it. If disk is tight, run a
pruned node instead (`node.config.prune`), which caps the block store at a few
tens of GB — at the cost of not being able to serve historic blocks to peers or
rescan old wallet history.

## 6. Changing `storage.*` and freezing every future sync — **[Kubernetes forbids; chart warns]**

The most insidious entry here, because it is **silent**, and your GitOps tool will
keep reporting the app as `Healthy` throughout.

`storage.size` and `storage.storageClass` live inside the StatefulSet's
`volumeClaimTemplates`, which Kubernetes **forbids updating** on an existing
StatefulSet. Edit one and apply, and the API server rejects the **entire
StatefulSet** — and keeps rejecting it. Every later change to that release then
silently fails to land as well. A real instance of this hid a Bitcoin version
upgrade for weeks: git said the node was on a new version, the dashboard said
`Healthy`, and the node was quietly still running the old one.

Detect it — health is not enough, you have to read the *operation*:

```bash
kubectl describe statefulset bitcoin-node -n <ns> | grep -iA3 forbidden
```

Grow the volume like this instead. The node never stops:

```bash
# 1. expand the live PVC (most CSI drivers do this online, no restart)
kubectl patch pvc data-bitcoin-node-0 -n <ns> \
  -p '{"spec":{"resources":{"requests":{"storage":"1200Gi"}}}}'

# 2. update storage.size in your values so git and the cluster agree

# 3. recreate the StatefulSet WITHOUT touching the pod or the PVC
kubectl delete statefulset bitcoin-node -n <ns> --cascade=orphan
helm upgrade ...
```

`--cascade=orphan` leaves the running pod and the PVC alone; the new StatefulSet
adopts them. The chart prints this procedure in `NOTES.txt` on every install, so
it is in front of you *before* you need it.

## 7. Slow or remote storage — the sync that never finishes — **[you must guard this]**

Nothing is corrupted here. The node just never catches up — and for that whole
time the pool has no chain to build on, which is the same outcome as a dead node,
only quieter, and with no error anywhere to point at.

Initial block download is **random-I/O bound**: hundreds of gigabytes of small,
scattered reads and writes against the UTXO database. The disk underneath it is
the single biggest *hardware* lever on how long that takes, and the default choice
is usually the wrong one.

**Replicated or network-attached storage — Longhorn, Ceph, NFS, cloud block
volumes — can turn a roughly one-day sync into weeks.** Every cache-missed read
becomes a network round trip, and the per-operation latency that is invisible
under a web app is ruinous under IBD.

Two traps make it worse:

- **The data-locality trap.** Distributed storage can place the volume's replica
  on a *different node* than the pod. Then *every* read that misses page cache
  crosses the network — a node whose data lives one hop away syncs an order of
  magnitude slower than the same node reading its local disk, with nothing in any
  dashboard to explain the difference. (Longhorn's `dataLocality: disabled` does
  exactly this.)
- **Page-cache thrash.** The kernel hides a slow disk behind page cache — right up
  until memory is too tight to hold it. Then it evicts the cache it needed back
  moments later and every eviction becomes another slow read (see #1). A too-low
  `limits.memory` and slow storage compound into something far worse than either
  alone.

**The fix is to give the datadir fast, node-local disk.** A Bitcoin node is a
single, fully re-syncable dataset with no irreplaceable data (no wallet) — the
durability a replicated volume sells you is durability you do not need, paid for
in sync speed you do. Prefer local NVMe: a `local-path` provisioner, or a `local`
PersistentVolume.

```yaml
bitcoin-node:
  storage:
    storageClass: local-path   # node-local disk, not a replicated volume
  # Pin the pod to the node that holds that disk, so it schedules where its data
  # is rather than wherever the scheduler feels like.
  nodeSelector:
    kubernetes.io/hostname: your-fast-node
```

If you are stuck with distributed storage, at least keep the data node-local
(co-locate the pod with a replica — e.g. Longhorn `dataLocality: best-effort`
plus a matching `nodeSelector`) and give memory real headroom so page cache
survives.

The trade-off of node-local storage is honest: the datadir is bound to that one
node and is not replicated or snapshotted, so recovery is a resync. For public
chain data with no wallet, that is the right trade.

To tell which of these is actually biting — read the numbers, not the dashboard:

```bash
# Is the disk the bottleneck? high %util + high await = yes. (Run on the node,
# or a debug pod with the host mounted; the minimal image has no iostat.)
iostat -x 2 3
# Rule CPU out — bitcoind is not CPU-bound. nr_throttled should stay ~0.
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.stat
# Is memory pressure evicting page cache? the max/high counters climb under it.
kubectl exec <pod> -- cat /sys/fs/cgroup/memory.events
# Locality: is the pod even on the same node as its volume's replica?
kubectl get pod <pod> -o jsonpath='{.spec.nodeName}'   # vs where the PV lives
```

## 8. Two bitcoinds on one datadir — **[chart guards this]**

Fatal to a datadir. Prevented three ways: `replicas: 1` is not configurable,
`podManagementPolicy: OrderedReady`, and a `ReadWriteOnce` volume. bitcoind's own
`.lock` file is the last line of defence. Do not hand-run a second pod against the
same PVC "just to check something".

## 9. Deleting the release and taking the chain with it — **[chart guards this]**

The PVC carries `helm.sh/resource-policy: keep` (`storage.keepOnDelete`), so
`helm uninstall` will not delete hundreds of gigabytes that take weeks to
re-download. Deleting the chain should be a deliberate, manual act.

The RPC Secret is kept for the same reason: silently rotating or losing it breaks
every consumer of the node, with an error that looks nothing like the cause.

## 10. Config changes that silently trigger a reindex — **[you must guard this]**

Some `bitcoin.conf` changes make bitcoind reprocess the whole chain on next start
— and because any values change rolls the pod, you find out afterwards:

- enabling `txindex` or `blockfilterindex` (rebuilds the index over the whole chain)
- changing `prune` from 0 to non-zero, or trying to go back
- changing `network`
- rolling the image **backwards** across a major version — a newer chainstate
  format is not readable by an older bitcoind, and it will refuse to start or
  demand a reindex

Forward upgrades are safe and are the normal path. This is why Renovate is
configured never to auto-merge a node image bump.

## 11. A Knots-only option under Core — **[chart guards this]**

bitcoind **exits on an unknown config option**. Switch `node.implementation` to
`core` while a Knots-only option like `consensusrules` is still set, and you get a
crash loop — on a node that was healthy an hour ago. The chart refuses to render
that combination and names the offending option.

## 12. Running an image nobody can identify — **[chart guards this]**

The pool builds the coinbase output that pays out a found block. It decides who
gets paid. An image you did not audit can quietly change that address.

- Every image is pinned **by digest**, never by tag alone. A tag is a mutable
  pointer; a digest is the artifact. The chart will not render an unpinned image
  unless you set `safety.allowUnpinnedImage: true` deliberately.
- **ckpool defaults to docked-titan-foundation's own hardened image**, built the
  same way as public-pool: from a pinned upstream commit, non-root, cosign-signed,
  SBOM-attested. This exists because ckpool's upstream publishes source only and
  every ckpool image on Docker Hub is an unaudited personal build by an anonymous
  account — and this is the process that decides who a found block pays. If you
  replace the default, the digest guard still applies: no unpinned image runs.

## 13. Hard power loss — **[you must guard this]**

A power cut gives bitcoind no chance to flush. A UPS is the only real mitigation.
A *planned* reboot is fine provided it goes through `kubectl drain`, which respects
the grace period. A hard reset is not.

---

## If it does break

The symptom is `Corrupted block database` or `Error opening block database`,
usually followed by a crash loop.

1. **Turn on recovery mode first** (`recovery.enabled: true`) — otherwise the
   startup probe kills the repair every 10 minutes and it can never complete.
2. Try `-reindex-chainstate` before `-reindex`. It rebuilds the UTXO set from the
   blocks already on disk (hours) instead of re-verifying every block from genesis
   (days). It only works if the block files themselves are intact.
3. Only if the block files are damaged do you need a full `-reindex`.
4. Turn recovery mode back off afterwards.
