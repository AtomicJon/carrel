# syntax=docker/dockerfile:1
#
# Multi-target image for running Claude Code in a sandboxed dev container.
#
#   base   debian-slim + code search/nav tools + nvm.
#          Neither Claude nor Node is baked in; the entrypoint installs Claude
#          on first launch and provisions the project's Node version on demand,
#          both cached in volumes, so the image stays small and Claude
#          self-updates. corepack is enabled per-project, so this also covers
#          JS/TS work.
#   rust   base + rustup toolchain (clippy, rustfmt)
#   tauri  rust + web build deps (webkit, gtk) + tauri-cli
#
# Build a specific variant with --target, e.g.:
#   docker build --target rust -t carrel:rust .

# =============================================================================
# base
# =============================================================================
FROM debian:stable-20260610-slim AS base

ARG NVM_VERSION=v0.40.1

# UTF-8 locale; quieter npm. Claude lives in a persistent volume (see the
# entrypoint), so its background auto-updater is left enabled — updates stick.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# ripgrep / fd : fast content + filename search
# fzf          : fuzzy selection
# jq           : JSON wrangling
# tree, less   : navigation + paging (git needs a pager)
# git          : latest available in Debian stable (security-patched via apt)
# libstdc++6   : runtime for the prebuilt Claude binary (installed at runtime)
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/* \
    # Debian ships fd as `fdfind`; expose the familiar `fd` name too.
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# Provisions Node lazily at container start (see the script for details).
COPY entrypoint.sh /usr/local/bin/carrel-entrypoint
RUN chmod +x /usr/local/bin/carrel-entrypoint

# Non-root user. uid 1000 matches the typical host user so bind-mounted files
# keep sane ownership. safe.directory '*' stops Git complaining about repos
# owned by a different uid.
RUN useradd --create-home --shell /bin/bash --uid 1000 claude \
    && git config --system --add safe.directory '*' \
    && mkdir -p /workspace /home/claude/.claude \
        /home/claude/.local/bin /home/claude/.local/share/claude \
    && chown -R claude:claude /workspace /home/claude

USER claude
WORKDIR /home/claude

ENV NVM_DIR=/home/claude/.nvm
# Claude's binaries live in ~/.local/share/claude (a persistent volume at
# runtime); ~/.local/bin holds its launcher symlink, which is on PATH.
ENV PATH=/home/claude/.local/bin:$PATH

SHELL ["/bin/bash", "-c"]

# nvm only — no Node version baked in. Pre-create the versions dir (owned by
# claude) so the cache volume mounted there inherits the right ownership.
RUN curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash \
    && mkdir -p "$NVM_DIR/versions/node" \
    # Interactive shells should adopt whatever version the entrypoint provisioned
    # (the default alias). Silent + no-op when the project isn't a Node project.
    && echo 'nvm use default --silent >/dev/null 2>&1 || true' >> /home/claude/.bashrc

# Claude itself is NOT installed here. The entrypoint installs it into
# ~/.local/share/claude (a named volume) on first launch, so it's shared across
# variants and self-updates between runs.

WORKDIR /workspace
ENTRYPOINT ["carrel-entrypoint"]
CMD ["claude"]

# =============================================================================
# rust
# =============================================================================
FROM base AS rust

ARG RUST_TOOLCHAIN=stable

ENV RUSTUP_HOME=/home/claude/.rustup \
    CARGO_HOME=/home/claude/.cargo
ENV PATH=/home/claude/.cargo/bin:$PATH

# Most crates need a C toolchain + headers to build native deps.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*
USER claude

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN" \
    # clippy + rustfmt cover lint/format (Claude runs these). rust-analyzer is
    # omitted on purpose: it's a ~180MB LSP server, and Claude navigates code via
    # ripgrep/file reads rather than a language server. Add it back if a human
    # will also use this image in an editor.
    && rustup component add clippy rustfmt

# =============================================================================
# tauri  — Rust + web toolchain + desktop build deps
# =============================================================================
FROM rust AS tauri

# Tauri v2 Linux system dependencies.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        libwebkit2gtk-4.1-dev \
        libgtk-3-dev \
        libayatana-appindicator3-dev \
        librsvg2-dev \
        libxdo-dev \
        file \
        wget \
    && rm -rf /var/lib/apt/lists/*
USER claude

# The Tauri CLI. The frontend package manager (yarn/pnpm) is provided lazily by
# the entrypoint's corepack, same as any Node project. Drop cargo's registry
# cache afterwards — it's build-time only and ~300MB.
RUN cargo install tauri-cli --locked \
    && rm -rf "$CARGO_HOME/registry" "$CARGO_HOME/git"
