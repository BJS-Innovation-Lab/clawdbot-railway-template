#!/usr/bin/env bash
# VULKN bootstrap hook — called by wrapper on every start.
# Runs auto-boot on first deploy, skips on subsequent starts.

SCRIPT_DIR="$(dirname "$0")"

# First check workspace (may have newer version from vulkn-field-template)
if [ -f "${OPENCLAW_WORKSPACE_DIR:-/data/workspace}/deploy/auto-boot.sh" ]; then
    exec bash "${OPENCLAW_WORKSPACE_DIR:-/data/workspace}/deploy/auto-boot.sh"
fi

# Fall back to the version baked into the Docker image
BAKED="/app/scripts/vulkn-auto-boot.sh"
if [ -f "$BAKED" ]; then
    exec bash "$BAKED"
fi

echo "[bootstrap] No auto-boot script found — skipping"
