#!/usr/bin/env bash
#
# Bootstrap Claude + a project's Node toolchain at container start.
#
# Neither Claude nor Node is baked into the image, keeping it small. Both are
# installed on demand into named volumes, so it's a one-time download that
# persists across runs — and Claude self-updates.
#
# Claude: the versioned binaries live in a volume at ~/.local/share/claude. The
#   launcher symlink (~/.local/bin/claude) is NOT in the volume, so we recreate
#   it each launch, pointing at the newest cached version — which also activates
#   any background auto-update from a previous session. Only the binary is
#   persisted; nothing else under ~/.local is shared.
# Node: when the mounted project looks like a Node project, the version it pins
#   (.nvmrc / .node-version) or the latest LTS is installed, then corepack is
#   enabled for yarn/pnpm. Non-Node projects skip Node entirely.

export NVM_DIR=/home/claude/.nvm
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# Everything below operates in the container's working directory, which is set
# (via `-w`) to the project's real host path — so Node detection reads this
# project's files and Claude keys session history by that path.

# Claude Code — native standalone binary (no Node needed).
claude_versions=/home/claude/.local/share/claude/versions
claude_latest() { ls -1 "$claude_versions" 2>/dev/null | sort -V | tail -1; }

ver="$(claude_latest)"
if [ -z "$ver" ]; then
    echo "carrel: installing Claude Code (first run)..." >&2
    curl -fsSL https://claude.ai/install.sh | bash >/dev/null
    ver="$(claude_latest)"
fi
[ -n "$ver" ] && ln -sfn "$claude_versions/$ver" /home/claude/.local/bin/claude

if [ -f package.json ] || [ -f .nvmrc ] || [ -f .node-version ]; then
    echo "carrel: provisioning Node for this project..." >&2
    if [ -f .nvmrc ] || [ -f .node-version ]; then
        nvm install            # honours .nvmrc / .node-version, and activates it
    else
        nvm install --lts      # package.json with no pinned version
    fi
    # Make this version the default so interactive shells pick it up too, and
    # enable yarn/pnpm shims (managed per project via the packageManager field).
    nvm alias default "$(nvm current)" >/dev/null 2>&1
    corepack enable 2>/dev/null || true
fi

# node is now on PATH (exported), inherited by the exec'd process and its
# children.
exec "$@"
