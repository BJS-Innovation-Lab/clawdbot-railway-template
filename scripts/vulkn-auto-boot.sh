#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# VULKN Auto-Boot Script
# ═══════════════════════════════════════════════════════════
# Runs automatically on first container start (via wrapper's
# bootstrap.sh hook). Detects a fresh workspace and:
#   1. Generates openclaw.json from env vars (skips /setup page)
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
#   AGENT_NAME          — agent identity (default: derived from BRAIN_REPO)
#   AGENT_TIMEZONE      — timezone (default: America/Mexico_City)
#   SETUP_PASSWORD      — web UI login password
#   SUPABASE_URL        — for Hive Mind
#   SUPABASE_SERVICE_ROLE_KEY — for Hive Mind
#   GEMINI_API_KEY      — secondary model provider
# ═══════════════════════════════════════════════════════════

set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.clawdbot}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
CONFIG_FILE="$STATE_DIR/openclaw.json"
TEMPLATE_REPO="https://github.com/BJS-Innovation-Lab/vulkn-field-template.git"
BOOT_MARKER="$STATE_DIR/.vulkn-boot-complete"
TZ="${AGENT_TIMEZONE:-America/Mexico_City}"

# Derive agent name from BRAIN_REPO if not set
if [ -z "${AGENT_NAME:-}" ] && [ -n "${BRAIN_REPO:-}" ]; then
    AGENT_NAME=$(echo "$BRAIN_REPO" | sed 's|.*/||; s|-brain$||')
fi
AGENT_NAME="${AGENT_NAME:-agent}"

log() { echo "🐾 [auto-boot] $*"; }

# ── Guard: skip if already booted ─────────────────────────
if [ -f "$BOOT_MARKER" ]; then
    log "Already booted. Skipping."
    exit 0
fi

# ── Guard: skip if missing minimum credentials ────────────
if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    log "Missing ANTHROPIC_API_KEY or TELEGRAM_BOT_TOKEN. Use /setup instead."
    exit 0
fi

log "Starting VULKN auto-boot for agent: $AGENT_NAME"

# ── Step 1: Generate openclaw.json ────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "Step 1/5: Generating openclaw.json..."
    GW_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"
    mkdir -p "$STATE_DIR"

    node -e "
const fs = require('fs');
const config = {
  meta: { lastTouchedVersion: '2026.2.9', lastTouchedAt: new Date().toISOString() },
  auth: { profiles: { 'anthropic:default': { provider: 'anthropic', mode: 'token' } } },
  agents: {
    defaults: {
      workspace: process.env.OPENCLAW_WORKSPACE_DIR || '/data/workspace',
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
    controlUi: { enabled: true, allowInsecureAuth: true },
    auth: { mode: 'token', token: '$GW_TOKEN' },
    trustedProxies: ['127.0.0.1'],
    tailscale: { mode: 'off', resetOnExit: false },
    remote: { token: '$GW_TOKEN' }
  },
  skills: { install: { nodeManager: 'npm' } },
  plugins: { entries: { telegram: { enabled: true } } }
};
fs.writeFileSync('$CONFIG_FILE', JSON.stringify(config, null, 2));
"
    log "  ✅ Config written"
else
    log "Step 1/5: Config exists. Skipping."
fi

# ── Step 2: Clone skills template ─────────────────────────
if [ ! -f "$WORKSPACE_DIR/deploy/init-agent.sh" ]; then
    log "Step 2/5: Cloning vulkn-field-template..."
    mkdir -p "$WORKSPACE_DIR"
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "$TEMPLATE_REPO" "$TMPDIR" 2>/dev/null
    cp -rn "$TMPDIR"/* "$WORKSPACE_DIR"/ 2>/dev/null || true
    cp -rn "$TMPDIR"/.gitignore "$WORKSPACE_DIR"/ 2>/dev/null || true
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
    BRAIN_DIR="$WORKSPACE_DIR/$AGENT_NAME"
    BRAIN_URL="https://${GITHUB_TOKEN}@github.com/${BRAIN_REPO}.git"

    if [ ! -d "$BRAIN_DIR/.git" ]; then
        if git clone "$BRAIN_URL" "$BRAIN_DIR" 2>/dev/null; then
            log "  ✅ Brain repo cloned"
        else
            log "  Creating new brain repo..."
            mkdir -p "$BRAIN_DIR/memory/projects" "$BRAIN_DIR/memory/learning" "$BRAIN_DIR/memory/core"
            cd "$BRAIN_DIR"
            git init
            echo "# $AGENT_NAME Brain" > README.md
            git add . && git commit -m "Initial brain setup"
            curl -s -X POST \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                "https://api.github.com/orgs/BJS-Innovation-Lab/repos" \
                -d "{\"name\":\"${BRAIN_REPO##*/}\",\"private\":true}" > /dev/null 2>&1 || true
            git remote add origin "$BRAIN_URL"
            git push -u origin main 2>/dev/null || true
            log "  ✅ Brain repo created"
            cd "$WORKSPACE_DIR"
        fi
    else
        log "  Brain repo already set up"
    fi

    # Symlinks from workspace root → brain files
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
        AGENT_NAME="$AGENT_NAME" node skills/collective-memory/register-team-complete.js 2>&1 | tail -3 || true
        log "  ✅ Hive Mind registration complete"
    fi
else
    log "Step 5/5: No Supabase creds. Skipping Hive Mind."
fi

# ── Done ──────────────────────────────────────────────────
touch "$BOOT_MARKER"
log "════════════════════════════════════════════"
log "✅ VULKN auto-boot complete for: $AGENT_NAME"
log "════════════════════════════════════════════"
