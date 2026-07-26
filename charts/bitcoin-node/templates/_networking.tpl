{{/*
Networking: giving an endpoint a hostname, and a certificate if it can use one.

Two concepts, each defined in exactly one place:

  scopes     `global.networking.scopes` — HOW a name is published: which
             subdomain, which cert-manager issuer, whether external-dns
             publishes a record. Written once for the whole stack; both
             subcharts read the same map.

  endpoints  `networking.<endpoint>.scopes` — WHAT gets published, as a list of
             scope names. That list is the only per-endpoint switch. Empty
             (the default) means the endpoint is not published at all, which is
             why the whole feature is inert until someone opts in.

An endpoint published in two scopes is just a two-element list — there is no
separate "internal AND external" mode to configure, and no pair of near-identical
config blocks to keep in sync.

Whether an endpoint gets an Ingress or only a DNS record is NOT configurable: it
follows from the protocol. RPC is HTTP, so it can sit behind an Ingress and
terminate TLS. P2P is a raw TCP stream with no Host header and no SNI, so an
ingress controller has nothing to route on — it gets a name pointing at its
LoadBalancer address, and nothing else.

This file is deliberately duplicated in the mining-pool chart rather than being
factored into a library chart: both charts install standalone, and a library
dependency would add a fourth chart to the release, the Artifact Hub listing and
the version matrix for ~80 lines of template.
*/}}

{{/*
The scope map, from `global.networking.scopes`.
*/}}
{{- define "bitcoin-node.networking.scopes" -}}
{{- dig "networking" "scopes" dict (.Values.global | default dict) | toYaml -}}
{{- end -}}

{{- define "bitcoin-node.networking.baseDomain" -}}
{{- dig "networking" "baseDomain" "" (.Values.global | default dict) -}}
{{- end -}}

{{/*
Resolve one scope by name, applying the defaults for anything it left unset.

Takes a dict: `ctx` (the root context) and `scope` (the name). Returns the scope
as YAML — callers `fromYaml` it. Failing here rather than defaulting is
deliberate: a typo'd scope name would otherwise silently publish nothing, and
"my ingress did not appear" is a much worse afternoon than a render error.
*/}}
{{- define "bitcoin-node.networking.scope" -}}
{{- $ctx := .ctx -}}
{{- $name := .scope -}}
{{- $scopes := fromYaml (include "bitcoin-node.networking.scopes" $ctx) -}}
{{- if not (hasKey $scopes $name) -}}
{{- fail (printf "\n\nnetworking: unknown scope '%s'.\n\nAn endpoint asked to be published in a scope that is not defined. Scopes live in\nglobal.networking.scopes and are shared by every chart in the release; the ones\ndefined here are: %s.\n\nEither fix the name, or define it:\n\n  global:\n    networking:\n      baseDomain: example.com\n      scopes:\n        %s:\n          subdomain: %s\n          issuer: letsencrypt-prod\n          publishDns: true\n" $name (join ", " (keys $scopes | sortAlpha)) $name $name) -}}
{{- end -}}
{{/* A scope written as a bare `internal:` with nothing under it is legitimate —
     it means "all defaults" — so it must not blow up on a nil. */}}
{{- $s := index $scopes $name | default dict -}}
{{- $defaults := dict "subdomain" "" "issuer" "" "issuerKind" "ClusterIssuer" "publishDns" false "ttl" "300" "annotations" dict -}}
{{- merge (deepCopy $s) $defaults | toYaml -}}
{{- end -}}

{{/*
The fully qualified name an endpoint has in a scope.

  <endpoint name>.<scope subdomain>.<baseDomain>

with the subdomain dropped when it is empty, so an apex-relative scope gives
`rpc.example.com` rather than `rpc..example.com`. An explicit
`networking.<endpoint>.hosts.<scope>` overrides the derivation entirely, for the
cases where the name does not follow the pattern (a different domain, a vanity
name, a delegated zone).

Takes: `ctx`, `scope` (name), `endpoint` (the endpoint's values block).
*/}}
{{- define "bitcoin-node.networking.host" -}}
{{- $ctx := .ctx -}}
{{- $name := .scope -}}
{{- $ep := .endpoint -}}
{{- $override := dig "hosts" $name "" $ep -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- $scope := fromYaml (include "bitcoin-node.networking.scope" (dict "ctx" $ctx "scope" $name)) -}}
{{- $base := include "bitcoin-node.networking.baseDomain" $ctx -}}
{{- if not $base -}}
{{- fail (printf "\n\nnetworking: endpoint '%s' is published in scope '%s', but global.networking.baseDomain\nis empty and no explicit host was given.\n\nSet the domain the names are derived from:\n\n  global:\n    networking:\n      baseDomain: example.com\n\nor pin this one name yourself:\n\n  networking:\n    <endpoint>:\n      hosts:\n        %s: %s.example.com\n" (get $ep "name") $name $name (get $ep "name")) -}}
{{- end -}}
{{- $parts := list (get $ep "name") -}}
{{- if $scope.subdomain -}}
{{- $parts = append $parts $scope.subdomain -}}
{{- end -}}
{{- $parts = append $parts $base -}}
{{- join "." $parts -}}
{{- end -}}
{{- end -}}

