#!/usr/bin/env bash
#
# Tests for carrel-vm's launch plan. No Incus needed: `carrel-vm --dry-run`
# prints the incus commands it would run.
#
#   ./test/vm-test.sh          run everything
#   ./test/vm-test.sh group    run tests whose name contains "group"

set -uo pipefail

CARREL_VM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/carrel-vm"
FILTER="${1:-}"

passed=0
failed=0

# Each test gets its own CARREL_HOME and a throwaway git repo (with one commit,
# so it can have worktrees) as the project.
setup() {
  SANDBOX="$(mktemp -d)"
  export CARREL_HOME="$SANDBOX/home"
  PROJECT="$SANDBOX/project"
  mkdir -p "$CARREL_HOME" "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  cd "$PROJECT" || exit 1
}

teardown() {
  cd / || exit 1
  rm -rf "$SANDBOX"
}

carrel_vm() { "$CARREL_VM" "$@" </dev/null; }

# The VM a dry run would create, from its `incus init` line.
planned_vm() {
  carrel_vm --dry-run "$@" 2>/dev/null | sed -n 's/^incus init [^ ]* \([^ ]*\) .*/\1/p'
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

assert_not_equals() {
  [ "$1" != "$2" ] || fail "expected something other than '$2'"
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

test_each_session_gets_its_own_vm_by_default() {
  local first second

  first="$(planned_vm rust)"
  second="$(planned_vm rust)"

  assert_contains "$first" "carrel-rust-"
  assert_not_equals "$first" "$second"
}

test_vm_is_ephemeral() {
  local out

  out="$(carrel_vm --dry-run 2>/dev/null)"

  assert_contains "$out" "--vm --ephemeral"
}

test_project_is_shared_at_its_host_path() {
  local out

  out="$(carrel_vm --dry-run 2>/dev/null)"

  assert_contains "$out" "path=$PROJECT source=$PROJECT readonly=false"
}

test_file_mounts_are_copied_in() {
  local out
  echo '[user]' >"$SANDBOX/gitconfig"

  out="$(carrel_vm --dry-run -m "$SANDBOX/gitconfig:/home/claude/.gitconfig" 2>/dev/null)"

  assert_contains "$out" "file push -p --uid 1000 --gid 1000 $SANDBOX/gitconfig"
  assert_not_contains "$out" "source=$SANDBOX/gitconfig"
}

test_vm_ssh_dir_is_shared_read_only() {
  local out
  mkdir -p "$CARREL_HOME/vm-ssh"

  out="$(carrel_vm --dry-run 2>/dev/null)"

  assert_contains "$out" "path=/home/claude/.ssh source=$CARREL_HOME/vm-ssh readonly=true"
}

test_no_ssh_share_without_a_vm_ssh_dir() {
  local out

  out="$(carrel_vm --dry-run 2>/dev/null)"

  assert_not_contains "$out" "path=/home/claude/.ssh"
}

test_carrel_ssh_key_dir_is_hidden() {
  local out
  mkdir -p "$CARREL_HOME/ssh"

  out="$(cd "$SANDBOX" && carrel_vm --dry-run 2>/dev/null)"

  assert_contains "$out" "sh 1000:1000 $CARREL_HOME/ssh "
}

test_mount_from_inside_carrel_ssh_key_dir_is_refused() {
  local err
  mkdir -p "$CARREL_HOME/ssh"
  echo key >"$CARREL_HOME/ssh/id_ed25519"

  err="$(carrel_vm --dry-run -m "$CARREL_HOME/ssh/id_ed25519:/tmp/key" 2>&1)" &&
    fail "expected a nonzero exit"

  assert_contains "$err" "inside carrel's ssh key dir"
}

test_socket_flags_are_refused() {
  local err

  err="$(carrel_vm --dry-run --clipboard 2>&1)" && fail "expected a nonzero exit"

  assert_contains "$err" "isn't supported in a VM"
}

# ─── Runner ───────────────────────────────────────────────────────────────────

run_test "own vm by default"                  test_each_session_gets_its_own_vm_by_default
run_test "vm is ephemeral"                    test_vm_is_ephemeral
run_test "project shared at host path"        test_project_is_shared_at_its_host_path
run_test "file mounts are copied in"          test_file_mounts_are_copied_in
run_test "vm ssh dir shared read-only"        test_vm_ssh_dir_is_shared_read_only
run_test "no ssh share without vm-ssh"        test_no_ssh_share_without_a_vm_ssh_dir
run_test "carrel ssh key dir is hidden"       test_carrel_ssh_key_dir_is_hidden
run_test "mount inside key dir refused"       test_mount_from_inside_carrel_ssh_key_dir_is_refused
run_test "socket flags are refused"           test_socket_flags_are_refused

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
