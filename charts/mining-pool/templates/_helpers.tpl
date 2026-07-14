{{- define "mining-pool.name" -}}
{{- default "mining-pool" .Values.nameOverride -}}
{{- end -}}

{{- define "mining-pool.stratum.name" -}}
{{ include "mining-pool.name" . }}-stratum
{{- end -}}

{{- define "mining-pool.api.name" -}}
{{ include "mining-pool.name" . }}-api
{{- end -}}

{{- define "mining-pool.configName" -}}
{{ include "mining-pool.name" . }}-config
{{- end -}}

{{- define "mining-pool.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ default (include "mining-pool.name" .) .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{- define "mining-pool.labels" -}}
app.kubernetes.io/part-of: {{ include "mining-pool.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
The image, resolved from pool.implementation.

public-pool has a default (the org's own hardened build, digest-pinned). ckpool
deliberately does not — see the guard below.
*/}}
{{- define "mining-pool.image" -}}
{{- if eq .Values.pool.implementation "ckpool" -}}
{{- $c := .Values.pool.ckpool.image -}}
{{- if $c.digest -}}
{{- printf "%s:%s@%s" $c.repository $c.tag $c.digest -}}
{{- else -}}
{{- printf "%s:%s" $c.repository $c.tag -}}
{{- end -}}
{{- else -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{- printf "%s:%s@%s" $i.repository $i.tag $i.digest -}}
{{- else -}}
{{- printf "%s:%s" $i.repository $i.tag -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Where the pool finds its node.

Under the umbrella chart every one of these comes from `global.bitcoinNode`,
which the node subchart reads too — so the endpoint, the port, the username and
the Secret are each defined in exactly one place and the two halves cannot drift
apart. Standalone, they come from this chart's own bitcoin.* values, and the
chart refuses to render if you have not said which node to mine on.
*/}}
{{- define "mining-pool.node" -}}
{{- dig "bitcoinNode" dict (.Values.global | default dict) | toYaml -}}
{{- end -}}

{{- define "mining-pool.rpcHost" -}}
{{- $g := dig "bitcoinNode" dict (.Values.global | default dict) -}}
{{- $host := .Values.bitcoin.rpc.host | default (get $g "rpcHost") -}}
{{- required "bitcoin.rpc.host is required: the pool has no node to mine on.\nWith the umbrella chart this is derived from the node subchart; standalone, point it at your node's RPC Service." $host -}}
{{- end -}}

{{- define "mining-pool.rpcPort" -}}
{{- $g := dig "bitcoinNode" dict (.Values.global | default dict) -}}
{{- default .Values.bitcoin.rpc.port (get $g "rpcPort") -}}
{{- end -}}

{{- define "mining-pool.rpcUsername" -}}
{{- $g := dig "bitcoinNode" dict (.Values.global | default dict) -}}
{{- default .Values.bitcoin.rpc.username (get $g "rpcUsername") -}}
{{- end -}}

{{- define "mining-pool.zmqHost" -}}
{{- $g := dig "bitcoinNode" dict (.Values.global | default dict) -}}
{{- $host := .Values.bitcoin.zmq.host | default (get $g "rpcHost") | default .Values.bitcoin.rpc.host -}}
{{- $port := default .Values.bitcoin.zmq.rawBlockPort (get $g "zmqRawBlockPort") -}}
{{- printf "tcp://%s:%v" $host $port -}}
{{- end -}}

{{- define "mining-pool.rpcSecretName" -}}
{{- $g := dig "bitcoinNode" dict (.Values.global | default dict) -}}
{{- $name := .Values.bitcoin.existingSecret.name | default (get $g "secretName") -}}
{{- required "bitcoin.existingSecret.name is required: the pool needs the node's RPC password.\nWith the umbrella chart this is wired to the node's own Secret automatically." $name -}}
{{- end -}}

{{/*
Guards.
*/}}
{{- define "mining-pool.validate" -}}
{{- $impl := .Values.pool.implementation -}}
{{- if not (has $impl (list "public-pool" "ckpool")) -}}
{{- fail (printf "\n\npool.implementation must be 'public-pool' or 'ckpool', got '%s'.\n" $impl) -}}
{{- end -}}

{{- if not (has .Values.pool.network (list "mainnet" "testnet")) -}}
{{- fail (printf "\n\npool.network must be 'mainnet' or 'testnet', got '%s'.\nRegtest and signet share testnet's address parameters — use 'testnet' for those.\n" .Values.pool.network) -}}
{{- end -}}

{{- if eq $impl "ckpool" -}}
{{- if not .Values.pool.ckpool.image.repository -}}
{{- fail "\n\nckpool has no default image, on purpose.\n\nckpool's upstream publishes source only — there is no official container image,\nand every ckpool image on Docker Hub is an unaudited personal build by an\nanonymous account. This process constructs the coinbase output that pays out a\nfound block: an image you have not audited can quietly pay it to someone else.\n\nSet pool.ckpool.image.repository/tag/digest to an image YOU trust, or use\npool.implementation=public-pool, which has a hardened, signed, SBOM-attested\nbuild published by docked-titan-foundation.\n" -}}
{{- end -}}
{{- end -}}

{{/* Supply chain: no unpinned images. */}}
{{- if not .Values.safety.allowUnpinnedImage -}}
{{- $digest := ternary .Values.pool.ckpool.image.digest .Values.image.digest (eq $impl "ckpool") -}}
{{- if not $digest -}}
{{- fail (printf "\n\nThe %s image is not pinned by digest.\nA tag is a mutable pointer, and this process builds the transaction that pays out\na found block.\nPin it, or set safety.allowUnpinnedImage=true to accept the risk deliberately.\n" $impl) -}}
{{- end -}}
{{- end -}}
{{- end -}}
