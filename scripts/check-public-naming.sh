#!/usr/bin/env bash
#
# check-public-naming.sh — keep the private issue tracker out of this PUBLIC repository, and keep
# the public-facing text in a single standard shape.
#
# THE INVARIANT: nothing this repo publishes may name the internal tracker. This repository is
# public and everything it publishes is permanent — commit subjects are copied verbatim into
# CHANGELOG.md and shipped with every tag, and a branch name is embedded by GitHub into the merge
# commit it creates ("Merge pull request #N from org/BRANCH"). An issue key that reaches any of
# those cannot be taken back: a released tag is immutable here (the `released-tags-are-permanent`
# ruleset), and rewriting published history would break every device pinning a ref.
#
# So the key is not merely discouraged in the public surfaces, it is REJECTED before it lands.
# Traceability is not lost, it is INVERTED: the private ticket links out to the public PR, instead
# of the public PR naming the private ticket. Only the direction changes, and the direction that
# leaks is the one removed.
#
# FOUR SURFACES, because fixing fewer leaves the leak in the more permanent ones:
#   1. branch name    -> lands in the merge commit GitHub writes
#   2. PR title       -> the repository's public front page
#   3. PR body        -> same, and indexed
#   4. commit subject -> CHANGELOG.md and every release, forever
#
# It also enforces the shape of what replaces them: the PR title and every non-merge commit subject
# must be a Conventional Commits subject, which is what release-please parses to compute the
# version. A title that is not conventional is not just untidy — a merge whose subjects it cannot
# parse silently drops the change from the release notes.
#
# WHAT IS NOT SCANNED: the contents of tracked files. CHANGELOG.md, AGENTS.md and the git history
# legitimately contain issue keys from before this rule existed; that text is already public and
# cannot be unpublished, so scanning it would fail the build forever with nothing to fix. This gate
# governs what is ADDED from here on.
#
# Usage:
#   check-public-naming.sh [--range BASE..HEAD] [--branch NAME] [--title TEXT] [--body-file FILE]
#   check-public-naming.sh --self-test
#
# Inputs also come from the environment, which is how CI passes them — a PR title is untrusted
# text, and an env var cannot be word-split into the script's own arguments:
#   PR_BRANCH, PR_TITLE, PR_BODY_FILE, COMMIT_RANGE
#
# Every input is optional: a surface with nothing to check is skipped, never silently passed. The
# self-test proves each FAIL path.
set -uo pipefail

# Issue keys of the two Jira projects (ST is the retired key of the IoT board and stays covered:
# old keys leak exactly as much as current ones). Matched case-INSENSITIVELY, because a branch is
# routinely lowercased (`feat/aiot-117`) and a lowercased key leaks exactly as much. Word-boundaried
# so a token that merely ends in those letters is not caught ("adjust-2" is not "ST-2").
TICKET_RE='(^|[^A-Za-z0-9])(AIOT|ESN|ST)-[0-9]+([^A-Za-z0-9]|$)'
# The tracker itself, in any form: a bare host, a browse URL, or a markdown link to one.
TRACKER_RE='(c-iot\.atlassian\.net|atlassian\.net/browse)'
# Conventional Commits, spec-strict in the same way release-please parses it: type(optional scope)
# with an optional ! for breaking, a colon, a space, then a non-empty description.
CONVENTIONAL_RE='^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9,._/-]+\))?!?: .+'

rc=0
fail() { echo "check-public-naming: FAIL — $*"; rc=1; }
ok()   { echo "check-public-naming: ok — $*"; }

