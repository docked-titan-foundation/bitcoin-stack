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
follows from the protocol. The stats API is HTTP, so it can sit behind an Ingress
and terminate TLS. Stratum is a raw TCP stream with no Host header and no SNI, so
an ingress controller has nothing to route on — it gets a name pointing at its
LoadBalancer address, and nothing else. (Encrypted stratum exists, but it needs a
TLS-terminating proxy in front of the pool, which this chart does not ship.)

This file is deliberately duplicated from the bitcoin-node chart rather than
being factored into a library chart: both charts install standalone, and a
library dependency would add a fourth chart to the release, the Artifact Hub
listing and the version matrix for ~80 lines of template.
*/}}

{{/*
The scope map, from `global.networking.scopes`.
*/}}
{{- define "mining-pool.networking.scopes" -}}
{{- dig "networking" "scopes" dict (.Values.global | default dict) | toYaml -}}
{{- end -}}

{{- define "mining-pool.networking.baseDomain" -}}
{{- dig "networking" "baseDomain" "" (.Values.global | default dict) -}}
{{- end -}}

{{/*
Resolve one scope by name, applying the defaults for anything it left unset.

Takes a dict: `ctx` (the root context) and `scope` (the name). Returns the scope
as YAML — callers `fromYaml` it. Failing here rather than defaulting is
deliberate: a typo'd scope name would otherwise silently publish nothing, and
"my ingress did not appear" is a much worse afternoon than a render error.
*/}}
{{- define "mining-pool.networking.scope" -}}
{{- $ctx := .ctx -}}
{{- $name := .scope -}}
{{- $scopes := fromYaml (include "mining-pool.networking.scopes" $ctx) -}}
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
{{- define "mining-pool.networking.host" -}}
{{- $ctx := .ctx -}}
{{- $name := .scope -}}
{{- $ep := .endpoint -}}
{{- $override := dig "hosts" $name "" $ep -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- $scope := fromYaml (include "mining-pool.networking.scope" (dict "ctx" $ctx "scope" $name)) -}}
{{- $base := include "mining-pool.networking.baseDomain" $ctx -}}
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
external-dns annotations for a raw-TCP Service (stratum).

One Service, so every scope's hostname goes into a single comma-separated
`hostname` annotation — external-dns accepts a list. Only scopes with
publishDns are included; a scope's own `annotations` map is deliberately NOT
merged here, because it is where provider options like cloudflare-proxied live
and those are HTTP-proxy settings that cannot apply to a raw TCP stream.

The TTL comes from the first publishing scope: there is one record set per
hostname, but only one annotation to carry a TTL.
*/}}
{{- define "mining-pool.networking.serviceAnnotations" -}}
{{- $ctx := .ctx -}}
{{- $ep := .endpoint -}}
{{- $hosts := list -}}
{{- $ttl := "" -}}
{{- range $name := (get $ep "scopes" | default list) -}}
{{- $scope := fromYaml (include "mining-pool.networking.scope" (dict "ctx" $ctx "scope" $name)) -}}
{{- if $scope.publishDns -}}
{{- $hosts = append $hosts (include "mining-pool.networking.host" (dict "ctx" $ctx "scope" $name "endpoint" $ep)) -}}
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
without a `tls:` block. That is a legitimate choice for a read-only stats page on
a trusted LAN, so it is allowed here — unlike the node's RPC, which refuses to
publish without a certificate.
*/}}
{{- define "mining-pool.networking.tlsSecret" -}}
{{- $ctx := .ctx -}}
{{- $name := .scope -}}
{{- $ep := .endpoint -}}
{{- $existing := dig "tlsSecrets" $name "" $ep -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- $scope := fromYaml (include "mining-pool.networking.scope" (dict "ctx" $ctx "scope" $name)) -}}
{{- if $scope.issuer -}}
{{- printf "%s-%s-tls" .base $name -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/*
Guards. Called from mining-pool.validate, so they run on every render.
*/}}
{{- define "mining-pool.networking.validate" -}}
{{- $net := .Values.networking | default dict -}}

