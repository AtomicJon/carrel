#!/usr/bin/env bash
#
# Provision the `rust` VM image on top of `base`.
#
# Keep in step with the Dockerfile's rust stage: a tool added to one belongs in
# the other.

set -euo pipefail

RUST_TOOLCHAIN=stable

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  pkg-config \
  libssl-dev
rm -rf /var/lib/apt/lists/*

su - claude -c "
  set -euo pipefail
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain ${RUST_TOOLCHAIN}
  ~/.cargo/bin/rustup component add clippy rustfmt
"
