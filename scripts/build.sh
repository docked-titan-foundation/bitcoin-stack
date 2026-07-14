#!/bin/bash
# Package every chart into dist/. The version comes from VERSION (set by mise, or
# by semantic-release in CI); the leading "v" is stripped because SemVer in a
# Chart.yaml must not carry one.
set -e

VERSION="${VERSION:-v0.0.0.local}"
CHART_VERSION="${VERSION#v}"
DEBUG="${DEBUG:-0}"

CHARTS=(bitcoin-node mining-pool bitcoin-stack)

echo "📦 Packaging charts at ${CHART_VERSION}"
rm -rf dist
mkdir -p dist

run() {
  if [ "$DEBUG" = "1" ]; then "$@"; else "$@" >/dev/null 2>&1; fi
}

for chart in "${CHARTS[@]}"; do
  # The umbrella pulls in the other two from file://, so its dependencies have to
  # be rebuilt after they are packaged.
  if [ "$chart" = "bitcoin-stack" ]; then
    run helm dependency update "charts/${chart}"
  fi

  if run helm package "charts/${chart}" \
      --version "${CHART_VERSION}" \
      --app-version "${CHART_VERSION}" \
      --destination dist; then
    echo "✅ PASS  ${chart}"
  else
    echo "❌ FAIL  ${chart}"
    exit 1
  fi
done

echo
ls -1 dist/