{{/* A typo'd endpoint key is silent otherwise: `networking.API` would sit there
     looking configured while publishing nothing at all. */}}
{{- $known := list "api" "stratum" -}}
{{- range $epName := (keys $net | sortAlpha) -}}
{{- if not (has $epName $known) -}}
{{- fail (printf "\n\nnetworking.%s is not an endpoint of this chart.\n\nPublishable endpoints are: %s.\n" $epName (join ", " $known)) -}}
{{- end -}}
{{- end -}}

{{/* Resolving every referenced scope proves each one exists and that a hostname
     can actually be derived for it, before any of it reaches a cluster. */}}
{{- range $epName := (keys $net | sortAlpha) -}}
{{- $ep := index $net $epName | default dict -}}
{{- range $scopeName := (get $ep "scopes" | default list) -}}
{{- $_ := include "mining-pool.networking.host" (dict "ctx" $ "scope" $scopeName "endpoint" $ep) -}}
{{- end -}}
{{- end -}}

{{/* ── Stratum ──────────────────────────────────────────────────────────────
     Raw TCP: a DNS record is the only thing on offer, so a scope that does not
     publish records leaves nothing behind. Silently rendering nothing is the
     failure mode this guard exists to prevent. */}}
{{- $stratum := get $net "stratum" | default dict -}}
{{- if get $stratum "scopes" -}}
{{- $publishing := false -}}
{{- range $scopeName := $stratum.scopes -}}
{{- $scope := fromYaml (include "mining-pool.networking.scope" (dict "ctx" $ "scope" $scopeName)) -}}
{{- if $scope.publishDns -}}{{- $publishing = true -}}{{- end -}}
{{- end -}}
{{- if not $publishing -}}
{{- fail (printf "\n\nnetworking.stratum.scopes lists %s, but no scope in that list has publishDns.\n\nStratum is a raw TCP stream: it cannot go behind an HTTP Ingress, so a DNS record\nis the only thing publishing it can produce. With publishDns off in every listed\nscope this setting would render nothing at all.\n\nSet publishDns on the scope:\n\n  global:\n    networking:\n      scopes:\n        %s:\n          publishDns: true\n" (join ", " $stratum.scopes) (first $stratum.scopes)) -}}
{{- end -}}

{{/* Nothing to point a record at. external-dns needs an address on the Service,
     and a ClusterIP is not reachable from any miner that would query this name. */}}
{{- if eq .Values.stratum.service.type "ClusterIP" -}}
{{- fail "\n\nnetworking.stratum.scopes is set, but stratum.service.type is ClusterIP.\n\nThere is no address to publish: a ClusterIP is only reachable inside the cluster,\nand external-dns has no external IP to write into the record. A miner outside the\ncluster could resolve the name and still not reach the pool.\n\nSet stratum.service.type to LoadBalancer (MetalLB, on a homelab) or NodePort\nfirst.\n" -}}
{{- end -}}
{{- end -}}

{{/* ── The stats API ────────────────────────────────────────────────────────
     ckpool has no HTTP surface at all — no API, no web UI, nothing to serve —
     so services.yaml does not create an API Service under it. An Ingress here
     would point at a backend that does not exist: it would render, install, and
     then 503 forever. */}}
{{- $api := get $net "api" | default dict -}}
{{- if get $api "scopes" -}}
{{- if eq .Values.pool.implementation "ckpool" -}}
{{- fail "\n\nnetworking.api.scopes is set, but pool.implementation is 'ckpool'.\n\nckpool has no HTTP surface — no stats API and no web UI — so this chart does not\ncreate an API Service for it. The Ingress would point at a backend that does not\nexist and serve 503s.\n\nThe stratum port is ckpool's only interface. Publish that instead\n(networking.stratum), or switch to pool.implementation=public-pool, which does\nserve a JSON stats API.\n" -}}
{{- end -}}
{{- end -}}
{{- end -}}