{{/*
external-dns annotations for a raw-TCP Service (P2P).

One Service, so every scope's hostname goes into a single comma-separated
`hostname` annotation — external-dns accepts a list. Only scopes with
publishDns are included; a scope's own `annotations` map is deliberately NOT
merged here, because it is where provider options like cloudflare-proxied live
and those are HTTP-proxy settings that cannot apply to a raw TCP stream.

The TTL comes from the first publishing scope: there is one record set per
hostname, but only one annotation to carry a TTL.
*/}}
{{- define "bitcoin-node.networking.serviceAnnotations" -}}
{{- $ctx := .ctx -}}
{{- $ep := .endpoint -}}
{{- $hosts := list -}}
{{- $ttl := "" -}}
{{- range $name := (get $ep "scopes" | default list) -}}
{{- $scope := fromYaml (include "bitcoin-node.networking.scope" (dict "ctx" $ctx "scope" $name)) -}}
{{- if $scope.publishDns -}}
{{- $hosts = append $hosts (include "bitcoin-node.networking.host" (dict "ctx" $ctx "scope" $name "endpoint" $ep)) -}}
{{- if not $ttl -}}
{{- $ttl = $scope.ttl | toString -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $hosts -}}
external-dns.alpha.kubernetes.io/hostname: {{ join "," $hosts | quote }}
external-dns.alpha.kubernetes.io/ttl: {{ $ttl | quote }}
external-dns.alpha.kubernetes.io/action: sync
{{- end -}}
{{- end -}}

{{/*
The Secret an Ingress terminates TLS with, for one endpoint in one scope.

`tlsSecrets.<scope>` is the bring-your-own path. Otherwise the name is derived,
and per-scope, so two scopes issuing from two different issuers never write to
the same Secret — a collision that would have them overwrite each other's
certificate forever.

Empty means this endpoint terminates no TLS in this scope: the Ingress renders
without a `tls:` block. Fine for a stats page on a trusted LAN, and refused for
RPC by the guard below.
*/}}
{{- define "bitcoin-node.networking.tlsSecret" -}}
{{- $ctx := .ctx -}}
{{- $name := .scope -}}
{{- $ep := .endpoint -}}
{{- $existing := dig "tlsSecrets" $name "" $ep -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- $scope := fromYaml (include "bitcoin-node.networking.scope" (dict "ctx" $ctx "scope" $name)) -}}
{{- if $scope.issuer -}}
{{- printf "%s-%s-tls" .base $name -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Guards. Called from bitcoin-node.validate, so they run on every render.
*/}}
{{- define "bitcoin-node.networking.validate" -}}
{{- $net := .Values.networking | default dict -}}

{{/* ZMQ has no Service of its own — its ports ride on the ClusterIP RPC Service
     (see templates/services.yaml), so there is no address to publish and no
     object to annotate. Checked before anything else, so that asking for it
     gets this explanation rather than a downstream complaint about a missing
     hostname. */}}
{{- if dig "zmq" "scopes" list $net -}}
{{- fail "\n\nnetworking.zmq is not supported.\n\nZMQ has no Service of its own: its ports are served from the ClusterIP RPC\nService, so there is no external address to publish and nothing to annotate.\n\nZMQ is also unauthenticated and unencrypted — it is a publish socket bitcoind\nwrites block data to, with no credential of any kind. Reaching it from outside\nthe cluster would need a dedicated LoadBalancer Service, which this chart does\nnot create.\n\nIn-cluster subscribers (the mining pool) already reach it at the RPC Service and\nneed nothing from this block.\n" -}}
{{- end -}}

{{/* A typo'd endpoint key is silent otherwise: `networking.P2P` would sit there
     looking configured while publishing nothing at all. */}}
{{- $known := list "p2p" "rpc" -}}
{{- range $epName := (keys $net | sortAlpha) -}}
{{- if not (has $epName $known) -}}
{{- fail (printf "\n\nnetworking.%s is not an endpoint of this chart.\n\nPublishable endpoints are: %s.\n\n(ZMQ is deliberately absent — it shares the ClusterIP RPC Service and has no\naddress of its own. The pool's stats API lives in the mining-pool chart.)\n" $epName (join ", " $known)) -}}
{{- end -}}
{{- end -}}

