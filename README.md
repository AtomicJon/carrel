# carrel

Sandboxed Docker images for running [Claude Code](https://code.claude.com) against
your projects, with the right toolchain baked in per language. Run an isolated
Claude in any project directory without installing it — or its toolchains — on
your host.

A *carrel* is a private study cubicle in a library — one enclosed desk per piece
of work. That's the idea: a disposable, isolated workspace per project.

## Quick start

**One-time setup.** Build the images and put the `carrel` launcher on your `PATH`:

```bash
make all                                      # build carrel:base, :rust, :tauri
ln -s "$PWD/bin/carrel" ~/.local/bin/carrel   # symlink so `git pull` keeps it current
```

`carrel` is a plain script — no shell function or rc edits, and it behaves the
same in bash, zsh, or fish. Just make sure `~/.local/bin` is on your `PATH`.

```
carrel [variant] [claude args...]    run Claude (variant: base|rust|tauri)
carrel shell [variant]               open a shell instead of Claude
carrel sessions                      print this project's session directory
carrel --help                        full usage
```

**Daily use.** From any project, just launch it:

```bash
cd ~/projects/my-api
carrel rust           # Claude opens in this repo, with rust tooling, isolated
```

The project is mounted at its **real host path** (so Claude's file paths and
session history match what you'd see natively). Claude runs against `carrel`'s
own config dir — `~/.carrel` — not your real `~/.claude`; your `CLAUDE.md` and
settings are copied in on each launch, but anything the container writes stays in
`~/.carrel`. Each run is throwaway (`--rm`) — nothing Claude installs leaks back
onto your machine. See [Configuration](#configuration--sessions) for the full
model.

> The very first launch downloads Claude (and, for a Node project, Node) into
> the `carrel-claude` / `carrel-node` volumes. That's a one-time cost; later
> runs reuse the cache, and Claude keeps itself up to date in the background.

Pick the variant that matches the project:

| Run            | For                        | Includes                                          | Size   |
| -------------- | -------------------------- | ------------------------------------------------- | ------ |
| `carrel`       | General use + JS/TS        | ripgrep, fd, fzf, jq, tree, git, nvm (+ corepack) | ~210MB |
| `carrel rust`  | Rust                       | base + rustup, clippy, rustfmt                    | ~1.0GB |
| `carrel tauri` | Tauri desktop apps         | rust + web build deps (webkit, gtk) + tauri-cli   | ~2.1GB |

> Sizes are the images. Claude itself (~250MB) and Node live in shared volumes,
> not the images.

> First launch prompts you to log in (carrel has its own login, separate from
> your host's); the credential is saved in `~/.carrel` and reused afterwards.

Working inside the repo and haven't symlinked it yet? `make run TAG=rust` (and
`make shell`, `make sync`, `make sessions`) call the same launcher.

## About

`carrel` packages Claude Code as a disposable container so it can read, search,
and modify a project without touching your host environment. Each run is
`--rm` (throwaway); only what's needed crosses the boundary:

- `~/.carrel/claude` → `~/.claude` — carrel's own config + session history
- `~/.carrel/claude.json` → `~/.claude.json` — carrel's onboarding/config state
- the project directory → mounted at its real host path
- a named `carrel-claude` volume → the Claude binary (`~/.local/share/claude`)
- a named `carrel-node` volume → cached Node versions

Goals:

- **Isolation by default.** Claude and every language toolchain live in the
  container, not on your machine. Delete the image and it's gone.
- **Minimal footprint, maximum reach.** A small Debian-slim base carries only
  the tools Claude needs to navigate code. Neither Claude nor Node is baked in —
  both are installed on first launch into volumes (see below). Heavier
  toolchains are opt-in variants layered on top.
- **Always-current Claude.** Claude is installed via its native standalone
  binary (no Node dependency, ripgrep bundled) into a persistent volume shared
  by every variant, so its background auto-updater keeps it fresh between runs —
  no rebuild needed.

Claude runs as a non-root user (uid 1000) so bind-mounted files keep sane
ownership on the host.

### Lazy Node provisioning

The image ships `nvm` but **no Node**. On launch the entrypoint checks the
mounted project:

- No `package.json` / `.nvmrc` → nothing happens (e.g. a pure-Rust repo never
  pulls Node).
- `.nvmrc` or `.node-version` present → that exact version is installed.
- `package.json` with no pin → the latest LTS is installed.

`corepack` is then enabled so `yarn`/`pnpm` follow the project's
`packageManager` field. Downloaded versions are cached in the `carrel-node`
volume, so it's a one-time install per version rather than per run. This is why
there's no separate "web" image — `base` handles JS/TS projects directly.

Claude is bootstrapped the same way: the entrypoint installs it into the
`carrel-claude` volume on first launch if it's missing, then leaves Claude's own
auto-updater to keep it current.

> Switch versions inside a running container with `nvm install <version>`.

## Configuration & sessions

carrel keeps its **own** config directory on the host — `~/.carrel` — bind-mounted
to `~/.claude` inside the container. It is deliberately separate from your real
`~/.claude` so the container can never write back to the config your host Claude
uses.

```
~/.carrel/
├── claude/                 →  ~/.claude in the container
│   ├── CLAUDE.md           synced from your real ~/.claude (overwritten each run)
│   ├── settings.json       synced from your real ~/.claude (overwritten each run)
│   ├── .credentials.json   carrel's own login (created on first auth, persists)
│   └── projects/           session history, per project ← analyze these
└── claude.json             →  ~/.claude.json in the container
```

**Sync is one-way: host → carrel.** On every `carrel` launch (and `carrel sync`),
a whitelist of files is mirrored from your real `~/.claude` into `~/.carrel/claude`
with `rsync -aL` — symlinks (e.g. dotfiles) are dereferenced, only changed files
are copied, and each change is printed. The whitelist is:

```
CLAUDE.md  settings.json  commands  agents  output-styles
```

`--delete` is applied **per whitelisted directory**, so removing a file from
`~/.claude/commands/` removes it from carrel too — but it never touches anything
outside the whitelist. Credentials and session history are never synced: the
container logs in on its own and keeps its sessions to itself. Edit `SYNC_ITEMS`
in `bin/carrel` to change what's pulled in; add `.credentials.json` there if you'd
rather reuse your host login (note: the container can then use that token).

> No rsync on the host? `carrel` falls back to a `cp -RL` full replace — still
> correct, just without change detection or per-file output.

> Because the whitelist is overwritten each run, host is the source of truth for
> those files — if the container edits its `settings.json`, the change lives only
> in `~/.carrel` and is replaced on the next sync.

### Analyzing sessions

Because each project mounts at its **real host path**, Claude stores session
transcripts exactly where a native run would, just rooted in carrel's config dir:

```
~/.carrel/claude/projects/<your-project-path-with-slashes-as-dashes>/*.jsonl
```

So a project at `/home/you/projects/my-api` lands in
`~/.carrel/claude/projects/-home-you-projects-my-api/`. `make sessions` prints the
base path. These are plain JSONL transcripts — point your analysis tooling
straight at them on the host; no need to enter the container.

### Resuming sessions

`carrel` passes any args after the (optional) variant straight to `claude`, so
Claude's session flags work as-is. Because projects mount at their real path, the
session IDs are the same ones a native run would use:

```bash
carrel --resume                 # interactive picker for this project's sessions
carrel --resume <session-id>    # resume a specific session
carrel -c                       # continue the most recent session here
carrel rust --resume <id>       # ...on the rust image
```

Session IDs are the `*.jsonl` filenames under the project's sessions directory
(`make sessions` prints the base path), or just use the picker. The same
pass-through covers other flags too — `carrel -p "..."`, `carrel --model …`, etc.
With `make`: `make run ARGS="--resume <id>"`.

## Building

Everything is one multi-target `Dockerfile`. Build a single variant by
targeting its stage:

```bash
make base      # or: docker build --target base -t carrel:base .
make rust
make tauri
```

BuildKit builds only the targeted stage and its ancestors, so `make rust`
builds `base` then `rust`, and nothing else.

### Variant layering

```
base ── rust ── tauri
```

### Pinning versions

Toolchain versions are build args with defaults in the `Dockerfile`. Override
at build time:

```bash
docker build --target base \
  --build-arg NVM_VERSION=v0.40.1 \
  -t carrel:base .

docker build --target rust \
  --build-arg RUST_TOOLCHAIN=1.84.0 \
  -t carrel:rust .
```

## Make targets

| Target                   | Does                                              |
| ------------------------ | ------------------------------------------------- |
| `make all`               | Build every variant and list the resulting tags   |
| `make base\|rust\|tauri` | Build a single variant                            |
| `make run [TAG=…]`       | Sync config, then run Claude in `$PWD`             |
| `make shell [TAG=…]`     | Same, but launch `bash` instead of `claude`        |
| `make sync`              | Push host config into carrel's dir (also auto-run) |
| `make sessions`          | Print where session transcripts live               |

Useful overrides: `IMAGE` (image name, default `carrel`), `TAG` (variant,
default `base`), `ARGS` (extra args for `claude`, e.g. `--resume <id>`),
`WORKDIR` (project dir, default the current directory), `CARREL_HOME` (carrel's
config dir, default `~/.carrel`).

## Contributing

- **Adding a tool to every variant?** Put it in the `base` stage's apt list.
  Keep `base` lean — language toolchains belong in their own stage.
- **Adding a variant?** Add a `FROM base AS <name>` (or `FROM rust …`) stage,
  then append the name to `VARIANTS` in the `Makefile`.
- Keep system packages installed with `--no-install-recommends` and clean
  `/var/lib/apt/lists` in the same `RUN` to avoid bloating layers.
- **Run/mount logic lives in `bin/carrel`** — the `Makefile` delegates to it, so
  change it in one place. The `Dockerfile` defines the images; `bin/carrel`
  defines how they're run.
- Run `make all` before opening a PR to confirm every variant still builds.

## Trademark

Claude and Claude Code are trademarks of Anthropic, PBC. `carrel` is an
independent, unofficial project and is not affiliated with, sponsored by, or
endorsed by Anthropic. "Claude Code" is referenced only to describe what this
project runs. You are responsible for complying with Anthropic's terms of
service and for providing your own Claude access.
