#!/usr/bin/env bash
# OpenUI claw — one-shot installer.
#
#   curl -fsSL https://openui.com/openclaw-os/install.sh | bash
#
# Pulls the plugin from GitHub via degit (no npm publish needed), installs it
# into the local openclaw gateway, and opens the dashboard in your browser.
set -euo pipefail

PREFIX="[openui-claw]"
log() { printf '%s %s\n' "$PREFIX" "$*"; }
fail() { printf '%s ERROR: %s\n' "$PREFIX" "$*" >&2; exit 1; }

# 1. Sanity check: bash needs to actually be running.
[ -n "${BASH_VERSION:-}" ] || fail "This script requires bash. Run with \`bash install.sh\`."

# 2. Platform check. macOS + Linux supported; Windows users need WSL.
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) fail "Unsupported platform: $(uname -s). Use macOS, Linux, or WSL on Windows." ;;
esac

# 3. openclaw must already be installed (we don't auto-install per user pref).
if ! command -v openclaw >/dev/null 2>&1; then
  fail "openclaw CLI not found.
       Install it first:  curl -fsSL https://openclaw.ai/install.sh | bash
       Then re-run this script."
fi

# 4. Need node for degit and the launcher script.
if ! command -v node >/dev/null 2>&1; then
  fail "node not found. Install Node 22+ from https://nodejs.org and re-run."
fi

# 5. Pull the plugin source from GitHub. degit is a shallow snapshot, no git
#    history, no auth required for public repos. Drop into a tmpdir so we
#    don't pollute the user's cwd or home.
PLUGIN_REPO="${OPENUI_CLAW_PLUGIN_REPO:-thesysdev/openui/openui-claw/packages/claw-plugin}"
TMPDIR_ROOT="$(mktemp -d -t openui-claw-XXXXXX)"
PLUGIN_SRC="$TMPDIR_ROOT/plugin"

log "Downloading plugin from $PLUGIN_REPO …"
npx --yes degit "$PLUGIN_REPO" "$PLUGIN_SRC"

[ -f "$PLUGIN_SRC/openclaw.plugin.json" ] || fail "Downloaded plugin is missing openclaw.plugin.json — repo path may be wrong."

# 6. Install into openclaw. Copy mode (no -l) so openclaw runs npm install in
#    its managed install dir; flat node_modules, no escaping symlinks, the
#    install path that worked when the user tested earlier in development.
log "Installing plugin into openclaw …"
openclaw plugins install "$PLUGIN_SRC" --force

# 6b. Pin the plugin in `plugins.allow` so the gateway doesn't lazy-reload it
#     on every tool lookup. Without this, openclaw 2026.5.x re-runs the
#     plugin's register() hook for non-allowlisted plugins on each
#     `resolvePluginToolRegistry` call, which intermittently leaves the tool
#     runtime registry inconsistent — symptom: first `app_create` succeeds,
#     subsequent calls fail with `plugin tool runtime missing`. Adding our
#     plugin id (and the stock plugins that are already loading) to
#     `plugins.allow` makes the gateway skip the lazy-reload path.
log "Pinning plugin in plugins.allow …"
PLUGIN_ID="openclaw-ui-plugin"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
if [ -f "$OPENCLAW_CONFIG" ]; then
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    const id = process.argv[2];
    const cfg = JSON.parse(fs.readFileSync(path, "utf8"));
    cfg.plugins ??= {};
    const allow = Array.isArray(cfg.plugins.allow) ? cfg.plugins.allow : [];
    // Preserve any stock plugins openclaw already discovered + add ours.
    // Empty allow list means "allow everything"; once we add ourselves we
    // must also include stock plugin ids the gateway is already loading,
    // otherwise they will be hidden. Cheapest correct list: union with the
    // stock-plugin ids we currently see in `plugins.entries` plus a known
    // set of always-loaded ids so we do not regress the user.
    const known = new Set([
      id,
      "browser", "device-pair", "file-transfer", "memory-core",
      "phone-control", "talk-voice", "telegram",
      "anthropic", "openrouter", "ollama"
    ]);
    for (const name of allow) known.add(name);
    for (const name of Object.keys(cfg.plugins.entries ?? {})) known.add(name);
    cfg.plugins.allow = Array.from(known).sort();
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
    console.log("plugins.allow set to", cfg.plugins.allow.length, "ids");
  ' "$OPENCLAW_CONFIG" "$PLUGIN_ID" || log "WARNING: could not update plugins.allow — edit $OPENCLAW_CONFIG manually."
else
  log "WARNING: $OPENCLAW_CONFIG not found; cannot pin plugins.allow. Run \`openclaw config\` and add \"$PLUGIN_ID\" to plugins.allow before relying on the gateway."
fi

# 7. Restart the gateway so the new plugin loads. Soft-fail if not running —
#    user will start it manually before opening the dashboard.
log "Reloading gateway …"
if openclaw gateway restart >/dev/null 2>&1; then
  log "Gateway restarted."
else
  log "WARNING: could not auto-restart gateway. Run: openclaw start"
fi

# 8. Launch the dashboard in the browser. The launcher script lives in the
#    workspace scripts/ folder (NOT inside the plugin — openclaw's install
#    scanner rejects child_process usage in plugin bundles). Pull it from
#    GitHub via degit so the user doesn't need a local checkout.
LAUNCHER_REPO="${OPENUI_CLAW_LAUNCHER_REPO:-thesysdev/openui/openui-claw/scripts/open-ui.mjs}"
LAUNCHER="$HOME/.openclaw/openui-claw-launcher.mjs"
log "Fetching launcher …"
npx --yes degit "$LAUNCHER_REPO" "$LAUNCHER" >/dev/null 2>&1 || \
  curl -fsSL "https://raw.githubusercontent.com/$(echo "$LAUNCHER_REPO" | cut -d/ -f1-2)/main/$(echo "$LAUNCHER_REPO" | cut -d/ -f3-)" -o "$LAUNCHER"
node "$LAUNCHER"

# 9. Cleanup.
rm -rf "$TMPDIR_ROOT"
log "Done. Re-run \`node $LAUNCHER\` anytime to reopen the dashboard."
