#!/usr/bin/env bash
#
# Provision the `tauri` VM image on top of `rust`.
#
# Keep in step with the Dockerfile's tauri stage: a tool added to one belongs in
# the other.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  libxdo-dev \
  file \
  wget
rm -rf /var/lib/apt/lists/*

su - claude -c "
  set -euo pipefail
  ~/.cargo/bin/cargo install tauri-cli --locked
  rm -rf ~/.cargo/registry ~/.cargo/git
"
