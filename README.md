# carrel

Sandboxed Docker images for running [Claude Code](https://code.claude.com) against
your projects, with the right toolchain baked in per language. Run an isolated
Claude in any project directory without installing it — or its toolchains — on
your host.

A *carrel* is a private study cubicle in a library — one enclosed desk per piece
of work. That's the idea: a disposable, isolated workspace per project.

## Quick start

**Requirements.** `docker`, `git`, `jq`, and bash on the host. (`rsync` is used
if present, but isn't required.)

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
carrel opencode [variant] [args...]  run opencode instead of Claude
carrel config get|set …              read and write settings
carrel trust                         review and trust this repo's .carrel.json
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

| Run            | For                        | Includes                                                    | Size   |
| -------------- | -------------------------- | ----------------------------------------------------------- | ------ |
| `carrel`       | General use + JS/TS        | ripgrep, fd, fzf, jq, tree, git, gh, glab, nvm (+ corepack) | ~260MB |
| `carrel rust`  | Rust                       | base + rustup, clippy, rustfmt                              | ~1.1GB |
| `carrel tauri` | Tauri desktop apps         | rust + web build deps (webkit, gtk) + tauri-cli             | ~2.1GB |

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
- in a git worktree, the main checkout's `.git` directory → mounted at its real
  host path (read-write), since the worktree's history lives there
- a named `carrel-claude` volume → the Claude binary (`~/.local/share/claude`)
- a named `carrel-node` volume → cached Node versions
- for [opencode](#opencode): `~/.carrel/opencode/{config,data,state}` → its
  `~/.config`, `~/.local/share` and `~/.local/state` dirs, plus the
  `carrel-opencode` (binary) and `carrel-opencode-cache` volumes
- anything you opt into via [extra mounts](#extra-mounts) (ssh key, caches, …)
  or the [clipboard](#clipboard--image-paste) and [ssh agent](#ssh-agent--git-over-ssh)
  flags

> **Worktrees.** Inside the container, git can see your other worktrees but not
> their folders, so it treats them as deleted. Avoid `git worktree prune` in
> there: it removes their records (including anything staged in them). `git gc`
> can prune too, but only worktrees missing for longer than
> `gc.worktreePruneExpire` (3 months by default).

Goals:

- **Isolation by default.** Claude and every language toolchain live in the
  container, not on your machine. Delete the image and it's gone.
- **Minimal footprint, maximum reach.** A small Debian-slim base carries only
  the tools Claude needs to navigate code, plus the `gh`/`glab` CLIs so it can
  view and open PRs/MRs. Neither Claude nor Node is baked in — both are
  installed on first launch into volumes (see below). Heavier toolchains are
  opt-in variants layered on top.
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

### opencode

`carrel opencode [variant] [args...]` runs [opencode](https://opencode.ai)
instead of Claude, in the same image and with the same mounts. It's installed
into the `carrel-opencode` volume on first launch (Claude isn't installed unless
you run it), and upgrades itself in place via opencode's built-in autoupdate,
which the volume makes stick. `carrel shell` installs both.

opencode has its own login, saved in `~/.carrel/opencode/data`, and its sessions
live there too. No opencode config is synced from the host, but opencode falls
back to `~/.claude/CLAUDE.md` and `~/.claude/skills`, so the synced Claude
config carries over.

## Configuration & sessions

### Settings

Everything carrel does is driven by seven keys, read from JSON config files and
managed with `carrel config`:

| Key         | Type   | Default        | What it does                            |
| ----------- | ------ | -------------- | --------------------------------------- |
| `variant`   | string | `base`         | image to run when you don't name one    |
| `image`     | string | `carrel`       | image name / tag prefix                 |
| `tz`        | string | the host's     | container timezone                      |
| `clipboard` | bool   | `false`        | forward the host's Wayland clipboard    |
| `ssh_agent` | string | `off`          | forward an ssh-agent: `host`/`carrel`   |
| `mounts`    | list   | `[]`           | extra host items to pass in             |
| `sync`      | list   | see below      | what's mirrored from your `~/.claude`   |

```bash
carrel config get                       # every effective setting
carrel config get variant               # just one
carrel config get --show-origin         # …and which file each came from

carrel config set variant rust          # global default
carrel config set --project variant rust   # …for this project only
carrel config set --repo variant rust      # …in the repo's shared .carrel.json
carrel config add mounts ~/.gitconfig:/home/claude/.gitconfig   # append to a list
carrel config unset --project variant
carrel config path --project            # the file set/add would write
```

Every setting also has a flag that overrides it for a single run:

```bash
carrel --image carrel-fork rust         # image
carrel --tz UTC                         # tz
carrel --clipboard                      # clipboard on (--no-clipboard for off)
carrel --ssh-agent carrel               # ssh agent on (--no-ssh-agent for off)
carrel -m ~/.aws:/home/claude/.aws      # add a mount (repeatable)
carrel --dry-run                        # print the docker command, don't run it
```

`--dry-run` is the quickest way to see what your config actually resolves to.

### Where settings come from

Four layers, highest precedence first:

| Layer                                  | Scope                                     |
| -------------------------------------- | ----------------------------------------- |
| the flags above                        | one run                                   |
| `~/.carrel/projects/<slug>.json`       | **your** settings for one project         |
| `<project root>/.carrel.json`          | the **repo's** settings, once trusted     |
| `~/.carrel/config.json`                | your global defaults                      |

Scalars override — the nearest layer that sets `variant` wins. Lists
**accumulate**: a repo's `mounts` are added to yours, not swapped for them. (The
built-in defaults are the exception: they only fill in keys no file sets, so
setting `sync` replaces the default list rather than extending it.)

The **project root** is the enclosing git repo, falling back to the working
directory, so `carrel` behaves the same from any subdirectory. `<slug>` is that
path with slashes turned to dashes — the same scheme Claude uses for session
directories. Your per-project file lives *beside* `~/.carrel/claude`, not inside
it, so it's never visible to the agent.

```
$ carrel config get --show-origin
  clipboard  true                                 /home/you/.carrel/projects/-home-you-api.json
  image      carrel                               (default)
  mounts     ~/.gitconfig:/home/claude/.gitconfig /home/you/.carrel/config.json
  mounts     carrel-pnpm:/home/claude/…:rw        /home/you/api/.carrel.json
  variant    rust                                 /home/you/api/.carrel.json
```

### Repo configs: trust, and what they can't do

A `.carrel.json` committed at a project's root lets a repo ship the setup its
work actually needs — the right variant, a persistent package-manager volume, a
fixtures directory — so a teammate gets it on clone with nothing to configure.

But it arrives *with the code*, including from a repo you've only just cloned
and haven't read. So carrel won't use it until you've seen it. The first time
you launch in the project, and again whenever the file changes, carrel lists
what it asks for and waits for a yes:

```
$ carrel
carrel: /home/you/api/.carrel.json hasn't been reviewed yet. It asks for:
    variant   rust
    mount     volume carrel-pnpm -> /home/claude/.local/share/pnpm (read-write)
    mount     /home/you/api/fixtures -> /opt/fixtures (read-only)
carrel: trust it and continue? [y/N]
```

Read the mount targets closely. A mount can land anywhere in the container,
including over tools the agent runs (`/home/claude/.local/bin` holds `claude`
itself), and it's there before the agent starts.

Answering no, or running without a terminal (`carrel -p …` from a script, say),
launches without the repo config and prints a warning. `carrel trust` shows the
same list and records your answer ahead of time. Trust is tied to the file's
exact contents and stored in `~/.carrel/projects/<slug>.trusted`; delete that
file to revoke it.

Even once trusted, a repo config is restricted to what's inherently the
project's own:

| From a repo config             | Result                                          |
| ------------------------------ | ----------------------------------------------- |
| `variant`, `image`, `tz`       | honoured                                        |
| `mounts` — a named volume      | honoured (`carrel-pnpm:/home/claude/…:rw`)      |
| `mounts` — a path in the project | honoured (`./fixtures:/opt/fixtures`)         |
| `mounts` — anything else       | **skipped**, with a warning                     |
| `clipboard: false`             | honoured                                        |
| `clipboard: true`              | **ignored**, with a warning                     |
| `ssh_agent: "off"`             | honoured                                        |
| `ssh_agent: "host"`/`"carrel"` | **ignored**, with a warning                     |
| `sync`                         | **ignored**, with a warning                     |

`~` and `$VAR` are refused outright, and both sides of the "inside the project"
test go through `realpath`, so a symlink planted in the repo can't point out of
it. Everything a repo can't grant, you can — the warning tells you how:

```
$ carrel
carrel: skipping mount '~/.aws:/home/claude/.aws' in /home/you/api/.carrel.json
        (outside the project); add it with
        'carrel config add --project mounts ~/.aws:/home/claude/.aws'
```

To write a repo config, edit `.carrel.json` directly or use `--repo`, which
works like `--project` but targets the shared file:

```bash
carrel config set --repo variant rust
carrel config add --repo mounts ./fixtures:/opt/fixtures
```

`--repo` refuses anything a repo config can't grant (and points you at
`--project` instead), so it never writes a setting that would just be ignored.
Since you made the edit yourself, a file you'd already trusted, or a new one,
stays trusted. A file you hadn't trusted yet stays untrusted until you review
it with `carrel trust`.

A typical repo config, with a shared pnpm store (a named volume, seeded empty)
and a fixtures directory from the repo:

```json
{
  "variant": "rust",
  "mounts": [
    "carrel-pnpm:/home/claude/.local/share/pnpm:rw",
    "./fixtures:/opt/fixtures"
  ]
}
```

### Extra mounts

By default only the project directory crosses into the container. Some work
needs a few host-side items from *outside* the project - your SSH
`known_hosts`, your `~/.gitconfig`, or a warm package-manager cache. That's the
`mounts` key:

```bash
carrel config add mounts ~/.gitconfig:/home/claude/.gitconfig  # everywhere
carrel config add --project mounts ~/.aws:/home/claude/.aws    # this project
carrel -m ~/.aws:/home/claude/.aws rust                        # just this run
```

Each spec is `HOST[:CONTAINER][:ro|:rw]`:

- `HOST` — a host path (leading `~` and `$VARs` are expanded; `./` and `../`
  resolve against the project root) **or** a Docker named volume (anything else,
  e.g. `carrel-pnpm`).
- `CONTAINER` — where it lands inside the container. Optional for host paths
  (defaults to the same absolute path, like the project mount); **required** for
  named volumes. Home-relative items must set this: the container runs as
  `claude`, so `~` there is `/home/claude`, not your host home.
- `:ro` / `:rw` — access mode, **read-only by default**. An autonomous agent runs
  in the container, so writes are opt-in per mount.

Good candidates for `~/.carrel/config.json`: `~/.ssh/known_hosts` for git over
SSH (see [ssh agent](#ssh-agent--git-over-ssh) for the key), `~/.gitconfig` for
your name and aliases, `~/.config/gh` and `~/.config/glab-cli` for `gh`/`glab`
logins, and named volumes for persistent pnpm and yarn caches:

```json
{
  "mounts": [
    "~/.ssh/known_hosts:/etc/ssh/ssh_known_hosts",
    "~/.gitconfig:/home/claude/.gitconfig",
    "~/.config/gh:/home/claude/.config/gh",
    "~/.config/glab-cli:/home/claude/.config/glab-cli",
    "carrel-pnpm:/home/claude/.local/share/pnpm:rw",
    "carrel-yarn:/home/claude/.cache/yarn:rw"
  ]
}
```

> The `gh`/`glab` CLIs are in the image, but the container has its own isolated
> home, so it won't pick up your host login. Mount the config dirs above (or set
> a token another way) to let the agent act on your PRs/MRs. Read-only is enough
> for token auth; grant `:rw` only if you want the container to refresh it.

A volume spec with no container path, or a host path that doesn't exist, is
skipped with a warning rather than launching a broken container.

> **Keep it tight.** Every extra mount widens what the container — and the agent
> inside it — can touch. Mount secrets read-only, mount the narrowest path that
> works, and prefer isolated named volumes (`carrel-pnpm`, seeded empty and
> persisted across runs) over bind-mounting your real host cache dir.

### carrel's config directory

carrel keeps its **own** config directory on the host — `~/.carrel` — bind-mounted
to `~/.claude` inside the container. It is deliberately separate from your real
`~/.claude` so the container can never write back to the config your host Claude
uses.

```
~/.carrel/
├── config.json             your global defaults        ← carrel config set
├── projects/
│   └── <slug>.json         your per-project settings   ← carrel config set --project
├── claude/                 →  ~/.claude in the container
│   ├── CLAUDE.md           synced from your real ~/.claude (overwritten each run)
│   ├── settings.json       synced from your real ~/.claude (overwritten each run)
│   ├── statusline-command.sh   ditto — the status line script settings.json runs
│   ├── .credentials.json   carrel's own login (created on first auth, persists)
│   └── projects/           session history, per project ← analyze these
└── claude.json             →  ~/.claude.json in the container
```

Set `CARREL_HOME` to move all of it. That's the one setting that stays an
environment variable, because it's what locates the config in the first place.

**Sync is one-way: host → carrel.** On every `carrel` launch (and `carrel sync`),
the files named by the `sync` key are mirrored from your real `~/.claude` into
`~/.carrel/claude` with `rsync -aL` — symlinks (e.g. dotfiles) are dereferenced,
only changed files are copied, and each change is printed. The default list:

```
CLAUDE.md  skills  agents  output-styles  statusline-command.sh  notify.sh
```

`settings.json` is always synced on top of that, and is the one file that isn't
copied verbatim. Commands it runs — `statusLine`, hooks — refer to scripts by
their **host** path under `~/.claude`, which is mounted at `/home/claude/.claude`
in the container, so those paths are rewritten on the way in. (`~` and `$HOME`
need no rewriting; they already point at the right place inside.) Anything else
in the file is passed through untouched, including hooks that shell out to
host-only tools — a `notify-send`/`paplay` hook, say, simply fails inside the
container.

`--delete` is applied **per synced directory**, so removing a file from
`~/.claude/agents/` removes it from carrel too — but it never touches anything
outside the list. The one exception inside the list is `skills/synced`, where
Claude Code in the container downloads your claude.ai account skills: it's
neither copied from the host nor deleted. Credentials and session history are
never synced: the container logs in on its own and keeps its sessions to itself.

```bash
carrel config set sync CLAUDE.md skills agents   # narrow it
carrel config add sync .credentials.json         # reuse your host login…
```

> Adding `.credentials.json` hands the container your real Claude token. It'll
> then act as you rather than as carrel's own login.

> No rsync on the host? `carrel` falls back to a `cp -RL` full replace — still
> correct, just without change detection or per-file output.

> Because these files are overwritten each run, host is the source of truth for
> them — if the container edits its `settings.json`, the change lives only in
> `~/.carrel` and is replaced on the next sync.

### Clipboard & image paste

Text pastes into a containerised Claude just fine — that's the terminal handing
over characters. Images don't, because a terminal only ever sends text. When you
press <kbd>Ctrl</kbd>+<kbd>V</kbd>, Claude reads the clipboard *itself*, shelling
out to `wl-paste`/`xclip`. Inside a container there's no display server to ask,
so nothing arrives.

The `clipboard` setting fixes that by binding the host's Wayland socket into
the container:

```bash
carrel --clipboard                        # this run only
carrel --clipboard rust -c                # alongside a variant and claude args
carrel config set --project clipboard true   # standing, for this project
carrel config set clipboard true          # standing, everywhere
carrel --no-clipboard                     # opt back out for one run
```

It's **off by default on purpose.** The socket is a live line to your session
for as long as the container runs: the agent can read anything you copy —
passwords, tokens, whatever was in the buffer — and overwrite it. That's a real
widening of the boundary, so it's yours to grant — a repo's `.carrel.json` can
turn it off but never on.

Requirements:

- **A Wayland session.** Without `WAYLAND_DISPLAY`, carrel warns and launches
  normally. X11 sessions aren't supported: forwarding an X socket would let the
  container read every keystroke and window in your session, not just the
  clipboard.
- **A compositor with a clipboard-manager protocol** (`wlr-data-control` or
  `ext-data-control`). wlroots (Hyprland, sway), KWin, and Mutter 48+ have one.
  Older GNOME — including **Ubuntu 24.04 LTS** — doesn't hand the clipboard to
  Wayland clients at all, so there's nothing to forward.

Quick check: if `wl-paste -l` lists an `image/png` line on the host after you
copy an image, it'll work in the container too.

> **macOS isn't supported.** Docker runs inside a Linux VM there, and macOS
> keeps its clipboard behind `pbpaste`/`osascript` on the host side of that
> boundary — there's no socket to forward. Save the image to a file under the
> project instead and hand Claude the path; it reads image files directly.

`wl-clipboard` ships in the base image, so `--clipboard` needs no rebuild beyond
picking up a current image. The socket is the *only* thing forwarded — no
`XDG_RUNTIME_DIR`, no other host runtime state.

### SSH agent & git over SSH

Pushing over SSH needs two things: a key to sign in with, and a list of
trusted server keys so ssh can tell it's talking to the real server.

**The key: forward an ssh-agent.** Don't mount `~/.ssh`: that hands the agent
your private keys to read or copy. The `ssh_agent` setting binds an ssh-agent
socket into the container instead, so the key stays on the host and the
container can only ask the agent to sign. While the container runs, it can use
*every* key that agent holds, against *any* server it can reach, so pick which
agent it gets:

| Mode     | Agent forwarded                  | Keys the container can use       |
| -------- | -------------------------------- | -------------------------------- |
| `off`    | none (the default)               | none                             |
| `host`   | yours (`SSH_AUTH_SOCK`)          | every key you've loaded          |
| `carrel` | one carrel runs for this session | only the keys in `~/.carrel/ssh` |

```bash
carrel --ssh-agent carrel                     # this run only
carrel config set --project ssh_agent host    # standing, for this project
carrel config set ssh_agent carrel            # standing, everywhere
carrel --no-ssh-agent                         # opt back out for one run
```

A repo's `.carrel.json` can turn it off but never on.

**`carrel` mode** keeps the agent's git access separate from yours. Give it its
own key, then register the public key with only the access you want it to
have, e.g. as a deploy key with write access on specific repos (GitLab lets one
deploy key cover several projects; GitHub needs one per repo):

```bash
ssh-keygen -t ed25519 -C carrel -f ~/.carrel/ssh/id_ed25519
cat ~/.carrel/ssh/id_ed25519.pub              # add this to GitLab / GitHub
```

Each launch starts a fresh agent and loads every `id_*` private key in
`~/.carrel/ssh` into it, asking for any passphrase on the terminal. If a key
won't load, carrel stops rather than launching without it. The agent runs the
session itself and exits shortly after it ends, even if carrel is killed, so
nothing a session does to its agent (such as locking it or swapping keys)
carries over to the next one. The agent also refuses to load PKCS#11 libraries
(`ssh-agent -P none`), so the container can't make it load code on the host.

The key file stays out of the container's reach: carrel doesn't mount
`~/.carrel/ssh`, and if the project or one of your extra mounts contains it
(such as running carrel from your home folder), carrel mounts an empty folder
over it. Mounting anything from inside `~/.carrel/ssh` is refused. Pushes
signed with the key are easy to spot, and you can revoke it without touching
your own key.

**`host` mode** is the quick option: it reuses whatever your own agent holds.
It's also your real agent, so anything the container does to it (removing,
adding or locking keys) stays after the session ends.
To narrow it, limit where each key works when you load it (OpenSSH 8.9+):

```bash
ssh-add -h github.com -h gitlab.com ~/.ssh/id_ed25519
```

A key loaded this way only signs in to the listed hosts, from the container or
anywhere else. carrel doesn't control how your own agent was started: unless it
was started with `ssh-agent -P none`, the container can ask it to load PKCS#11
libraries from the host's `/usr/lib`. Use `carrel` mode if that matters to you.

**Server keys: share your host's `known_hosts`, read-only.** Mount it as the
container's system-wide known-hosts file:

```bash
carrel config add mounts ~/.ssh/known_hosts:/etc/ssh/ssh_known_hosts
```

Servers you've already trusted on the host are trusted in the container, and
the agent can't add or change entries. An unknown server fails rather than
being trusted on first sight: connect to it once on the host
(`ssh -T git@newhost`) and it works in carrel from then on.

Requirements:

- **Linux:** `host` mode needs a running ssh-agent with `SSH_AUTH_SOCK` set;
  `carrel` mode needs `ssh-agent` installed. If the agent can't be reached,
  carrel warns and launches without it.
- **Your host user is uid 1000.** ssh-agent only answers processes running as
  its own user, and the container runs as uid 1000. Rootless Docker, Podman and
  `userns-remap` map that uid to a different host user, so the agent refuses
  the container.
- **Docker runs natively.** Docker Desktop on Linux runs containers in a VM that
  can't reach sockets on the host, so neither mode works there.
- **macOS:** `host` mode uses Docker Desktop's forwarded agent at
  `/run/host-services/ssh-auth.sock`. `carrel` mode isn't supported, as Docker
  Desktop can only forward your own agent.

### Timezone

The Debian base image runs on UTC. Left alone, every timestamp inside the
container is offset from the clock you're reading: git commit dates, file
mtimes, and the status line's usage-reset time all disagree with the host.

So `carrel` passes the host's timezone in as `TZ` on each launch, reading (in
order) the `tz` setting, `$TZ`, `/etc/timezone`, then the `/etc/localtime`
symlink. That covers Debian-style, systemd, and macOS hosts. Set `tz` to pin a
different zone:

```bash
carrel --tz UTC                       # keep this run on UTC
carrel config set tz Europe/Berlin    # or anywhere else, standing
```

If none of the sources resolve, no `TZ` is set and the container stays on UTC as
before.

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

## Incus VMs (experimental)

`carrel-vm` runs the same setup in a throwaway [Incus](https://linuxcontainers.org/incus/)
virtual machine instead of a Docker container. A container shares your
kernel, so a kernel bug is a way out; a VM has its own kernel behind a
hypervisor, which is a much harder wall to get through.

```bash
carrel-vm build                 # build carrel-base, -rust, -tauri VM images
ln -s "$PWD/bin/carrel-vm" ~/.local/bin/carrel-vm
carrel-vm rust                  # one fresh VM per session, deleted on exit
```

It shares carrel's config files, trust prompts, `~/.carrel` directory and
entrypoint, and puts everything at the same paths inside the VM. `config`,
`trust`, `sync` and `sessions` are passed straight to `carrel`.

Differences from the Docker launcher:

- **One VM per session.** Each launch boots a fresh ephemeral VM (a few
  seconds) and Incus deletes it when it stops. Size it with `--cpus` /
  `--memory`.
- **Volumes** (`carrel-claude`, `carrel-node`, …) are Incus storage volumes in
  the `default` pool (`CARREL_INCUS_POOL` to change it).
- **Single-file mounts are copied in**, since VMs can only share directories.
  Edits to them stay in the VM.
- **No clipboard or ssh-agent forwarding.** Incus can't forward Unix sockets
  into a VM. For git over SSH, give the VMs keys of their own instead (below).
- **Claude's `~/.claude.json`** lives in `~/.carrel/claude/.claude.json`
  (seeded once from `~/.carrel/claude.json`), so the two launchers keep
  separate onboarding state but share the login.

**SSH keys.** If `~/.carrel/vm-ssh` exists, every VM gets it read-only as
`~/.ssh`. Unlike `carrel` mode's agent, the private key is in the VM, where the
agent can read or copy it, so treat it as the agent's key: register it with
only the access you'd give the agent, e.g. a deploy key on specific repos.

```bash
mkdir -p ~/.carrel/vm-ssh
ssh-keygen -t ed25519 -C carrel-vm -N '' -f ~/.carrel/vm-ssh/id_ed25519
ssh-keyscan github.com gitlab.com > ~/.carrel/vm-ssh/known_hosts
cat ~/.carrel/vm-ssh/id_ed25519.pub        # add this to GitLab / GitHub
```

`~/.carrel/ssh` (the keys for `carrel` mode) is never shared with a VM. It's
covered with an empty folder if a share would carry it in.

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
  --build-arg GLAB_VERSION=1.108.0 \
  -t carrel:base .

docker build --target rust \
  --build-arg RUST_TOOLCHAIN=1.84.0 \
  -t carrel:rust .
```

> `gh` self-updates via apt and needs no pin; `glab` has no first-party apt
> repo, so its release `.deb` is version-pinned by `GLAB_VERSION`. Bump it to
> upgrade glab.

## Make targets

| Target                   | Does                                              |
| ------------------------ | ------------------------------------------------- |
| `make all`               | Build every variant and list the resulting tags   |
| `make base\|rust\|tauri` | Build a single variant                            |
| `make run [TAG=…]`       | Sync config, then run Claude in `$PWD`             |
| `make shell [TAG=…]`     | Same, but launch `bash` instead of `claude`        |
| `make sync`              | Push host config into carrel's dir (also auto-run) |
| `make sessions`          | Print where session transcripts live               |
| `make test`              | Run the config-layering tests (no Docker needed)   |

Useful overrides: `IMAGE` (image name, default `carrel`), `TAG` (variant,
default `base`), `ARGS` (extra args for `claude`, e.g. `--resume <id>`),
`CARREL_HOME` (carrel's config dir, default `~/.carrel`). Everything else is a
[setting](#settings).

## Contributing

- **Adding a tool to every variant?** Put it in the `base` stage's apt list.
  Keep `base` lean — language toolchains belong in their own stage.
- **Adding a variant?** Add a `FROM base AS <name>` (or `FROM rust …`) stage,
  then append the name to `VARIANTS` in `bin/carrel` (the `Makefile` reads it
  from there).
- Keep system packages installed with `--no-install-recommends` and clean
  `/var/lib/apt/lists` in the same `RUN` to avoid bloating layers.
- **Run/mount logic lives in `bin/carrel`** — the `Makefile` delegates to it, so
  change it in one place. The `Dockerfile` defines the images; `bin/carrel`
  defines how they're run.
- **Adding a setting?** Add it to `CONFIG_KEYS`, `config_type`, and
  `DEFAULT_CONFIG` in `bin/carrel`, then decide whether a repo's `.carrel.json`
  may set it — `read_repo_config` is where that's enforced.
- Run `make test` before opening a PR, and `make all` to confirm every variant
  still builds.

## Trademark

Claude and Claude Code are trademarks of Anthropic, PBC. `carrel` is an
independent, unofficial project and is not affiliated with, sponsored by, or
endorsed by Anthropic. "Claude Code" is referenced only to describe what this
project runs. You are responsible for complying with Anthropic's terms of
service and for providing your own Claude access.
