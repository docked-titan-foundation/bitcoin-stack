{{/*
Names. Deliberately release-name-independent so the Service DNS a pool points at
is predictable and stable across reinstalls.
*/}}
{{- define "bitcoin-node.name" -}}
{{- default "bitcoin-node" .Values.nameOverride -}}
{{- end -}}

{{- define "bitcoin-node.rpc.name" -}}
{{ include "bitcoin-node.name" . }}-rpc
{{- end -}}

{{- define "bitcoin-node.p2p.name" -}}
{{ include "bitcoin-node.name" . }}-p2p
{{- end -}}

{{- define "bitcoin-node.configName" -}}
{{ include "bitcoin-node.name" . }}-config
{{- end -}}

{{- define "bitcoin-node.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ default (include "bitcoin-node.name" .) .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
The Secret holding the RPC credential.

All three providers converge on one contract — keys `rpc.conf`, `rpc-password`,
`rpc-username` — so nothing downstream has to care where the credential came
from.
*/}}
{{- define "bitcoin-node.secretName" -}}
{{- if eq .Values.secret.provider "existingSecret" -}}
{{- required "secret.existingSecret.name is required when secret.provider=existingSecret" .Values.secret.existingSecret.name -}}
{{- else -}}
{{- printf "%s-rpc-credentials" (include "bitcoin-node.name" .) -}}
{{- end -}}
{{- end -}}

{{- define "bitcoin-node.labels" -}}
app.kubernetes.io/part-of: {{ include "bitcoin-node.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
The in-cluster RPC endpoint, as a pool (or anything else) must address it.
*/}}
{{- define "bitcoin-node.rpcHost" -}}
{{ printf "%s.%s.svc.cluster.local" (include "bitcoin-node.rpc.name" .) .Release.Namespace }}
{{- end -}}

{{/*
The three settings a consumer of this node (a mining pool) has to agree with it
on. Under the umbrella chart they come from `global.bitcoinNode`, so there is one
place to set each and the two charts cannot drift apart. Standalone, they fall
back to this chart's own values.
*/}}
{{- define "bitcoin-node.rpcPort" -}}
{{- dig "bitcoinNode" "rpcPort" .Values.rpc.port (.Values.global | default dict) -}}
{{- end -}}

{{- define "bitcoin-node.rpcUsername" -}}
{{- dig "bitcoinNode" "rpcUsername" .Values.rpc.username (.Values.global | default dict) -}}
{{- end -}}

{{- define "bitcoin-node.zmqRawBlockPort" -}}
{{- dig "bitcoinNode" "zmqRawBlockPort" .Values.zmq.rawBlockPort (.Values.global | default dict) -}}
{{- end -}}

{{/*
Convert a Kubernetes quantity (8Gi, 6144Mi, 2G, 500M, raw bytes) to MiB.
Needed because the memory guard has to compare a quantity against a dbcache
value that bitcoind expresses in plain MiB.
*/}}
{{- define "bitcoin-node.toMiB" -}}
{{- $v := . | toString -}}
{{- if hasSuffix "Gi" $v -}}
{{- mulf (float64 (trimSuffix "Gi" $v)) 1024 | int64 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- float64 (trimSuffix "Mi" $v) | int64 -}}
{{- else if hasSuffix "Ki" $v -}}
{{- divf (float64 (trimSuffix "Ki" $v)) 1024 | int64 -}}
{{- else if hasSuffix "G" $v -}}
{{- divf (mulf (float64 (trimSuffix "G" $v)) 1000000000) 1048576 | int64 -}}
{{- else if hasSuffix "M" $v -}}
{{- divf (mulf (float64 (trimSuffix "M" $v)) 1000000) 1048576 | int64 -}}
{{- else -}}
{{- divf (float64 $v) 1048576 | int64 -}}
{{- end -}}
{{- end -}}

