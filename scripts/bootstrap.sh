#!/usr/bin/env bash
# One-shot bootstrap for toi_companion.
#
# - Installs Node deps in worker/ (wrangler, typescript, @cloudflare/workers-types).
# - Generates the Xcode project from app/project.yml via XcodeGen.
# - Verifies both build targets compile.
#
# Idempotent: safe to run multiple times.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- Worker ----------
echo "==> Worker: installing npm deps"
cd "$REPO_ROOT/worker"
npm install

echo "==> Worker: typechecking"
npx tsc --noEmit

# ---------- App ----------
echo "==> App: checking xcodegen"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "    xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

cd "$REPO_ROOT/app"
xcodegen generate

echo "==> App: building (Debug)"
xcodebuild \
  -project ToiCompanion.xcodeproj \
  -scheme ToiCompanion \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  | tail -n 5

echo "==> Done. Next steps:"
echo "    1. cd worker && wrangler login"
echo "    2. wrangler secret put OPENAI_API_KEY"
echo "    3. wrangler secret put TOI_SHARED_SECRET"
echo "    4. wrangler deploy"
echo "    5. cd ../app && open ./build/Debug/ToiCompanion.app"