#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# VULKN Auto-Boot Script
# ═══════════════════════════════════════════════════════════
# Runs on container start. Detects a fresh workspace and
# automatically:
#   1. Generates openclaw.json from env vars (skips /setup)
#   2. Clones vulkn-field-template (skills + deploy scripts)
#   3. Runs init-agent.sh --gold-standard (cron jobs + config)
#   4. Sets up brain repo (persistent memory across redeploys)
#   5. Registers agent in Hive Mind
#
# Required env vars:
#   ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN,
#   OPENCLAW_GATEWAY_TOKEN (or auto-generated),
#   GITHUB_TOKEN, BRAIN_REPO (e.g. BJS-Innovation-Lab/sophia-brain)
#
# Optional env vars:
#   AGENT_NAME          — agent identity (default: from BRAIN_REPO)
#   AGENT_TIMEZONE      — timezone (default: America/Mexico_City)
#   SETUP_PASSWORD      — web UI login password
#   SUPABASE_URL        — for Hive Mind
#   SUPABASE_SERVICE_ROLE_KEY — for Hive Mind
#   GEMINI_API_KEY      — secondary model provider
#
# Usage: Called from wrapper entrypoint OR run manually:
#   ./deploy/auto-boot.sh
# ═══════════════════════════════════════════════════════════

set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.clawdbot}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
CONFIG_FILE="$STATE_DIR/openclaw.json"
TEMPLATE_REPO="https://github.com/BJS-Innovation-Lab/vulkn-field-template.git"
BOOT_MARKER="$STATE_DIR/.vulkn-boot-complete"
TZ="${AGENT_TIMEZONE:-America/Mexico_City}"

# Derive agent name from BRAIN_REPO if not set
# e.g. BJS-Innovation-Lab/sophia-brain -> sophia
if [ -z "${AGENT_NAME:-}" ] && [ -n "${BRAIN_REPO:-}" ]; then
    AGENT_NAME=$(echo "$BRAIN_REPO" | sed 's|.*/||; s|-brain$||')
fi
AGENT_NAME="${AGENT_NAME:-agent}"

log() { echo "🐾 [auto-boot] $*"; }

# ── Guard: skip if already booted ─────────────────────────
if [ -f "$BOOT_MARKER" ]; then
    log "Already booted (marker exists). Skipping."
    exit 0
fi

log "Starting VULKN auto-boot for agent: $AGENT_NAME"

# ── Step 1: Generate openclaw.json ────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "Step 1/5: Generating openclaw.json..."

    # Require minimum credentials
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        log "ERROR: ANTHROPIC_API_KEY not set. Cannot generate config."
        exit 1
    fi
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        log "ERROR: TELEGRAM_BOT_TOKEN not set. Cannot generate config."
        exit 1
    fi

    # Use existing gateway token or generate one
    GW_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"

    mkdir -p "$STATE_DIR"

    node -e "
const fs = require('fs');
const config = {
  meta: {
    lastTouchedVersion: '2026.2.9',
    lastTouchedAt: new Date().toISOString()
  },
  auth: {
    profiles: {
      'anthropic:default': {
        provider: 'anthropic',
        mode: 'token'
      }
    }
  },
  agents: {
    defaults: {
      workspace: '$WORKSPACE_DIR',
      userTimezone: '$TZ',
      contextPruning: { mode: 'cache-ttl', ttl: '1h' },
      compaction: { mode: 'safeguard' },
      heartbeat: { every: '1h' },
      maxConcurrent: 4,
      subagents: { maxConcurrent: 8 }
    }
  },
  messages: { ackReactionScope: 'group-mentions' },
  commands: { native: 'auto', nativeSkills: 'auto' },
  channels: {
    telegram: {
      enabled: true,
      dmPolicy: 'pairing',
      botToken: process.env.TELEGRAM_BOT_TOKEN,
      groupPolicy: 'allowlist',
      streamMode: 'partial'
    }
  },
  gateway: {
    port: 18789,
    mode: 'local',
    bind: 'loopback',
    controlUi: {
      enabled: true,
      allowInsecureAuth: true
    },
    auth: {
      mode: 'token',
      token: '$GW_TOKEN'
    },
    trustedProxies: ['127.0.0.1'],
    tailscale: { mode: 'off', resetOnExit: false },
    remote: { token: '$GW_TOKEN' }
  },
  skills: { install: { nodeManager: 'npm' } },
  plugins: { entries: { telegram: { enabled: true } } }
};
fs.writeFileSync('$CONFIG_FILE', JSON.stringify(config, null, 2));
console.log('  ✅ Config written');
"

    # Export the token so the wrapper picks it up
    export OPENCLAW_GATEWAY_TOKEN="$GW_TOKEN"
else
    log "Step 1/5: openclaw.json already exists. Skipping."
fi

