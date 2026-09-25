#!/usr/bin/env bash
# Dev runner: Worker (wrangler dev) + build the app and open it.
#
# The app points at the local Worker by editing CompanionManager.swift's
# workerBaseURL to http://localhost:8787 (Phase 4+).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_ROOT/worker"
exec npx wrangler dev --port 8787