{{/*
The image reference: a preset selected by node.implementation, or your own build.

Pinned by digest. A tag is a mutable pointer — the same tag can be repointed at
different bytes tomorrow — and this is a process that holds the keys to money.

image.* is used as a UNIT, never merged field-by-field with a preset: a preset's
digest names the preset's repository, so mixing your repository with it would
produce a reference that resolves to the wrong bytes or to nothing at all.
*/}}
{{- define "bitcoin-node.image" -}}
{{- if .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- else -}}
{{- $preset := index .Values.images .Values.node.implementation -}}
{{- printf "%s:%s@%s" $preset.repository $preset.tag $preset.digest -}}
{{- end -}}
{{- end -}}

{{/*
The minimum termination grace period this dbcache needs.

bitcoind writes its dirty UTXO cache to disk on SIGTERM. If the grace period runs
out first, the kubelet sends SIGKILL mid-write and the chainstate is corrupted.
Flush time scales with dbcache; network-attached storage is slow; 8 MiB/s is a
pessimistic-but-real floor, with 300s of slack for shutdown itself.
*/}}
{{- define "bitcoin-node.minGracePeriod" -}}
{{- $dbcache := int64 (default 450 .Values.node.config.dbcache) -}}
{{- max 300 (add 300 (div $dbcache 8)) | int64 -}}
{{- end -}}

{{/*
Every guard, in one place. Included from the StatefulSet so it runs on every
render — `helm template`, `helm install`, and ArgoCD alike.

These are `fail` calls, not warnings, because each one of them is a way to
destroy a datadir that takes weeks to rebuild.
*/}}
{{- define "bitcoin-node.validate" -}}
{{- $impl := .Values.node.implementation -}}
{{- if not (has $impl (list "knots" "core" "custom")) -}}
{{- fail (printf "\n\nnode.implementation must be 'knots', 'core', or 'custom', got '%s'.\n" $impl) -}}
{{- end -}}

{{/* 'custom' brings your own bitcoind-compatible image: there is no preset to
     fall back on, so image.* is required. It also makes no dialect assumption —
     the Knots-only-option guard below does not run, and you own the config. */}}
{{- if and (eq $impl "custom") (not .Values.image.repository) -}}
{{- fail "\n\nnode.implementation is 'custom' but image.repository is empty.\n\n'custom' runs your own bitcoind-compatible image, so the chart needs one. Set\nimage.repository, image.tag and image.digest together (the digest is the pin — a\ntag, even a commit-based one, is a mutable pointer). To run a stock build instead,\nset node.implementation to 'knots' or 'core'.\n" -}}
{{- end -}}

{{- if not (has .Values.node.network (list "main" "test" "signet" "regtest")) -}}
{{- fail (printf "\n\nnode.network must be one of main|test|signet|regtest, got '%s'.\n" .Values.node.network) -}}
{{- end -}}