{{/* Resolving every referenced scope proves each one exists and that a hostname
     can actually be derived for it, before any of it reaches a cluster. */}}
{{- range $epName := (keys $net | sortAlpha) -}}
{{- $ep := index $net $epName | default dict -}}
{{- range $scopeName := (get $ep "scopes" | default list) -}}
{{- $_ := include "bitcoin-node.networking.host" (dict "ctx" $ "scope" $scopeName "endpoint" $ep) -}}
{{- end -}}
{{- end -}}

{{/* P2P and ZMQ are raw TCP: a DNS record is the only thing on offer, so a scope
     that does not publish records leaves nothing behind. Silently rendering
     nothing is the failure mode this guard exists to prevent. */}}
{{- $p2p := get $net "p2p" | default dict -}}
{{- if get $p2p "scopes" -}}
{{- $publishing := false -}}
{{- range $scopeName := $p2p.scopes -}}
{{- $scope := fromYaml (include "bitcoin-node.networking.scope" (dict "ctx" $ "scope" $scopeName)) -}}
{{- if $scope.publishDns -}}{{- $publishing = true -}}{{- end -}}
{{- end -}}
{{- if not $publishing -}}
{{- fail (printf "\n\nnetworking.p2p.scopes lists %s, but no scope in that list has publishDns.\n\nP2P is a raw TCP stream: it cannot go behind an HTTP Ingress, so a DNS record is\nthe only thing publishing it can produce. With publishDns off in every listed\nscope this setting would render nothing at all.\n\nSet publishDns on the scope:\n\n  global:\n    networking:\n      scopes:\n        %s:\n          publishDns: true\n" (join ", " $p2p.scopes) (first $p2p.scopes)) -}}
{{- end -}}

{{/* Nothing to point a record at. external-dns needs an address on the Service,
     and a ClusterIP is not reachable from anywhere that would query this name. */}}
{{- if eq .Values.p2p.service.type "ClusterIP" -}}
{{- fail "\n\nnetworking.p2p.scopes is set, but p2p.service.type is ClusterIP.\n\nThere is no address to publish: a ClusterIP is only reachable inside the cluster,\nand external-dns has no external IP to write into the record.\n\nPublishing P2P only makes sense when you are accepting inbound peers. Set\np2p.service.type to LoadBalancer (or NodePort) first — and remember to forward\nthe port on your router.\n" -}}
{{- end -}}
{{- end -}}

{{/* ── RPC ──────────────────────────────────────────────────────────────────
     RPC is full control over the node: it can move coins if a wallet is loaded,
     and it can stop the process. It is the one endpoint here that is genuinely
     dangerous to publish, so it is guarded rather than merely documented. */}}
{{- $rpc := get $net "rpc" | default dict -}}
{{- if get $rpc "scopes" -}}

{{/* Publishing RPC invalidates the reasoning behind the rpc.allowSubnet default.
     That default is 0.0.0.0/0 *because* the Service is ClusterIP-only, so the
     subnet only ever spans the pod network. An Ingress breaks that premise: the
     ingress controller's pod IP is inside the pod network, so bitcoind would
     accept whatever the controller forwards, from anywhere. */}}
{{- if eq .Values.rpc.allowSubnet "0.0.0.0/0" -}}
{{- fail "\n\nnetworking.rpc.scopes is set while rpc.allowSubnet is still 0.0.0.0/0.\n\nThat default is only safe because the RPC Service is ClusterIP-only — the subnet\nnever spans more than the pod network. Publishing RPC through an Ingress breaks\nthat premise: the ingress controller forwards from its own pod IP, which is\ninside the allowed range, so bitcoind would accept whatever reaches the Ingress.\n\nNarrow it deliberately before publishing, to the ingress controller's pod CIDR:\n\n  rpc:\n    allowSubnet: 10.42.0.0/16   # your cluster's pod network\n\nRPC is full control over the node. If what you actually want is a read-only\nstats page, publish the pool's API instead — networking.api in the mining-pool\nchart — and leave this alone.\n" -}}
{{- end -}}

{{/* No plaintext RPC Ingress, ever. Not even on a LAN scope: this is a bearer
     credential over HTTP Basic auth, and it is the whole node. */}}
{{- range $scopeName := $rpc.scopes -}}
{{- $secret := include "bitcoin-node.networking.tlsSecret" (dict "ctx" $ "scope" $scopeName "endpoint" $rpc "base" (include "bitcoin-node.rpc.name" $)) -}}
{{- if not $secret -}}
{{- fail (printf "\n\nnetworking.rpc.scopes lists '%s', but that scope resolves no TLS.\n\nRPC authenticates with HTTP Basic — the password crosses the wire on every call.\nThere is no plaintext RPC Ingress in this chart, on any scope.\n\nGive the scope an issuer:\n\n  global:\n    networking:\n      scopes:\n        %s:\n          issuer: letsencrypt-prod\n\nor bring your own certificate:\n\n  networking:\n    rpc:\n      tlsSecrets:\n        %s: my-existing-tls-secret\n" $scopeName $scopeName $scopeName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
