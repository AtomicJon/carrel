#!/usr/bin/env bash
#
# Tests for carrel's config layering. No Docker needed: `carrel --dry-run`
# prints the command it would run, so every launch-affecting setting is
# observable without starting a container.
#
#   ./test/config-test.sh          run everything
#   ./test/config-test.sh mounts   run tests whose name contains "mounts"

set -uo pipefail

CARREL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/carrel"
FILTER="${1:-}"

passed=0
failed=0

# Each test gets its own CARREL_HOME and a throwaway git repo as the project, so
# nothing leaks between cases or touches the real ~/.carrel.
setup() {
  SANDBOX="$(mktemp -d)"
  export CARREL_HOME="$SANDBOX/home"
  PROJECT="$SANDBOX/project"
  mkdir -p "$CARREL_HOME" "$PROJECT"
  git -C "$PROJECT" init -q
  cd "$PROJECT" || exit 1
}

teardown() {
  cd / || exit 1
  rm -rf "$SANDBOX"
}

# stdin is never a terminal here, so carrel never stops to ask about trust.
carrel() { "$CARREL" "$@" </dev/null; }

# Write a config file, creating parents. write_config <path> <json>
write_config() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

# Write the repo's .carrel.json and trust it, as a user would after reviewing it.
write_repo_config() {
  write_config "$PROJECT/.carrel.json" "$1"
  carrel trust >/dev/null 2>&1
}

project_config() {
  printf '%s/projects/%s.json' "$CARREL_HOME" "${PROJECT//\//-}"
}

fail() {
  printf '  FAIL: %b\n' "$*" >&2
  test_failed=1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected to find '$2' in:\n$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected NOT to find '$2' in:\n$1" ;;
  esac
}