# Report every offending line rather than only the first: a author fixing one key and pushing again
# to discover the next one wastes a CI round trip per key.
scan_text() {
  local what="$1" text="$2" found=0
  [ -n "$text" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -qiE "$TICKET_RE" <<<"$line"; then
      fail "${what} names an internal issue key: ${line}"; found=1
    fi
    if grep -qiE "$TRACKER_RE" <<<"$line"; then
      fail "${what} links the internal tracker: ${line}"; found=1
    fi
  done <<<"$text"
  return "$found"
}

check_branch() {
  local branch="$1"
  [ -n "$branch" ] || return 0
  if scan_text "branch name '${branch}'" "$branch"; then
    ok "branch name '${branch}' carries no issue key"
  fi
}

check_title() {
  local title="$1"
  [ -n "$title" ] || return 0
  local clean=0
  scan_text "PR title" "$title" || clean=1
  if ! grep -qE "$CONVENTIONAL_RE" <<<"$title"; then
    fail "PR title is not a Conventional Commits subject: ${title}"
    clean=1
  fi
  [ "$clean" -eq 0 ] && ok "PR title is conventional and carries no issue key"
  return 0
}

check_body() {
  local file="$1"
  [ -n "$file" ] || return 0
  [ -f "$file" ] || { fail "PR body file '${file}' does not exist"; return 0; }
  if scan_text "PR body" "$(cat "$file")"; then
    ok "PR body carries no issue key or tracker link"
  fi
}

# Merge commits are excluded: their subject is written by GitHub, not by the author, and the branch
# check above is what keeps that subject clean at the source.
check_commits() {
  local range="$1" subjects clean=0
  [ -n "$range" ] || return 0
  subjects="$(git log --no-merges --format='%s' "$range" 2>/dev/null)" || {
    fail "cannot read commit range '${range}'"; return 0; }
  [ -n "$subjects" ] || { ok "no non-merge commits in ${range}"; return 0; }
  scan_text "commit subject" "$subjects" || clean=1
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if ! grep -qE "$CONVENTIONAL_RE" <<<"$s"; then
      fail "commit subject is not a Conventional Commits subject: ${s}"; clean=1
    fi
  done <<<"$subjects"
  [ "$clean" -eq 0 ] && ok "$(wc -l <<<"$subjects") commit subject(s) conventional, no issue keys"
  return 0
}

self_test() {
  local t rc=0 out
  t="$(mktemp -d)"
  _expect() { # _expect <want-pass|want-fail> <label> <command...>
    local want="$1" label="$2"; shift 2
    if "$@" >/dev/null 2>&1; then
      [ "$want" = pass ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} was accepted but must be rejected"; rc=1; }
    else
      [ "$want" = fail ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} was rejected but must be accepted"; rc=1; }
    fi
  }
  _run() { ( rc=0; "$@"; exit "$rc" ); }

  _expect fail "a branch named for a ticket"        _run check_branch "feat/AIOT-117"
  _expect fail "a lowercase ticket in a branch"     _run check_branch "feat/aiot-117"
  _expect pass "a slug branch"                      _run check_branch "feat/broker-env-pinning"
  # A word that merely begins with a project's letters is not a key.
  _expect pass "a branch whose slug starts like a key" _run check_branch "feat/estimate-1-pass"

  _expect fail "a title carrying a ticket"          _run check_title "feat/AIOT-117 SDK-21 — pin the broker"
  _expect fail "a non-conventional title"           _run check_title "Pin the broker per environment"
  _expect pass "a conventional title"               _run check_title "feat(mqtt)!: pin the broker per environment"

  printf 'See https://c-iot.atlassian.net/browse/AIOT-117 for context.\n' >"$t/body-bad.md"
  printf 'Closes the broker pinning work.\n' >"$t/body-ok.md"
  _expect fail "a body linking the tracker"         _run check_body "$t/body-bad.md"
  _expect pass "a clean body"                       _run check_body "$t/body-ok.md"
  _expect fail "a missing body file"                _run check_body "$t/nope.md"

  # A throwaway repo, so the commit path is exercised for real rather than mocked. Each case is one
  # commit on top of the previous, and the range checked is always the single newest commit.
  ( cd "$t" && git init -q . && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m "chore: base" ) >/dev/null 2>&1
  _commit() { ( cd "$t" && git commit -q --allow-empty -m "$1" ) >/dev/null 2>&1; }
  _check_last() { ( cd "$t" && _run check_commits "HEAD~1..HEAD" ); }

  _commit "feat(mqtt): pin the broker (AIOT-117)"
  _expect fail "a commit subject carrying a ticket" _check_last
  _commit "not conventional at all"
  _expect fail "a non-conventional commit subject" _check_last
  _commit "feat(mqtt)!: pin the broker per environment"
  _expect pass "a clean conventional commit subject" _check_last
  # A merge commit's subject is GitHub's, not the author's, and must not fail the gate.
  ( cd "$t" && git checkout -q -b side && git commit -q --allow-empty -m "fix(x): side" \
      && git checkout -q - && git merge -q --no-ff side -m "Merge pull request #1 from org/feat/AIOT-9" ) >/dev/null 2>&1
  ( cd "$t" && _run check_commits "HEAD~2..HEAD" ) >/dev/null 2>&1 \
    && echo "self-test: PASS — a merge commit subject is exempt" \
    || { echo "self-test: FAILED — a merge commit subject was scanned"; rc=1; }

  rm -rf "$t"
  [ "$rc" -eq 0 ] && echo "self-test: all FAIL paths proven" || echo "self-test: FAILED"
  return "$rc"
}

BRANCH="${PR_BRANCH:-}"; TITLE="${PR_TITLE:-}"; BODY_FILE="${PR_BODY_FILE:-}"; RANGE="${COMMIT_RANGE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) self_test; exit $? ;;
    --branch)    BRANCH="${2:-}"; shift 2 ;;
    --title)     TITLE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --range)     RANGE="${2:-}"; shift 2 ;;
    *) echo "check-public-naming: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$BRANCH$TITLE$BODY_FILE$RANGE" ]; then
  echo "check-public-naming: no surface given (branch/title/body/range all empty) — nothing to check" >&2
  exit 2
fi

check_branch "$BRANCH"
check_title "$TITLE"
check_body "$BODY_FILE"
check_commits "$RANGE"
exit "$rc"
