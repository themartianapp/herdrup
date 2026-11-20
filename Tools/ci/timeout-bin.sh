# shellcheck shell=bash
# Sourced by the Tools/ci shell scripts: sets TIMEOUT_BIN to the `timeout` they run every
# bounded step under. GNU coreutils' timeout where installed (as `timeout`, or Homebrew's
# `gtimeout`); otherwise Tools/ci/timeout.py, the same options in Python (macOS has no
# `timeout`, and macserve's job PATH has no Homebrew).
#
# ONLY GNU's, never another `timeout` on PATH. uutils' timeout (Rust coreutils 0.10.0,
# Ubuntu 26.04's /usr/bin/timeout and GitHub's ubuntu-latest since November 2026) starts the
# command with the signal dispositions it inherited, so a command started from a script's
# background job (`timeout … &`, where bash ignores SIGINT) ignores the SIGINT timeout
# passes on; it also KILLs only the command after --kill-after, not its process group.
# ui-shard.sh stops a round whose simulator stopped answering accessibility, and ends a
# round at its budget, with SIGINT: under uutils the round ran on until the 60 s KILL, and
# the command's own children survived it (#748's CI, test_ci_helpers' AccessibilityStopTests).
# GNU timeout catches SIGINT before it starts the command, so the command starts with
# SIGINT at its default; timeout.py does the same.
pick_timeout_bin() {
  local candidate path
  for candidate in timeout gtimeout; do
    path=$(command -v "$candidate") || continue
    case "$("$path" --version 2>/dev/null)" in
      *"GNU coreutils"*) echo "$path"; return 0 ;;
    esac
  done
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timeout.py"
}
# shellcheck disable=SC2034 # read by the scripts that source this file
TIMEOUT_BIN=$(pick_timeout_bin)
