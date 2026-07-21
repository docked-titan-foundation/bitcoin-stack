#!/usr/bin/env bash
# Called by semantic-release (.releaserc prepareCmd) with the next version.
#
# A chart's version lives in its Chart.yaml, not in package.json, so this is the
# step that makes the release real: it bumps all three charts (and the umbrella's
# dependency pins, which must match or `helm dependency build` fails), rewrites
# the README's version matrix, and syncs the local VERSION in .mise.toml.
set -euo pipefail

VERSION="${1:?usage: update-versions.sh <version>   (e.g. 1.2.0)}"
VERSION="${VERSION#v}"

CHARTS=(bitcoin-node mining-pool bitcoin-stack)
DATE="$(date -u +%Y-%m-%d)"

echo "🔖 Setting version ${VERSION}"

for chart in "${CHARTS[@]}"; do
  f="charts/${chart}/Chart.yaml"
  # Only the top-level `version:`/`appVersion:` — never a dependency's.
  sed -i -E "s/^version: .*/version: ${VERSION}/" "$f"
  sed -i -E "s/^appVersion: .*/appVersion: \"${VERSION}\"/" "$f"
  echo "   ${f}"
done

# The umbrella pins its subcharts by exact version. If those pins drift from the
# subcharts' own Chart.yaml, `helm dependency build` fails and the release is
# broken — so they are rewritten from the same variable rather than by hand.
python3 - "$VERSION" <<'PY'
import re, sys, pathlib
version = sys.argv[1]
p = pathlib.Path("charts/bitcoin-stack/Chart.yaml")
s = re.sub(
    r"(  - name: (?:bitcoin-node|mining-pool)\n    version: )[^\n]+",
    lambda m: m.group(1) + version,
    p.read_text(),
)
p.write_text(s)
print(f"   charts/bitcoin-stack/Chart.yaml (dependency pins → {version})")
PY

# The local build tag, so `mise run build` produces something recognisable.
# `-local` is a SemVer prerelease suffix: `1.2.0-local` is valid, `1.2.0.local`
# (a 4th version segment) is not, and helm package rejects it.
sed -i -E "s/^VERSION    = .*/VERSION    = \"v${VERSION}-local\"/" .mise.toml
echo "   .mise.toml"

# The README's version matrix. The new row is inserted beneath the matrix's
# header-separator line, and the previous "(latest)" marker is dropped.
#
# The anchor must be the *matrix* separator, not the first "|---|" in the file:
# the README has other tables above this one (e.g. the "Options" table), so the
# awk arms only after it has seen the matrix header row and fires on the very
# next separator line — otherwise release rows land in the wrong table.
NODE_KNOTS="$(grep -A2 '^  knots:' charts/bitcoin-node/values.yaml | grep 'tag:' | sed -E 's/.*"(.*)".*/\1/')"
NODE_CORE="$(grep -A2 '^  core:' charts/bitcoin-node/values.yaml | grep 'tag:' | sed -E 's/.*"(.*)".*/\1/')"

if grep -q '^| Chart | Knots | Core | Pool | Date |$' README.md; then
  sed -i -E 's/ \(latest\)//' README.md
  awk -v ver="$VERSION" -v knots="$NODE_KNOTS" -v core="$NODE_CORE" -v date="$DATE" '
    { print }
    /^\| Chart \| Knots \| Core \| Pool \| Date \|$/ { in_matrix = 1 }
    in_matrix && !done && /^\|[- |:]+\|$/ {
      printf "| %s (latest) | %s | %s | public-pool | %s |\n", ver, knots, core, date
      done = 1
    }
  ' README.md > README.md.tmp && mv README.md.tmp README.md
  echo "   README.md (version matrix)"
fi

echo "✅ Version ${VERSION} written"