{{/* Knots-only options must not be handed to Core: bitcoind exits on an unknown
     option, so this would be a crash loop discovered at 3am rather than now. */}}
{{- if eq $impl "core" -}}
{{- $knotsOnly := list "consensusrules" "spkreuse" "corepolicy" -}}
{{- range $key, $val := .Values.node.config -}}
{{/* A null value means the option is explicitly unset — e.g. `--set
     node.config.consensusrules=null` to turn a Knots default off under Core. It
     is not in effect, so it must not trip the guard (and helm 3 keeps the null
     key in the map where helm 4 drops it, so the check has to be explicit). */}}
{{- if and (has $key $knotsOnly) (not (kindIs "invalid" $val)) -}}
{{- fail (printf "\n\nnode.config.%s is a Bitcoin Knots option, but node.implementation is 'core'.\nCore does not recognise it and bitcoind refuses to start on an unknown option.\nEither switch to node.implementation=knots or remove this option.\n" $key) -}}
{{- end -}}
{{- end -}}
{{- range $line := .Values.node.extraConfig -}}
{{- $key := splitList "=" $line | first | trim -}}
{{- if has $key $knotsOnly -}}
{{- fail (printf "\n\nnode.extraConfig contains '%s', a Bitcoin Knots option, but node.implementation is 'core'.\nCore refuses to start on an unknown option.\n" $line) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Supply chain: no unpinned images. The digest comes from image.* for a
     bring-your-own build, or from the selected preset otherwise — the same unit
     the image reference itself is built from, never a mix of the two. */}}
{{- if not .Values.safety.allowUnpinnedImage -}}
{{- $digest := "" -}}
{{- if .Values.image.repository -}}
{{- $digest = .Values.image.digest -}}
{{- else -}}
{{- $digest = (index .Values.images $impl).digest -}}
{{- end -}}
{{- if not $digest -}}
{{- fail (printf "\n\nThe %s image is not pinned by digest.\nA tag is a mutable pointer; this process holds the keys to money.\nSet image.digest (or images.%s.digest for a stock preset), or set\nsafety.allowUnpinnedImage=true to accept the risk deliberately.\n" $impl $impl) -}}
{{- end -}}
{{- end -}}

{{/* THE guard. An OOM kill mid-flush corrupts the chainstate — this is not a
     performance suggestion, it is the difference between a node and a reindex. */}}
{{- $limit := dig "limits" "memory" "" .Values.resources -}}
{{- if $limit -}}
{{- $limitMiB := int64 (include "bitcoin-node.toMiB" $limit) -}}
{{- $headroomMiB := int64 (include "bitcoin-node.toMiB" .Values.safety.memoryHeadroom) -}}
{{- $dbcache := int64 (default 450 .Values.node.config.dbcache) -}}
{{- $required := add $dbcache $headroomMiB -}}
{{- if lt $limitMiB $required -}}
{{- fail (printf "\n\nresources.limits.memory (%s = %d MiB) is too small for node.config.dbcache (%d MiB).\n\nbitcoind's peak memory runs well above dbcache — block index, mempool and peer\nbuffers all sit on top of it. If the kernel OOM-kills bitcoind it never flushes\nits dirty UTXO cache, and the chainstate is corrupted: that costs you a reindex\n(days) or a resync (weeks).\n\nRequired: dbcache (%d MiB) + safety.memoryHeadroom (%d MiB) = %d MiB.\n\nEither raise resources.limits.memory to at least %d MiB, or lower\nnode.config.dbcache to at most %d MiB.\n" $limit $limitMiB $dbcache $dbcache $headroomMiB $required $required (sub $limitMiB $headroomMiB)) -}}
{{- end -}}
{{- end -}}

{{/* A grace period that cannot outlast the flush is just a slower SIGKILL. */}}
{{- if .Values.safety.enforceGracePeriod -}}
{{- $minGrace := int64 (include "bitcoin-node.minGracePeriod" .) -}}
{{- if lt (int64 .Values.terminationGracePeriodSeconds) $minGrace -}}
{{- fail (printf "\n\nterminationGracePeriodSeconds (%d) is below the minimum for a dbcache of %d MiB (%d seconds).\n\nOn SIGTERM bitcoind flushes its dirty UTXO cache to disk. If the grace period\nexpires first, the kubelet sends SIGKILL mid-write and the chainstate is\ncorrupted. The bigger the cache, the longer the flush.\n\nRaise terminationGracePeriodSeconds to at least %d, or set\nsafety.enforceGracePeriod=false to accept the risk deliberately.\n" (int64 .Values.terminationGracePeriodSeconds) (int64 (default 450 .Values.node.config.dbcache)) $minGrace $minGrace) -}}
{{- end -}}
{{- end -}}

{{/* A pruned node on a huge volume, or an archival node on a tiny one, are both
     silent money-wasters — and the second one corrupts the chainstate when the
     disk fills mid-write. Warn loudly; do not block. */}}
{{- end -}}
