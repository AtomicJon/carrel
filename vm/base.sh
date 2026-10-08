#!/usr/bin/env bash
#
# Provision the `base` VM image. Runs as root inside a fresh Debian VM during
# `carrel-vm build`; the result is published as an Incus image. It uses the same
# user, paths and entrypoint as the container, so entrypoint.sh behaves the same
# in both.
#
# Keep in step with the Dockerfile's base stage: a tool added to one belongs in
# the other.

set -euo pipefail

NVM_VERSION=v0.40.1
GLAB_VERSION=1.108.0

export DEBIAN_FRONTEND=noninteractive

# Same toolset as the Docker image (see the Dockerfile for what each is for).
# wl-clipboard is left out: a VM can't be handed the host's Wayland socket.
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  less \
  ripgrep \
  fd-find \
  fzf \
  jq \
  tree \
  procps \
  openssh-client \
  libstdc++6 \
  tzdata
ln -sf "$(command -v fdfind)" /usr/local/bin/fd

curl -fsSL -o /usr/local/share/ca-certificates/isrg-root-yr-by-x1.crt \
  https://letsencrypt.org/certs/gen-y/root-yr-by-x1.pem
update-ca-certificates

install -d -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_$(dpkg --print-architecture).deb" \
  -o /tmp/glab.deb
apt-get update
apt-get install -y --no-install-recommends gh /tmp/glab.deb
rm -f /tmp/glab.deb
rm -rf /var/lib/apt/lists/*

install -m 755 /tmp/carrel/entrypoint.sh /usr/local/bin/carrel-entrypoint

# uid 1000 so files written through the virtiofs shares keep the host user's
# ownership. No sudo: root inside the VM is what can remount or unhide things.
useradd --create-home --shell /bin/bash --uid 1000 claude
git config --system --add safe.directory '*'
mkdir -p /home/claude/.claude \
  /home/claude/.local/bin /home/claude/.local/share/claude \
  /home/claude/.local/share/pnpm /home/claude/.cache/yarn \
  /home/claude/.opencode /home/claude/.config/opencode \
  /home/claude/.local/share/opencode /home/claude/.local/state/opencode \
  /home/claude/.cache/opencode
chown -R claude:claude /home/claude

su - claude -c "
  set -euo pipefail
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
  mkdir -p ~/.nvm/versions/node
  echo 'nvm use default --silent >/dev/null 2>&1 || true' >> ~/.bashrc
"
