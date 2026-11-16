#!/usr/bin/env bash
# Compares the vendored cross-SDK scenario fixture field by field, by diffing
# pretty-printed copies.
#
#   test/fixtures/diff_scenarios.sh OLD_REV            # OLD_REV vs working tree
#   test/fixtures/diff_scenarios.sh OLD_REV NEW_REV    # OLD_REV vs NEW_REV
#
# e.g. uncommitted changes: test/fixtures/diff_scenarios.sh HEAD
#      a committed change:  test/fixtures/diff_scenarios.sh <sha>^ <sha>
#
# Exit status: 0 no difference, 1 a difference (shown), 2 usage error, bad
# revision or a fixture that cannot be rendered (nothing is diffed).

set -euo pipefail

fixture=test/fixtures/cross_sdk_scenarios.json

fail() {
  echo "error: $*" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: $0 OLD_REV [NEW_REV]"
command -v jq >/dev/null || fail "jq is required"
cd "$(git rev-parse --show-toplevel)" || fail "not in a git repository"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Writes the pretty-printed fixture at a revision (or the working tree) to $2.
render() {
  local rev=$1 out=$2

  if [ "$rev" = "--worktree" ]; then
    [ -f "$fixture" ] || fail "no $fixture in the working tree"
    jq . "$fixture" >"$out" || fail "cannot render $fixture from the working tree"
  else
    git rev-parse -q --verify "$rev:$fixture" >/dev/null || fail "no $fixture at $rev"
    git show "$rev:$fixture" >"$tmp/raw" || fail "cannot read $fixture at $rev"
    jq . "$tmp/raw" >"$out" || fail "cannot render $fixture at $rev"
  fi
}

render "$1" "$tmp/old.json"
render "${2:---worktree}" "$tmp/new.json"

status=0
git diff --no-index -- "$tmp/old.json" "$tmp/new.json" || status=$?
[ "$status" -le 1 ] || fail "git diff failed with status $status"
exit "$status"