assert_equals() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# run_test <name> <function>
run_test() {
  local name="$1" fn="$2"
  case "$name" in
    *"$FILTER"*) ;;
    *) return 0 ;;
  esac

  test_failed=0
  setup
  "$fn"
  teardown

  if [ "$test_failed" = 0 ]; then
    passed=$((passed + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name"
  fi
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_defaults() {
  local out
  out="$(carrel --dry-run 2>/dev/null)"
  assert_contains "$out" "carrel:base"
  assert_equals "$(carrel config get variant)" "base"
  assert_equals "$(carrel config get image)" "carrel"
  assert_equals "$(carrel config get clipboard)" "false"
}

test_global_config_applies() {
  write_config "$CARREL_HOME/config.json" '{"variant": "rust", "image": "mine"}'
  local out
  out="$(carrel --dry-run 2>/dev/null)"
  assert_contains "$out" "mine:rust"
}

test_repo_config_beats_global() {
  write_config "$CARREL_HOME/config.json" '{"variant": "base"}'
  write_repo_config '{"variant": "rust"}'
  assert_equals "$(carrel config get variant)" "rust"
}

test_project_config_beats_repo() {
  write_repo_config '{"variant": "rust"}'
  write_config "$(project_config)" '{"variant": "tauri"}'
  assert_equals "$(carrel config get variant)" "tauri"
}

test_flag_beats_every_layer() {
  write_config "$CARREL_HOME/config.json" '{"variant": "rust", "image": "global"}'
  write_config "$(project_config)" '{"image": "project"}'
  local out
  out="$(carrel --image flag --dry-run tauri 2>/dev/null)"
  assert_contains "$out" "flag:tauri"
}

test_mounts_accumulate_across_layers() {
  mkdir -p "$PROJECT/fixtures"
  write_config "$CARREL_HOME/config.json" '{"mounts": ["vol-global:/mnt/global"]}'
  write_repo_config '{"mounts": ["./fixtures:/mnt/repo"]}'
  write_config "$(project_config)" '{"mounts": ["vol-project:/mnt/project"]}'

  local out
  out="$(carrel --dry-run --mount vol-flag:/mnt/flag 2>/dev/null)"
  assert_contains "$out" "vol-global:/mnt/global:ro"
  assert_contains "$out" "$PROJECT/fixtures:/mnt/repo:ro"
  assert_contains "$out" "vol-project:/mnt/project:ro"
  assert_contains "$out" "vol-flag:/mnt/flag:ro"
}

test_repo_cannot_mount_outside_project() {
  write_repo_config \
    '{"mounts": ["~/.ssh:/home/claude/.ssh", "/etc:/mnt/etc", "../:/mnt/up"]}'

  local out err
  out="$(carrel --dry-run 2>/dev/null)"
  err="$(carrel --dry-run 2>&1 >/dev/null)"

  assert_not_contains "$out" "/home/claude/.ssh"
  assert_not_contains "$out" "/mnt/etc"
  assert_not_contains "$out" "/mnt/up"
  assert_contains "$err" "outside the project"
}

test_repo_cannot_escape_via_symlink() {
  ln -s /etc "$PROJECT/escape"
  write_repo_config '{"mounts": ["./escape:/mnt/escape"]}'

  local out err
  out="$(carrel --dry-run 2>/dev/null)"
  err="$(carrel --dry-run 2>&1 >/dev/null)"
  assert_not_contains "$out" "/mnt/escape"
  assert_contains "$err" "skipping mount './escape:/mnt/escape'"
}

test_repo_may_mount_named_volumes_and_own_paths() {
  mkdir -p "$PROJECT/cache"
  write_repo_config \
    '{"mounts": ["carrel-pnpm:/home/claude/.local/share/pnpm:rw", "./cache:/mnt/cache:rw"]}'

  local out
  out="$(carrel --dry-run 2>/dev/null)"
  assert_contains "$out" "carrel-pnpm:/home/claude/.local/share/pnpm:rw"
  assert_contains "$out" "$PROJECT/cache:/mnt/cache:rw"
}

test_repo_cannot_enable_clipboard() {
  write_repo_config '{"clipboard": true}'
  local err
  err="$(carrel config get clipboard 2>&1 >/dev/null)"
  assert_equals "$(carrel config get clipboard 2>/dev/null)" "false"
  assert_contains "$err" "only you can turn it on"
}

test_repo_cannot_enable_clipboard_via_wrong_type() {
  write_repo_config '{"clipboard": ["true"]}'
  local err
  err="$(carrel config get clipboard 2>&1 >/dev/null)"
  assert_equals "$(carrel config get clipboard 2>/dev/null)" "false"
  assert_contains "$err" "expected true or false"
}

test_repo_may_disable_clipboard() {
  write_config "$CARREL_HOME/config.json" '{"clipboard": true}'
  write_repo_config '{"clipboard": false}'
  assert_equals "$(carrel config get clipboard 2>/dev/null)" "false"
}

test_repo_cannot_enable_ssh_agent() {
  local mode err
  for mode in host carrel; do
    write_repo_config "{\"ssh_agent\": \"$mode\"}"

    err="$(carrel config get ssh_agent 2>&1)"

    assert_contains "$err" "only you can turn it on"
    assert_contains "$err" "off"
  done
}

test_repo_may_disable_ssh_agent() {
  write_config "$CARREL_HOME/config.json" '{"ssh_agent": "host"}'
  write_repo_config '{"ssh_agent": "off"}'

  local mode
  mode="$(carrel config get ssh_agent 2>/dev/null)"

  assert_equals "$mode" "off"
}

# A unix socket standing in for an ssh-agent, for dry runs.
make_fake_agent_socket() {
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
}

test_ssh_agent_is_off_by_default() {
  local sock="$SANDBOX/agent.sock"
  make_fake_agent_socket "$sock"

  local out
  out="$(SSH_AUTH_SOCK="$sock" carrel --dry-run 2>/dev/null)"

  assert_not_contains "$out" "SSH_AUTH_SOCK"
}

test_ssh_agent_host_forwards_your_socket() {
  local sock="$SANDBOX/agent.sock"
  make_fake_agent_socket "$sock"

  local out
  out="$(SSH_AUTH_SOCK="$sock" carrel --ssh-agent host --dry-run 2>/dev/null)"

  assert_contains "$out" "$sock:/run/carrel/ssh-agent.sock:rw"
  assert_contains "$out" "SSH_AUTH_SOCK=/run/carrel/ssh-agent.sock"
}

test_no_ssh_agent_flag_beats_config() {
  local sock="$SANDBOX/agent.sock"
  make_fake_agent_socket "$sock"
  write_config "$CARREL_HOME/config.json" '{"ssh_agent": "host"}'

  local out
  out="$(SSH_AUTH_SOCK="$sock" carrel --no-ssh-agent --dry-run 2>/dev/null)"

  assert_not_contains "$out" "SSH_AUTH_SOCK"
}

test_ssh_agent_carrel_forwards_a_session_socket() {
  mkdir -p "$CARREL_HOME/ssh"
  touch "$CARREL_HOME/ssh/id_ed25519"

  local out
  out="$(SSH_AUTH_SOCK="$SANDBOX/host.sock" carrel --ssh-agent=carrel --dry-run 2>/dev/null)"

  assert_contains "$out" "carrel-ssh.XXXXXX/agent.sock:/run/carrel/ssh-agent.sock:rw"
  assert_not_contains "$out" "host.sock"
}

test_ssh_agent_carrel_without_keys_warns_and_launches() {
  local out err
  out="$(carrel --ssh-agent carrel --dry-run 2>"$SANDBOX/err")"
  err="$(cat "$SANDBOX/err")"

  assert_contains "$out" "docker run"
  assert_not_contains "$out" "SSH_AUTH_SOCK"
  assert_contains "$err" "ssh-keygen"
}

# Puts a fake docker first on PATH that logs the keys the forwarded agent holds
# and the agent socket it was given, so a real launch can be inspected.
stub_docker() {
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker sees SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-} SSH_AGENT_PID=${SSH_AGENT_PID:-}"
for arg in "$@"; do
  case "$arg" in
    *:/run/carrel/ssh-agent.sock:rw)
      sock="${arg%%:*}"
      echo "socket $sock"
      SSH_AUTH_SOCK="$sock" ssh-add -l
      ;;
  esac
done
STUB
  chmod +x "$SANDBOX/bin/docker"
}