# ── Step 2: Clone skills template ─────────────────────────
if [ ! -f "$WORKSPACE_DIR/deploy/init-agent.sh" ]; then
    log "Step 2/5: Cloning vulkn-field-template into workspace..."
    mkdir -p "$WORKSPACE_DIR"

    # Clone into temp dir, then move contents (workspace may have agent brain files)
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "$TEMPLATE_REPO" "$TMPDIR"
    
    # Copy template files without overwriting existing agent files
    cp -rn "$TMPDIR"/* "$WORKSPACE_DIR"/ 2>/dev/null || true
    cp -rn "$TMPDIR"/.* "$WORKSPACE_DIR"/ 2>/dev/null || true
    rm -rf "$TMPDIR"
    
    log "  ✅ Skills template cloned"
else
    log "Step 2/5: Skills already present. Skipping."
fi

# ── Step 3: Run gold standard init ────────────────────────
log "Step 3/5: Running init-agent.sh --gold-standard..."
cd "$WORKSPACE_DIR"
chmod +x deploy/init-agent.sh
bash deploy/init-agent.sh --gold-standard 2>&1 | tail -5
log "  ✅ Gold standard init complete"

# ── Step 4: Set up brain repo ─────────────────────────────
if [ -n "${BRAIN_REPO:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    log "Step 4/5: Setting up brain repo ($BRAIN_REPO)..."
    
    BRAIN_URL="https://${GITHUB_TOKEN}@github.com/${BRAIN_REPO}.git"
    BRAIN_DIR="$WORKSPACE_DIR/$AGENT_NAME"
    REPO_NAME=$(echo "$BRAIN_REPO" | sed 's|.*/||')

    # Detect monorepo (vulkn-cloud-brains) vs standalone (sofia-brain)
    if echo "$REPO_NAME" | grep -qi "cloud-brains\|brains"; then
        # Monorepo: clone once, agent lives in a subdirectory
        BRAIN_CLONE_DIR="$WORKSPACE_DIR/.brain-repo"
        log "  Monorepo pattern: $REPO_NAME/$AGENT_NAME"
        if [ ! -d "$BRAIN_CLONE_DIR/.git" ]; then
            git clone "$BRAIN_URL" "$BRAIN_CLONE_DIR" 2>/dev/null || true
        else
            cd "$BRAIN_CLONE_DIR" && git pull 2>/dev/null || true
            cd "$WORKSPACE_DIR"
        fi
        mkdir -p "$BRAIN_CLONE_DIR/$AGENT_NAME/memory/projects" \
                 "$BRAIN_CLONE_DIR/$AGENT_NAME/memory/learning" \
                 "$BRAIN_CLONE_DIR/$AGENT_NAME/memory/core"
        # Symlink agent subdir to workspace
        if [ ! -L "$BRAIN_DIR" ] && [ ! -d "$BRAIN_DIR" ]; then
            ln -sf "$BRAIN_CLONE_DIR/$AGENT_NAME" "$BRAIN_DIR"
        fi
        log "  ✅ Brain monorepo configured"
    else
        # Standalone repo
        if [ ! -d "$BRAIN_DIR/.git" ]; then
            if git clone "$BRAIN_URL" "$BRAIN_DIR" 2>/dev/null; then
                log "  ✅ Brain repo cloned"
            else
                log "  Creating brain directory (no remote)..."
                mkdir -p "$BRAIN_DIR/memory/projects" "$BRAIN_DIR/memory/learning" "$BRAIN_DIR/memory/core"
            fi
        else
            log "  Brain repo already set up"
        fi
    fi

    # Create symlinks from workspace root to brain files
    for f in SOUL.md IDENTITY.md USER.md MEMORY.md TOOLS.md HEARTBEAT.md AGENTS.md; do
        if [ -f "$BRAIN_DIR/$f" ] && [ ! -L "$WORKSPACE_DIR/$f" ]; then
            ln -sf "$BRAIN_DIR/$f" "$WORKSPACE_DIR/$f"
        fi
    done
    if [ -d "$BRAIN_DIR/memory" ] && [ ! -L "$WORKSPACE_DIR/memory" ]; then
        rm -rf "$WORKSPACE_DIR/memory" 2>/dev/null || true
        ln -sf "$BRAIN_DIR/memory" "$WORKSPACE_DIR/memory"
    fi
    log "  ✅ Symlinks configured"
else
    log "Step 4/5: No BRAIN_REPO set. Skipping."
fi

# ── Step 5: Register in Hive Mind ─────────────────────────
if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    log "Step 5/5: Registering in Hive Mind..."
    if [ -f "$WORKSPACE_DIR/skills/collective-memory/register-team-complete.js" ]; then
        cd "$WORKSPACE_DIR"
        AGENT_NAME="$AGENT_NAME" node skills/collective-memory/register-team-complete.js 2>&1 | tail -3
        log "  ✅ Hive Mind registration complete"
    else
        log "  ⚠️  Hive Mind script not found. Skipping."
    fi
else
    log "Step 5/5: No Supabase credentials. Skipping Hive Mind."
fi

# ── Done ──────────────────────────────────────────────────
touch "$BOOT_MARKER"
log "════════════════════════════════════════════"
log "✅ VULKN auto-boot complete for: $AGENT_NAME"
log "════════════════════════════════════════════"
