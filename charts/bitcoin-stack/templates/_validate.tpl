{{/*
Cross-chart guards.

Neither subchart can catch these on its own: the node does not know a pool exists,
and the pool does not know which chain the node is actually on. The umbrella is
the only place that sees both.
*/}}
{{- define "bitcoin-stack.validate" -}}
{{- $node := index .Values "bitcoin-node" -}}
{{- $pool := index .Values "mining-pool" -}}

{{/*
Disabling both leaves nothing to install. Helm renders it happily — an empty
release that reports success — so a fat-fingered values file would fail silently.
Refuse it loudly instead.
*/}}
{{- if and (not $node.enabled) (not $pool.enabled) -}}
{{- fail "\n\nBoth bitcoin-node.enabled and mining-pool.enabled are false: there is nothing to install.\n\nEnable at least one:\n  - bitcoin-node.enabled=true   a Bitcoin node (useful on its own)\n  - mining-pool.enabled=true    a mining pool (needs a node to mine on)\n" -}}
{{- end -}}

{{- if and $pool.enabled (not $node.enabled) -}}
{{- $host := dig "bitcoin" "rpc" "host" "" $pool -}}
{{- if not $host -}}
{{- fail "\n\nThe pool is enabled but the node is not, and no external node was given.\n\nA mining pool is useless on its own: it needs a bitcoind to pull block templates\nfrom. Either enable the node (bitcoin-node.enabled=true), or point the pool at an\nexisting one:\n\n  mining-pool:\n    bitcoin:\n      rpc:\n        host: <your node's RPC service>\n      existingSecret:\n        name: <secret holding its rpc-password>\n" -}}
{{- end -}}
{{- end -}}

{{/*
A pool decoding mainnet addresses while mining on a test chain (or the reverse)
is not a small mistake. The pool builds the coinbase from the address the miner
authenticates with — mismatched network parameters mean it is parsing that
address against the wrong rules.
*/}}
{{- if and $pool.enabled $node.enabled -}}
{{- $nodeNet := dig "node" "network" "main" $node -}}
{{- $poolNet := dig "pool" "network" "mainnet" $pool -}}
{{- $expected := ternary "mainnet" "testnet" (eq $nodeNet "main") -}}
{{- if ne $poolNet $expected -}}
{{- fail (printf "\n\nThe node is on '%s' but the pool is configured for '%s'.\n\nThe pool decodes the miner's payout address using its network's parameters. Mining\non %s with %s parameters means it is reading that address against the wrong rules.\n\nSet mining-pool.pool.network to '%s' (regtest and signet share testnet's address\nparameters), or change bitcoin-node.node.network.\n" $nodeNet $poolNet $nodeNet $poolNet $expected) -}}
{{- end -}}
{{- end -}}
{{- end -}}