# Waits up to 15 seconds for the agent behind a socket to stop answering;
# ssh-agent checks on the command it runs every 10.
agent_has_stopped() {
  local attempt
  for attempt in $(seq 15); do
    if ! SSH_AUTH_SOCK="$1" ssh-add -l >/dev/null 2>&1 && [ ! -e "$1" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

test_ssh_agent_carrel_runs_an_agent_for_the_session() {
  stub_docker
  mkdir -p "$CARREL_HOME/ssh"
  ssh-keygen -q -t ed25519 -N '' -C carrel-test -f "$CARREL_HOME/ssh/id_ed25519"

  local out sock stopped=no
  out="$(XDG_RUNTIME_DIR="$SANDBOX" PATH="$SANDBOX/bin:$PATH" carrel --ssh-agent carrel 2>/dev/null)"
  sock="$(printf '%s\n' "$out" | sed -n 's/^socket //p')"
  if agent_has_stopped "$sock"; then
    stopped=yes
  fi

  assert_contains "$out" "carrel-test (ED25519)"
  assert_contains "$sock" "$SANDBOX/carrel-ssh."
  assert_equals "$stopped" "yes"
}

test_ssh_agent_carrel_leaves_docker_your_own_agent() {
  stub_docker
  mkdir -p "$CARREL_HOME/ssh"
  ssh-keygen -q -t ed25519 -N '' -C carrel-test -f "$CARREL_HOME/ssh/id_ed25519"

  local out
  out="$(SSH_AUTH_SOCK=/host/agent.sock XDG_RUNTIME_DIR="$SANDBOX" PATH="$SANDBOX/bin:$PATH" \
    carrel --ssh-agent carrel 2>/dev/null)"

  assert_contains "$out" "docker sees SSH_AUTH_SOCK=/host/agent.sock SSH_AGENT_PID="$'\n'
}

test_ssh_agent_carrel_refuses_pkcs11_providers() {
  stub_docker
  mkdir -p "$CARREL_HOME/ssh"
  touch "$CARREL_HOME/ssh/id_ed25519"
  printf '#!/bin/sh\necho "ssh-agent $*" >"%s/ssh-agent.log"\n' "$SANDBOX" >"$SANDBOX/bin/ssh-agent"
  chmod +x "$SANDBOX/bin/ssh-agent"

  XDG_RUNTIME_DIR="$SANDBOX" PATH="$SANDBOX/bin:$PATH" carrel --ssh-agent carrel >/dev/null 2>&1

  assert_contains "$(cat "$SANDBOX/ssh-agent.log")" "ssh-agent -P none -a "
}

test_ssh_agent_carrel_keeps_fresh_dirs_and_prunes_old_empty_ones() {
  stub_docker
  mkdir -p "$CARREL_HOME/ssh" "$SANDBOX/carrel-ssh.starting" "$SANDBOX/carrel-ssh.finished"
  ssh-keygen -q -t ed25519 -N '' -C carrel-test -f "$CARREL_HOME/ssh/id_ed25519"
  touch -d '2 minutes ago' "$SANDBOX/carrel-ssh.finished"

  XDG_RUNTIME_DIR="$SANDBOX" PATH="$SANDBOX/bin:$PATH" carrel --ssh-agent carrel >/dev/null 2>&1

  [ -d "$SANDBOX/carrel-ssh.starting" ] || fail "expected a fresh session dir to be kept"
  [ -d "$SANDBOX/carrel-ssh.finished" ] && fail "expected an old empty session dir to be removed"
}

test_ssh_agent_carrel_stops_when_keys_fail_to_load() {
  stub_docker
  mkdir -p "$CARREL_HOME/ssh"
  ssh-keygen -q -t ed25519 -N 'secret' -C carrel-test -f "$CARREL_HOME/ssh/id_ed25519"

  local out status=0
  out="$(SSH_ASKPASS=/bin/false SSH_ASKPASS_REQUIRE=force XDG_RUNTIME_DIR="$SANDBOX" \
    PATH="$SANDBOX/bin:$PATH" carrel --ssh-agent carrel 2>&1)" || status=$?

  assert_equals "$status" "1"
  assert_contains "$out" "not launching"
  assert_not_contains "$out" "socket "
}
test_ssh_key_dir_is_hidden_from_a_project_containing_it() {
  export CARREL_HOME="$PROJECT/.carrel"
  mkdir -p "$CARREL_HOME/ssh"

  local out
  out="$(carrel --dry-run 2>/dev/null)"

  assert_contains "$out" "--mount type=tmpfs\\,destination=$PROJECT/.carrel/ssh"
}

test_ssh_key_dir_is_hidden_at_the_project_path_given() {
  mkdir -p "$SANDBOX/real"
  mv "$PROJECT" "$SANDBOX/real/project"
  ln -s "$SANDBOX/real" "$SANDBOX/link"
  export CARREL_HOME="$SANDBOX/link/project/.carrel"
  mkdir -p "$CARREL_HOME/ssh"
  cd "$SANDBOX/link/project" || return

  local out
  out="$(carrel --dry-run 2>/dev/null)"

  assert_contains "$out" "destination=$SANDBOX/link/project/.carrel/ssh"
  assert_not_contains "$out" "destination=$SANDBOX/real"
}

test_ssh_key_dir_is_hidden_inside_extra_mounts() {
  mkdir -p "$CARREL_HOME/ssh"

  local out
  out="$(carrel -m "$SANDBOX:/data" --dry-run 2>/dev/null)"

  assert_contains "$out" "destination=/data/home/ssh"
}

test_ssh_key_dir_is_hidden_inside_a_root_mount() {
  mkdir -p "$CARREL_HOME/ssh"

  local out
  out="$(carrel -m "/:/host" --dry-run 2>/dev/null)"

  assert_contains "$out" "destination=/host$CARREL_HOME/ssh"
}

test_ssh_key_dir_is_hidden_once_per_path() {
  export CARREL_HOME="$PROJECT/.carrel"
  mkdir -p "$CARREL_HOME/ssh"

  local out
  out="$(carrel -m "$PROJECT" --dry-run 2>/dev/null)"

  assert_equals "$(printf '%s\n' "$out" | grep -o 'type=tmpfs' | wc -l | tr -d ' ')" "1"
}

test_ssh_key_dir_behind_a_comma_path_refuses_to_launch() {
  mkdir -p "$CARREL_HOME/ssh"

  local out status=0
  out="$(carrel -m "$SANDBOX:/a,destination=/elsewhere" --dry-run 2>&1)" || status=$?

  assert_equals "$status" "1"
  assert_contains "$out" "can't hide"
}

test_mount_inside_ssh_key_dir_refuses_to_launch() {
  mkdir -p "$CARREL_HOME/ssh"
  touch "$CARREL_HOME/ssh/id_ed25519"

  local out status=0
  out="$(carrel -m "$CARREL_HOME/ssh/id_ed25519:/k" --dry-run 2>&1)" || status=$?

  assert_equals "$status" "1"
  assert_contains "$out" "inside carrel's ssh key dir"
}

test_missing_ssh_key_dir_is_not_mounted_over() {
  export CARREL_HOME="$PROJECT/.carrel"
  mkdir -p "$CARREL_HOME"

  local out
  out="$(carrel --dry-run 2>/dev/null)"

  assert_not_contains "$out" "tmpfs"
}
test_ssh_agent_rejects_unknown_flag_values() {
  local value err
  for value in yes ""; do
    err="$(carrel --ssh-agent="$value" --dry-run 2>&1)" && fail "expected a nonzero exit for '$value'"

    assert_contains "$err" "off host carrel"
  done
}

test_ssh_agent_set_rejects_unknown_values() {
  local err
  err="$(carrel config set ssh_agent true 2>&1)" && fail "expected a nonzero exit"

  assert_contains "$err" "off host carrel"
}

test_ssh_agent_unknown_config_value_warns() {
  write_config "$CARREL_HOME/config.json" '{"ssh_agent": "yes"}'

  local out err
  out="$(carrel --dry-run 2>"$SANDBOX/err")"
  err="$(cat "$SANDBOX/err")"

  assert_contains "$out" "docker run"
  assert_contains "$err" "unknown ssh_agent 'yes'"
}

test_ssh_agent_host_without_socket_warns_and_launches() {
  local out err
  out="$(SSH_AUTH_SOCK="$SANDBOX/missing.sock" carrel --ssh-agent host --dry-run 2>"$SANDBOX/err")"
  err="$(cat "$SANDBOX/err")"

  assert_contains "$out" "docker run"
  assert_not_contains "$out" "SSH_AUTH_SOCK"
  assert_contains "$err" "continuing without it"
}

test_ssh_agent_host_without_agent_warns() {
  local err
  err="$(env -u SSH_AUTH_SOCK "$CARREL" --ssh-agent host --dry-run 2>&1 >/dev/null </dev/null)"

  assert_contains "$err" "SSH_AUTH_SOCK is unset"
}

test_repo_cannot_set_sync() {
  write_repo_config '{"sync": ["evil.sh"]}'
  local err
  err="$(carrel config get sync 2>&1 >/dev/null)"
  assert_contains "$err" "only you can choose what's synced"
  assert_not_contains "$(carrel config get sync 2>/dev/null)" "evil.sh"
}

test_sync_replaces_defaults_rather_than_appending() {
  write_config "$CARREL_HOME/config.json" '{"sync": ["CLAUDE.md"]}'
  assert_equals "$(carrel config get sync 2>/dev/null)" "CLAUDE.md"
}

test_set_get_add_unset_roundtrip() {
  carrel config set variant rust >/dev/null
  assert_equals "$(carrel config get variant)" "rust"

  carrel config set --project variant tauri >/dev/null
  assert_equals "$(carrel config get variant)" "tauri"
  [ -f "$(project_config)" ] || fail "expected a project config at $(project_config)"

  carrel config unset --project variant >/dev/null
  assert_equals "$(carrel config get variant)" "rust"

  carrel config add mounts vol-a:/mnt/a >/dev/null
  carrel config add mounts vol-b:/mnt/b >/dev/null
  assert_equals "$(carrel config get mounts | tr '\n' ' ')" "vol-a:/mnt/a vol-b:/mnt/b "

  carrel config set mounts vol-c:/mnt/c >/dev/null
  assert_equals "$(carrel config get mounts)" "vol-c:/mnt/c"
}

test_set_rejects_bad_input() {
  local err
  err="$(carrel config set variant banana 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "unknown variant"

  err="$(carrel config set nonsense 1 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "unknown key"

  err="$(carrel config add variant rust 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "isn't a list"
}

test_unknown_key_in_file_is_ignored() {
  write_config "$CARREL_HOME/config.json" '{"variant": "rust", "wat": 1}'
  local err
  err="$(carrel config get variant 2>&1 >/dev/null)"
  assert_contains "$err" "unknown key 'wat'"
  assert_equals "$(carrel config get variant 2>/dev/null)" "rust"
}

test_multiple_json_documents_are_ignored() {
  write_config "$CARREL_HOME/config.json" '{"variant": "rust"} {"image": "x"}'
  local err
  err="$(carrel config get variant 2>&1 >/dev/null)"
  assert_contains "$err" "not a single JSON object"
  assert_not_contains "$err" "jq:"
  assert_equals "$(carrel config get variant 2>/dev/null)" "base"
}

test_malformed_file_is_ignored() {
  write_config "$CARREL_HOME/config.json" '{ not json'
  local err
  err="$(carrel config get variant 2>&1 >/dev/null)"
  assert_contains "$err" "not a single JSON object"
  assert_equals "$(carrel config get variant 2>/dev/null)" "base"
}

test_show_origin_attributes_each_value() {
  write_config "$CARREL_HOME/config.json" '{"variant": "rust"}'
  write_config "$(project_config)" '{"image": "mine"}'

  local out
  out="$(carrel config get --show-origin 2>/dev/null)"
  assert_contains "$out" "variant    rust"
  assert_contains "$out" "$CARREL_HOME/config.json"
  assert_contains "$out" "$(project_config)"
  assert_contains "$out" "(default)"
}

test_config_reads_from_a_subdirectory() {
  write_repo_config '{"variant": "rust"}'
  mkdir -p "$PROJECT/src/deep"
  cd "$PROJECT/src/deep" || return
  assert_equals "$(carrel config get variant)" "rust"
}

test_tz_falls_back_to_the_host() {
  write_config "$CARREL_HOME/config.json" '{"tz": "Antarctica/Troll"}'
  assert_contains "$(carrel --dry-run 2>/dev/null)" "TZ=Antarctica/Troll"
  assert_contains "$(carrel --tz UTC --dry-run 2>/dev/null)" "TZ=UTC"
}

test_claude_args_still_pass_through() {
  local out
  out="$(carrel --dry-run rust --resume abc123 -p hello 2>/dev/null)"
  assert_contains "$out" "carrel:rust claude --resume abc123 -p hello"
}

test_shell_launches_bash() {
  assert_contains "$(carrel shell --dry-run rust 2>/dev/null)" "carrel:rust bash"
}

test_opencode_launches_opencode() {
  local out
  out="$(carrel opencode --dry-run rust --continue 2>/dev/null)"
  assert_contains "$out" "carrel:rust opencode --continue"
  assert_contains "$out" "$CARREL_HOME/opencode/data:/home/claude/.local/share/opencode"
}

# The Makefile passes --image ahead of the subcommand, so flags have to be
# recognised on either side of it.
test_flags_may_precede_a_subcommand() {
  assert_contains "$(carrel --image mine shell --dry-run rust 2>/dev/null)" "mine:rust bash"
  assert_contains "$(carrel --image mine sessions 2>/dev/null)" "$CARREL_HOME/claude/projects/"
}

test_config_flags_are_not_eaten_by_the_launcher() {
  write_config "$CARREL_HOME/config.json" '{"variant": "rust"}'
  carrel config set --project image mine >/dev/null
  assert_contains "$(carrel config get --show-origin 2>/dev/null)" "image      mine"
}

test_untrusted_repo_config_is_skipped() {
  write_config "$PROJECT/.carrel.json" '{"variant": "rust"}'
  local err
  err="$(carrel --dry-run 2>&1 >/dev/null)"
  assert_contains "$err" "until you trust it"
  assert_contains "$(carrel --dry-run 2>/dev/null)" "carrel:base"
}

test_trust_applies_repo_config_and_lists_it() {
  mkdir -p "$PROJECT/bin"
  write_config "$PROJECT/.carrel.json" \
    '{"variant": "rust", "mounts": ["./bin:/home/claude/.local/bin"]}'
  local out
  out="$(carrel trust 2>/dev/null)"
  assert_contains "$out" "rust"
  assert_contains "$out" "$PROJECT/bin -> /home/claude/.local/bin (read-only)"
  assert_contains "$(carrel --dry-run 2>/dev/null)" "carrel:rust"
}

test_changed_repo_config_needs_trust_again() {
  write_repo_config '{"variant": "rust"}'
  write_config "$PROJECT/.carrel.json" '{"variant": "tauri"}'
  local err
  err="$(carrel --dry-run 2>&1 >/dev/null)"
  assert_contains "$err" "until you trust it"
  assert_contains "$(carrel --dry-run 2>/dev/null)" "carrel:base"
}

test_repo_scope_writes_and_trusts_repo_config() {
  mkdir -p "$PROJECT/.vmssh"
  carrel config set --repo variant rust >/dev/null
  carrel config add --repo mounts ./.vmssh:/home/claude/.ssh >/dev/null
  [ -f "$PROJECT/.carrel.json" ] || fail "expected a repo config at $PROJECT/.carrel.json"
  assert_equals "$(carrel config path --repo)" "$PROJECT/.carrel.json"

  local out
  out="$(carrel --dry-run 2>/dev/null)"
  assert_contains "$out" "carrel:rust"
  assert_contains "$out" "$PROJECT/.vmssh:/home/claude/.ssh:ro"

  carrel config unset --repo variant >/dev/null
  assert_contains "$(carrel --dry-run 2>/dev/null)" "carrel:base"
}

test_repo_cannot_set_vm_group() {
  write_repo_config '{"vm_group": "work"}'

  local err
  err="$(carrel config get vm_group 2>&1 >/dev/null)"

  assert_equals "$(carrel config get vm_group 2>/dev/null)" ""
  assert_contains "$err" "only you can choose which projects share a VM"
}

test_repo_scope_rejects_what_a_repo_cannot_set() {
  local err
  err="$(carrel config add --repo mounts ~/.ssh:/home/claude/.ssh 2>&1)" &&
    fail "expected a nonzero exit"
  assert_contains "$err" "outside the project"

  err="$(carrel config set --repo clipboard true 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "clipboard"

  err="$(carrel config set --repo ssh_agent carrel 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "ssh_agent"

  err="$(carrel config set --repo sync CLAUDE.md 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "sync"

  err="$(carrel config set --repo vm_group work 2>&1)" && fail "expected a nonzero exit"
  assert_contains "$err" "vm_group"

  [ -f "$PROJECT/.carrel.json" ] && fail "expected no repo config to be written"
}

test_repo_scope_keeps_untrusted_config_untrusted() {
  write_config "$PROJECT/.carrel.json" '{"image": "sketchy"}'
  local err
  err="$(carrel config set --repo variant rust 2>&1 >/dev/null)"
  assert_contains "$err" "carrel trust"
  assert_contains "$(carrel --dry-run 2>/dev/null)" "carrel:base"
}

test_config_help_succeeds() {
  local out
  out="$(carrel config --help)" || fail "expected a zero exit"
  assert_contains "$out" "carrel config get"
}

test_help_works_without_jq() {
  mkdir -p "$SANDBOX/bin"
  ln -s "$(command -v cat)" "$SANDBOX/bin/cat"
  local out
  out="$(PATH="$SANDBOX/bin" "$BASH" "$CARREL" --help)" || fail "expected a zero exit"
  assert_contains "$out" "Usage:"
}

test_help_lists_every_variant() {
  assert_contains "$(carrel --help)" "base|rust|tauri"
}

test_every_variant_is_recognised() {
  local variant
  for variant in base rust tauri; do
    assert_contains "$(carrel --dry-run "$variant" 2>/dev/null)" "carrel:$variant claude"
  done
}

test_show_origin_warns_once() {
  write_config "$CARREL_HOME/config.json" '{"bogus": 1}'
  local err
  err="$(carrel config get --show-origin 2>&1 >/dev/null)"
  assert_equals "$(printf '%s\n' "$err" | grep -c "unknown key 'bogus'")" "1"
}

test_worktree_mounts_main_git_dir() {
  git -C "$PROJECT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$PROJECT" worktree add -q "$SANDBOX/wt"
  cd "$SANDBOX/wt" || return
  assert_contains "$(carrel --dry-run 2>/dev/null)" "$PROJECT/.git:$PROJECT/.git:rw"
}

test_relative_worktree_mounts_main_git_dir() {
  git -C "$PROJECT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$PROJECT" worktree add -q --relative-paths "$SANDBOX/wt"
  cd "$SANDBOX/wt" || return
  assert_contains "$(carrel --dry-run 2>/dev/null)" "$PROJECT/.git:$PROJECT/.git:rw"
}

test_main_checkout_mounts_no_extra_git_dir() {
  assert_not_contains "$(carrel --dry-run 2>/dev/null)" ".git:"
}

# A repo elsewhere on the host that a crafted .git tries to get mounted.
make_victim_repo() {
  VICTIM="$SANDBOX/victim"
  git init -q "$VICTIM"
}

assert_no_victim_mount() {
  local out
  out="$(carrel --dry-run 2>/dev/null)"
  assert_contains "$out" "docker run"
  assert_not_contains "$out" "$VICTIM"
}

test_commondir_file_cannot_mount_another_repo() {
  make_victim_repo
  printf '%s\n' "$VICTIM/.git" >"$PROJECT/.git/commondir"
  assert_no_victim_mount
}

test_crafted_git_file_cannot_mount_another_repo() {
  make_victim_repo
  rm -rf "$PROJECT/.git"
  mkdir -p "$PROJECT/.fake"
  echo 'ref: refs/heads/main' >"$PROJECT/.fake/HEAD"
  printf '%s\n' "$VICTIM/.git" >"$PROJECT/.fake/commondir"
  echo 'gitdir: ./.fake' >"$PROJECT/.git"
  assert_no_victim_mount
}

test_git_file_into_another_repos_worktree_is_not_mounted() {
  make_victim_repo
  git -C "$VICTIM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$VICTIM" worktree add -q "$SANDBOX/victim-wt"
  rm -rf "$PROJECT/.git"
  echo "gitdir: $VICTIM/.git/worktrees/victim-wt" >"$PROJECT/.git"
  assert_no_victim_mount
}

test_double_dash_passes_the_rest_to_claude() {
  assert_contains "$(carrel --dry-run rust -- --help 2>/dev/null)" "carrel:rust claude --help"
}

test_sync_dry_run_writes_nothing() {
  carrel --dry-run sync >/dev/null 2>&1
  [ -e "$CARREL_HOME/claude" ] && fail "expected sync --dry-run not to create $CARREL_HOME/claude"
}

test_sync_refuses_paths_outside_claude_dir() {
  mkdir -p "$SANDBOX/fakehome/.claude"
  write_config "$CARREL_HOME/config.json" '{"sync": ["..", "a/../../b", "/etc"]}'
  local err
  err="$(HOME="$SANDBOX/fakehome" carrel sync 2>&1 >/dev/null)"
  assert_contains "$err" "skipping sync item '..'"
  assert_contains "$err" "skipping sync item 'a/../../b'"
  assert_contains "$err" "skipping sync item '/etc'"
}

test_sync_leaves_container_downloaded_skills_alone() {
  local host="$SANDBOX/fakehome/.claude"
  mkdir -p "$host/skills/mine" "$host/skills/synced/from-host" \
    "$CARREL_HOME/claude/skills/synced/bucket" "$CARREL_HOME/claude/skills/stale"
  touch "$host/skills/mine/SKILL.md" "$CARREL_HOME/claude/skills/synced/bucket/SKILL.md"
  write_config "$CARREL_HOME/config.json" '{"sync": ["skills"]}'

  local out
  out="$(HOME="$SANDBOX/fakehome" carrel sync 2>&1)"

  assert_not_contains "$out" "deleting synced"
  [ -f "$CARREL_HOME/claude/skills/synced/bucket/SKILL.md" ] || fail "expected skills/synced to survive the sync"
  [ -e "$CARREL_HOME/claude/skills/synced/from-host" ] && fail "expected host skills/synced not to be copied"
  [ -f "$CARREL_HOME/claude/skills/mine/SKILL.md" ] || fail "expected host skills to be synced"
  [ -e "$CARREL_HOME/claude/skills/stale" ] && fail "expected skills removed on the host to be deleted"
}

# ─── Runner ───────────────────────────────────────────────────────────────────

run_test "defaults"                          test_defaults
run_test "global config applies"             test_global_config_applies
run_test "repo config beats global"          test_repo_config_beats_global
run_test "project config beats repo"         test_project_config_beats_repo
run_test "flag beats every layer"            test_flag_beats_every_layer
run_test "mounts accumulate"                 test_mounts_accumulate_across_layers
run_test "repo mounts stay in the project"   test_repo_cannot_mount_outside_project
run_test "repo mounts cannot symlink out"    test_repo_cannot_escape_via_symlink
run_test "repo mounts volumes and own paths" test_repo_may_mount_named_volumes_and_own_paths
run_test "repo cannot enable clipboard"      test_repo_cannot_enable_clipboard
run_test "repo clipboard must be a bool"      test_repo_cannot_enable_clipboard_via_wrong_type
run_test "repo may disable clipboard"        test_repo_may_disable_clipboard
run_test "repo cannot enable ssh agent"      test_repo_cannot_enable_ssh_agent
run_test "repo may disable ssh agent"        test_repo_may_disable_ssh_agent
run_test "ssh agent off by default"          test_ssh_agent_is_off_by_default
run_test "ssh agent host forwards yours"     test_ssh_agent_host_forwards_your_socket
run_test "--no-ssh-agent beats config"       test_no_ssh_agent_flag_beats_config
run_test "ssh agent carrel session socket"   test_ssh_agent_carrel_forwards_a_session_socket
run_test "ssh agent carrel needs keys"       test_ssh_agent_carrel_without_keys_warns_and_launches
run_test "ssh agent carrel per session"      test_ssh_agent_carrel_runs_an_agent_for_the_session
run_test "ssh agent carrel bad key stops"    test_ssh_agent_carrel_stops_when_keys_fail_to_load
run_test "ssh agent carrel docker env"       test_ssh_agent_carrel_leaves_docker_your_own_agent
run_test "ssh agent carrel refuses pkcs11"   test_ssh_agent_carrel_refuses_pkcs11_providers
run_test "ssh agent carrel prunes old dirs"   test_ssh_agent_carrel_keeps_fresh_dirs_and_prunes_old_empty_ones
run_test "ssh key dir hidden from project"   test_ssh_key_dir_is_hidden_from_a_project_containing_it
run_test "ssh key dir hidden at given path"  test_ssh_key_dir_is_hidden_at_the_project_path_given
run_test "ssh key dir hidden in mounts"      test_ssh_key_dir_is_hidden_inside_extra_mounts
run_test "missing ssh key dir not covered"   test_missing_ssh_key_dir_is_not_mounted_over
run_test "ssh key dir hidden in root mount"  test_ssh_key_dir_is_hidden_inside_a_root_mount
run_test "ssh key dir hidden once per path"  test_ssh_key_dir_is_hidden_once_per_path
run_test "ssh key dir comma path refused"    test_ssh_key_dir_behind_a_comma_path_refuses_to_launch
run_test "mount inside ssh key dir refused"  test_mount_inside_ssh_key_dir_refuses_to_launch
run_test "ssh agent rejects bad flag"        test_ssh_agent_rejects_unknown_flag_values
run_test "ssh agent set rejects bad value"   test_ssh_agent_set_rejects_unknown_values
run_test "ssh agent bad config warns"        test_ssh_agent_unknown_config_value_warns
run_test "ssh agent host missing socket"     test_ssh_agent_host_without_socket_warns_and_launches
run_test "ssh agent host no agent"           test_ssh_agent_host_without_agent_warns
run_test "repo cannot set sync"              test_repo_cannot_set_sync
run_test "repo cannot set vm_group"          test_repo_cannot_set_vm_group
run_test "sync replaces defaults"            test_sync_replaces_defaults_rather_than_appending
run_test "set/get/add/unset roundtrip"       test_set_get_add_unset_roundtrip
run_test "set rejects bad input"             test_set_rejects_bad_input
run_test "unknown key ignored"               test_unknown_key_in_file_is_ignored
run_test "multiple json documents ignored"   test_multiple_json_documents_are_ignored
run_test "malformed file ignored"            test_malformed_file_is_ignored
run_test "show-origin attributes values"     test_show_origin_attributes_each_value
run_test "config reads from a subdirectory"  test_config_reads_from_a_subdirectory
run_test "tz from config and flag"           test_tz_falls_back_to_the_host
run_test "claude args pass through"          test_claude_args_still_pass_through
run_test "shell launches bash"               test_shell_launches_bash
run_test "opencode launches opencode"        test_opencode_launches_opencode
run_test "flags may precede a subcommand"    test_flags_may_precede_a_subcommand
run_test "config flags reach config"         test_config_flags_are_not_eaten_by_the_launcher
run_test "untrusted repo config skipped"     test_untrusted_repo_config_is_skipped
run_test "trust applies and lists"           test_trust_applies_repo_config_and_lists_it
run_test "changed repo config needs trust"   test_changed_repo_config_needs_trust_again
run_test "--repo writes and trusts"          test_repo_scope_writes_and_trusts_repo_config
run_test "--repo rejects repo-only limits"   test_repo_scope_rejects_what_a_repo_cannot_set
run_test "--repo keeps untrusted untrusted"  test_repo_scope_keeps_untrusted_config_untrusted
run_test "config --help succeeds"            test_config_help_succeeds
run_test "help works without jq"             test_help_works_without_jq
run_test "help lists every variant"          test_help_lists_every_variant
run_test "every variant recognised"          test_every_variant_is_recognised
run_test "show-origin warns once"            test_show_origin_warns_once
run_test "worktree mounts main .git"         test_worktree_mounts_main_git_dir
run_test "relative worktree mounts .git"     test_relative_worktree_mounts_main_git_dir
run_test "main checkout mounts no .git"      test_main_checkout_mounts_no_extra_git_dir
run_test "commondir can't mount a repo"      test_commondir_file_cannot_mount_another_repo
run_test "crafted .git can't mount a repo"   test_crafted_git_file_cannot_mount_another_repo
run_test ".git into other worktree no mount" test_git_file_into_another_repos_worktree_is_not_mounted
run_test "-- passes the rest to claude"      test_double_dash_passes_the_rest_to_claude
run_test "sync --dry-run writes nothing"     test_sync_dry_run_writes_nothing
run_test "sync stays inside ~/.claude"       test_sync_refuses_paths_outside_claude_dir
run_test "sync keeps skills/synced"          test_sync_leaves_container_downloaded_skills_alone

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
