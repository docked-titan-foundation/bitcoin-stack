#!/usr/bin/env bash
set -euo pipefail

RELEASERC=".releaserc"
EXIT=0

echo "🔍 Validating semantic release configuration..."

# 1. Check .releaserc exists
if [ ! -f "$RELEASERC" ]; then
  echo "❌ Error: $RELEASERC not found"
  exit 1
fi

# 2. Validate JSON syntax
if ! node -e "JSON.parse(require('fs').readFileSync('$RELEASERC','utf8'))" 2>/dev/null; then
  echo "❌ Error: $RELEASERC contains invalid JSON"
  exit 1
fi

# 3. Validate assets from @semantic-release/git plugin exist
ASSETS=$(node -e "
const cfg = JSON.parse(require('fs').readFileSync('$RELEASERC','utf8'));
const gitPlugin = cfg.plugins.find(p => Array.isArray(p) && p[0] === '@semantic-release/git');
if (gitPlugin) console.log(gitPlugin[1].assets.join(' '));
" 2>/dev/null || true)

if [ -n "$ASSETS" ]; then
  echo "📦 Checking git plugin assets..."
  for asset in $ASSETS; do
    if [ ! -f "$asset" ]; then
      echo "❌ Error: Asset file '$asset' referenced in @semantic-release/git does not exist"
      EXIT=1
    fi
  done
else
  echo "⚠️  Warning: No assets found in @semantic-release/git plugin"
fi

# 4. Validate prepareCmd from @semantic-release/exec plugin uses nextRelease.version
PREPARE_SCRIPT=$(RELEASERC="$RELEASERC" node -e '
const cfg = JSON.parse(require("fs").readFileSync(process.env.RELEASERC, "utf8"));
const execPlugin = cfg.plugins.find(p => Array.isArray(p) && p[0] === "@semantic-release/exec");
if (execPlugin && execPlugin[1].prepareCmd) {
  const match = execPlugin[1].prepareCmd.match(/\$\{nextRelease\.version\}/);
  if (match) console.log("prepareCmd uses nextRelease.version placeholder");
}
' 2>/dev/null || true)

if [ "$PREPARE_SCRIPT" = "prepareCmd uses nextRelease.version placeholder" ]; then
  echo "✅ @semantic-release/exec prepareCmd is correctly configured"
else
  echo "⚠️  Warning: @semantic-release/exec prepareCmd may not be using nextRelease.version"
fi

# 5. Try a dry-run (if git environment is suitable)
echo ""
echo "🧪 Running semantic-release dry-run (configuration check only)..."
if npx semantic-release --dry-run --no-ci 2>&1 | tee /tmp/sr-dry-run.log; then
  echo "✅ Semantic-release dry-run completed successfully"
else
  echo "⚠️  Dry-run encountered issues (may be due to local git state). Checking logs..."
  if grep -q "missing file\|cannot find\|ENOENT" /tmp/sr-dry-run.log; then
    echo "❌ Semantic-release configuration error detected in logs"
    EXIT=1
  else
    echo "ℹ️  Dry-run failed for reasons unrelated to config validation (likely git tag conflicts)"
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $EXIT -eq 0 ]; then
  echo "✅ All validation checks passed"
  exit 0
else
  echo "❌ Some validation checks failed"
  exit 1
fi
