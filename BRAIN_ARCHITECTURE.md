# VULKN Gold Standard Brain Architecture

## The Goal
Keep the GitHub 'vulkn-cloud-brains' repo organized by agent name (e.g., /vulki, /cloud-sam) while keeping OpenClaw files in the root for the agent to function.

## The Strategy: Symlink Rooting
All persistent agent files live in a named folder, with symlinks in the root.

### Structure
/data/workspace/
├── [agent-name]/          <-- Actual Git Root
│   ├── IDENTITY.md
│   ├── SOUL.md
│   └── memory/
├── IDENTITY.md -> [agent-name]/IDENTITY.md
├── SOUL.md -> [agent-name]/SOUL.md
└── memory -> [agent-name]/memory

## Setup Script for New Agents
```bash
mkdir -p [agent-name]
mv AGENTS.md HEARTBEAT.md IDENTITY.md MEMORY.md SOUL.md TOOLS.md USER.md memory/ [agent-name]/
ln -sf [agent-name]/AGENTS.md .
ln -sf [agent-name]/HEARTBEAT.md .
ln -sf [agent-name]/IDENTITY.md .
ln -sf [agent-name]/MEMORY.md .
ln -sf [agent-name]/SOUL.md .
ln -sf [agent-name]/TOOLS.md .
ln -sf [agent-name]/USER.md .
ln -sf [agent-name]/memory .
```

## Backup Cron Job
```bash
cd /data/workspace/[agent-name] && git add . && git commit -m "brain backup" && git push origin main
```
