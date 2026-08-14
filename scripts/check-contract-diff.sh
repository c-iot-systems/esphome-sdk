#!/usr/bin/env bash
#
# check-contract-diff.sh — a substitution rename can never ship as a non-breaking release.
#
# THE INVARIANT (README "Versioning"): the SDK's public surface is its SUBSTITUTION CONTRACT, and
# "a module rename or a substitution rename is a major bump plus a migration of stored configs".
# Nothing mechanical enforced that. Conventional Commits describe how an author *labelled* a change;
# release-please derives the version from those labels and cannot see the contract at all. So a
# renamed substitution committed as `feat:` publishes a tag that silently breaks every stored
# config that still sets the old name — and a published tag is permanent.
#
# This gate closes the loop at PR time, where the author can still fix it: it diffs the contract
# between BASE and HEAD, and if the change is breaking it REQUIRES the range to carry a breaking
# marker (`type!:` or a `BREAKING CHANGE:` footer). Release-please then computes the bump from a
# label that provably matches reality.
#
# THE CONTRACT SURFACE has exactly two classes, both declarative and both extracted from
# modules/ and hardware/:
#
#   required  — `${ name if name is defined else 1/0 }`. The Jinja guard is the SDK's idiom for
#               "the consumer MUST supply this"; the division by zero is what makes the render
#               fail. tests/negative/ pins one fixture per required name.
#   optional  — a key under a top-level `substitutions:` block, carrying the default the consumer
#               inherits when it stays silent.
#
# SCOPES. A consumer config is every module it imports PLUS EXACTLY ONE board, so the surface is
# keyed by scope, not by name alone: `modules` (all of modules/, which compose into one shared
# namespace) and one scope per `hardware/<board>.yaml`. Boards deliberately reuse names with
# DIFFERENT values — `slot_1_triple_digital_input_in1` is GPIO 7 on hds_v1_0 and 23 on hds_v1_1 —
# so a name-only surface would both collapse those pin tables and go blind to a pin dropped from a
# single board. Splitting a module file moves nothing between scopes, so ordinary refactors stay
# silent.
#
# WHAT COUNTS AS BREAKING, and why (a stored config is a set of substitution values, written once
# and re-used against whatever ref it pins):
#
#   required removed/renamed   BREAKING  the value a stored config supplies stops being read
#   required added            BREAKING  stored configs do not supply it — the render fails
#   optional removed/renamed  BREAKING  WORSE than an error: the value a stored config sets is
#                                       silently ignored and the device takes a different default
#   optional -> required      BREAKING  a config that relied on the default now fails to render
#   required -> optional      ok        a relaxation; every existing config keeps working
#   optional added            ok        silent configs keep their behaviour
#   default value changed     ok, but REPORTED — re-pinning changes device behaviour with no
#                                       config edit, and this SDK's defaults are safety-tagged
#
# NEGATIVE-HARNESS PARITY. The required set derived here must equal the set pinned by
# tests/negative/omit_<name>.yaml — the two are independent statements of the same contract, so a
# disagreement means one of them is stale. In particular a NEW required substitution that arrives
# without its negative fixture would ship unproven.
#
# WHERE IT RUNS. On every pull request (base merge-base -> head), AND again on main before a tag is
# created (last released tag -> HEAD). The second pass is not redundant: the PR pass validates
# commits that a SQUASH MERGE can rewrite, and a direct push to main never sees a PR at all. Only
# the main pass reads the commits release-please will actually parse, so it is the one that can
# still stop a mislabelled permanent tag.
#
# Usage:
#   check-contract-diff.sh [BASE [HEAD]]   # default: origin/main HEAD
#   check-contract-diff.sh --surface [ROOT]
#   check-contract-diff.sh --since-release [HEAD]
#   check-contract-diff.sh --negative-parity [ROOT]
#   check-contract-diff.sh --self-test
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── value helpers ─────────────────────────────────────────────────────────────────────────────

# Strip a trailing ` # comment`, then surrounding whitespace and quotes.
_clean_value() {
  local v="$1"
  v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# ── surface extraction ────────────────────────────────────────────────────────────────────────

# Print every substitution NAME referenced in one file, one per line. Two reference forms carry
# contract meaning and both are collected:
#
#   ${ name if name is defined else 1/0 }   the SDK's explicit "consumer must supply this" guard;
#                                           the division by zero is what makes the render fail
#   ${name}                                 a plain reference. Undefaulted, it is JUST AS REQUIRED —
#                                           ESPHome itself fails on an undefined substitution. This
#                                           is how `device_name` is declared, and
#                                           tests/negative/omit_device_name.yaml pins that.
#
# A guard whose two names disagree is malformed and is reported rather than silently trusted.
_refs_in_file() {
  local file="$1" hit a b
  # Scan with FULL-LINE comments removed: a `${x}` inside a commented-out block is not a reference,
  # and counting it would invent a required substitution out of dead text. Only whole-line comments
  # are dropped — trailing `#` is not a safe comment marker inside the C++ lambdas these modules
  # embed (`#include`, `#define`), and a reference can legitimately share a line with one.
  local body; body="$(mktemp)"
  grep -v '^[[:space:]]*#' "$file" 2>/dev/null >"$body"
  while IFS= read -r hit; do
    a="$(printf '%s' "$hit" | sed -E 's/^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
    b="$(printf '%s' "$hit" | sed -E 's/.*[[:space:]]if[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+is[[:space:]]+defined.*/\1/')"
    if [ "$a" != "$b" ]; then
      # Fail CLOSED. A malformed guard silently drops a name from the surface, which would hide
      # both a breaking removal and a missing negative fixture — the two things this gate exists
      # to catch. The flag file survives the subshells that $(extract_surface) runs in.
      echo "check-contract-diff: MALFORMED — ${file}: guard '${hit}' names '${a}' but tests '${b}'" >&2
      [ -n "${_CONTRACT_ERR_FILE:-}" ] && echo "${file}: ${hit}" >>"$_CONTRACT_ERR_FILE"
      continue
    fi
    printf '%s\n' "$a"
  done < <(grep -oE '\$\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+if[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+is[[:space:]]+defined[[:space:]]+else[[:space:]]+1/0[[:space:]]*\}' "$body" 2>/dev/null)

  # An `if <name> is defined` whose else-branch is NOT `1/0` does not fail the render — it supplies
  # a fallback, which makes the substitution OPTIONAL with a default this extractor cannot read from
  # a `substitutions:` block. Classifying it either way would be a guess, so fail closed.
  if grep -oE '\$\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+if[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+is[[:space:]]+defined[[:space:]]+else[[:space:]]+[^}]*\}' "$body" 2>/dev/null \
       | grep -qvE 'else[[:space:]]+1/0[[:space:]]*\}'; then
    echo "check-contract-diff: UNSUPPORTED — ${file}: an 'is defined' guard uses a fallback other than 'else 1/0'; its default cannot be derived" >&2
    [ -n "${_CONTRACT_ERR_FILE:-}" ] && echo "${file}: non-1/0 guard fallback" >>"$_CONTRACT_ERR_FILE"
  fi

  grep -oE '\$\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}' "$body" 2>/dev/null \
    | sed -E 's/^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}$/\1/'
  rm -f "$body"
}

# Print `name<TAB>value` for every key of the top-level `substitutions:` block in one file. The
# block runs from a column-0 `substitutions:` to the next column-0, non-comment content line; only
# direct children are contract keys (a nested mapping is that key's value, not a new key).
_defaults_in_file() {
  # This extractor reads BLOCK-style `substitutions:` only, which is the form every module uses.
  # Flow style (`substitutions: {a: b}`) would be silently skipped, and a skipped default reads as
  # "required" or as a removal — so reject it loudly instead of guessing.
  if grep -qE '^substitutions:[[:space:]]*[{[]' "$1" 2>/dev/null; then
    echo "check-contract-diff: UNSUPPORTED — $1: flow-style 'substitutions:' is not parsed; use block style" >&2
    [ -n "${_CONTRACT_ERR_FILE:-}" ] && echo "$1: flow-style substitutions:" >>"$_CONTRACT_ERR_FILE"
    return 0
  fi
  awk '
    function indent(s){ match(s, /^ */); return RLENGTH }
    /^substitutions:[[:space:]]*(#.*)?$/ { inblk=1; child=-1; next }
    inblk && /^[^ \t#]/                  { inblk=0 }
    inblk {
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      ind = indent($0)
      if (child < 0) child = ind
      if (ind != child) next
      rest = substr($0, ind + 1)
      if (match(rest, /^["'\'']?[A-Za-z_][A-Za-z0-9_]*["'\'']?[[:space:]]*:/)) {
        key = substr(rest, 1, RLENGTH - 1)
        gsub(/[[:space:]"'\'']/, "", key)
        val = substr(rest, RLENGTH + 1)
        print key "\t" val
      }
    }
  ' "$1" 2>/dev/null
}

# Collect refs (into $2) and defaults (into $3) across every YAML file in directory $1.
_collect() {
  local dir="$1" refs="$2" defs="$3" f
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    _refs_in_file "$f" >>"$refs"
    _defaults_in_file "$f" >>"$defs"
  done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
}

# Print the whole contract surface of a tree, sorted and stable:
#   path <relative/path.yaml>
#   required <scope> <name>
#   optional <scope> <name> = <default>
#
# PATHS ARE CONTRACT. A consumer imports a module by URL — `github://c-iot-systems/esphome-sdk/
# modules/controls.yaml@<ref>` — so deleting or renaming a module or board file breaks every config
# importing it, immediately and regardless of substitutions. A module that declares none (as
# controls.yaml does) would otherwise be invisible to this gate entirely.
#
# A name is CONTRACT if it is referenced or defaulted; it is OPTIONAL if a default is reachable in
# its scope and REQUIRED otherwise.
#
# SCOPES MIRROR HOW A CONFIG IS ASSEMBLED. `modules/core.yaml` is the base every networked config
# imports, and every other module and board is a scope layered on it: `core ∪ <file>`. Modules are
# OPT-IN and composed selectively — tests/validate/phone.yaml is explicitly self-contained and
# imports no core — so resolving all of modules/ as one namespace would let a default in one
# module mask a required reference in an unrelated one, and the surface would not move even though
# a consumer importing only the second module breaks. Boards need the same layering in the other
# direction: `framework_variant` and `ota_rollback` are referenced by every board but defaulted in
# core, and are correctly not required.
#
# Residual, deliberately accepted: a name defaulted in core and referenced elsewhere resolves as
# optional. That is right for every config that imports core, and a module that skips core is
# self-contained by construction. Names already stated by the `core` scope are not repeated per
# scope, so a core default change is reported once rather than once per module.
extract_surface() {
  local root="$1" scope f name val rc=0
  local tmp; tmp="$(mktemp -d)"

  local own_err=0
  if [ -z "${_CONTRACT_ERR_FILE:-}" ]; then
    _CONTRACT_ERR_FILE="$tmp/malformed"; : >"$_CONTRACT_ERR_FILE"; own_err=1
  fi

  local core="$root/modules/core.yaml"
  : >"$tmp/crefs"; : >"$tmp/cdefs"
  if [ -f "$core" ]; then
    _refs_in_file "$core" >>"$tmp/crefs"
    _defaults_in_file "$core" >>"$tmp/cdefs"
  fi
  cut -f1 "$tmp/cdefs" | sort -u >"$tmp/cdefn"

  # Emit one scope: names referenced or defaulted in FILES, resolved against core ∪ FILES.
  # `$2` is a file listing names already claimed by an earlier scope, which are skipped.
  _emit_scope() {
    local scope="$1" claimed="$2"; shift 2
    local f name val
    : >"$tmp/srefs"; : >"$tmp/sdefs"
    for f in "$@"; do
      [ -f "$f" ] || continue
      _refs_in_file "$f" >>"$tmp/srefs"
      _defaults_in_file "$f" >>"$tmp/sdefs"
    done
    cut -f1 "$tmp/sdefs" | sort -u >"$tmp/sdefn"
    cat "$tmp/srefs" "$tmp/sdefn" | grep -v '^$' | sort -u >"$tmp/snames"
    while IFS= read -r name; do
      [ -s "$claimed" ] && grep -qxF "$name" "$claimed" && continue
      if grep -qxF "$name" "$tmp/sdefn"; then
        val="$(awk -F'\t' -v k="$name" '$1==k {print $2; exit}' "$tmp/sdefs")"
        printf 'optional %s %s = %s\n' "$scope" "$name" "$(_clean_value "$val")"
      elif grep -qxF "$name" "$tmp/cdefn"; then
        val="$(awk -F'\t' -v k="$name" '$1==k {print $2; exit}' "$tmp/cdefs")"
        printf 'optional %s %s = %s\n' "$scope" "$name" "$(_clean_value "$val")"
      else
        printf 'required %s %s\n' "$scope" "$name"
      fi
    done <"$tmp/snames" | sort -u
  }

  # Every shipped YAML path is a surface entry in its own right.
  for d in "$root/modules" "$root/hardware"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do
      printf 'path %s\n' "${f#"$root"/}"
    done < <(find "$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  done | sort -u

  : >"$tmp/claimed"
  if [ -f "$core" ]; then
    _emit_scope modules/core.yaml "$tmp/claimed" "$core"
    cat "$tmp/crefs" "$tmp/cdefn" | grep -v '^$' | sort -u >"$tmp/claimed"
  fi

  local d
  for d in "$root/modules" "$root/hardware"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do
      [ "$f" = "$core" ] && continue
      # Scope identity is the full repo-relative PATH. A basename stem would make modules/foo.yaml
      # and hardware/foo.yml one scope, so a substitution removed from one would look like it
      # survived in the other.
      _emit_scope "${f#"$root"/}" "$tmp/claimed" "$f"
    done < <(find "$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  done

  if [ "$own_err" -eq 1 ]; then
    [ -s "$_CONTRACT_ERR_FILE" ] && rc=1
    unset _CONTRACT_ERR_FILE
  fi
  rm -rf "$tmp"
  return "$rc"
}

# Materialize a git ref into DIR (whole tree; the repo is small enough that this is cheaper than
# reasoning about which paths exist at that revision).
_extract_ref() {
  local ref="$1" dir="$2"
  mkdir -p "$dir"
  # Both halves must succeed: a silently empty tree would read as "the whole contract was removed"
  # or "nothing changed", depending on which side failed.
  git archive "$ref" 2>/dev/null | tar -x -C "$dir" 2>/dev/null
  local st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ]
}

# ── commit-range inspection ───────────────────────────────────────────────────────────────────

# True iff any commit in BASE..HEAD declares a breaking change, by either Conventional Commits
# marker: `type(scope)!:` in the subject, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer.
_range_declares_breaking() {
  local base="$1" head="$2" subj body
  while IFS= read -r subj; do
    # `!:` must be adjacent — `feat(wifi)! : x` is NOT a valid Conventional Commit subject, and
    # release-please's parser ignores it. Accepting it here would let the gate pass while the
    # released version silently disagreed with the contract change.
    [[ "$subj" =~ ^[a-zA-Z]+(\([^\)]*\))?!: ]] && return 0
  done < <(git log --format='%s' "${base}..${head}" 2>/dev/null)
  body="$(git log --format='%b' "${base}..${head}" 2>/dev/null)"
  grep -qE '^BREAKING[ -]CHANGE:' <<<"$body" && return 0
  return 1
}

# ── the gate ──────────────────────────────────────────────────────────────────────────────────

# Compare two already-extracted surfaces. Prints the classified diff; returns 0 if the change is
# non-breaking, 1 if it is breaking.
compare_surfaces() {
  local base_s="$1" head_s="$2" breaking=0 key val oval scope name
  local tmp; tmp="$(mktemp -d)"

  # keys are "<scope> <name>"; optional entries keep their default in field 2 after the tab.
  sed -nE 's/^required (.*)$/\1/p' "$base_s" | sort -u >"$tmp/breq"
  sed -nE 's/^required (.*)$/\1/p' "$head_s" | sort -u >"$tmp/hreq"
  sed -nE 's/^optional ([^ ]+ [A-Za-z0-9_]+) = (.*)$/\1\t\2/p' "$base_s" | sort -u >"$tmp/bopt"
  sed -nE 's/^optional ([^ ]+ [A-Za-z0-9_]+) = (.*)$/\1\t\2/p' "$head_s" | sort -u >"$tmp/hopt"
  cut -f1 "$tmp/bopt" | sort -u >"$tmp/boptn"; cut -f1 "$tmp/hopt" | sort -u >"$tmp/hoptn"

  _describe() { scope="${1%% *}"; name="${1#* }"; printf "'%s' (%s)" "$name" "$scope"; }

  # a removed or renamed module/board path breaks every config importing it.
  sed -nE 's/^path (.*)$/\1/p' "$base_s" | sort -u >"$tmp/bpath"
  sed -nE 's/^path (.*)$/\1/p' "$head_s" | sort -u >"$tmp/hpath"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$tmp/hpath" && continue
    echo "check-contract-diff: BREAKING — module path '${key}' was removed or renamed — every config importing it fails"
    breaking=1
  done <"$tmp/bpath"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$tmp/bpath" && continue
    echo "check-contract-diff: ok — new module path '${key}'"
  done <"$tmp/hpath"

  # required removed — gone entirely, or relaxed into an optional (relaxation is fine).
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$tmp/hreq" && continue
    if grep -qxF "$key" "$tmp/hoptn"; then
      echo "check-contract-diff: ok — required $(_describe "$key") gained a default (relaxation)"
    else
      echo "check-contract-diff: BREAKING — required substitution $(_describe "$key") was removed or renamed"
      breaking=1
    fi
  done <"$tmp/breq"

  # required added — from nothing, or tightened from an optional.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$tmp/breq" && continue
    if grep -qxF "$key" "$tmp/boptn"; then
      echo "check-contract-diff: BREAKING — optional substitution $(_describe "$key") lost its default and is now required"
    else
      echo "check-contract-diff: BREAKING — new required substitution $(_describe "$key") — existing stored configs do not supply it"
    fi
    breaking=1
  done <"$tmp/hreq"

  # optional removed — silent behaviour change for any config that sets it.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$tmp/hoptn" && continue
    grep -qxF "$key" "$tmp/hreq" && continue   # already reported as "lost its default"
    echo "check-contract-diff: BREAKING — optional substitution $(_describe "$key") was removed or renamed — a config that sets it is now silently ignored"
    breaking=1
  done <"$tmp/boptn"

  # optional added, and default changes.
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    if ! grep -qxF "$key" "$tmp/boptn"; then
      echo "check-contract-diff: ok — new optional substitution $(_describe "$key") (default '${val}')"
      continue
    fi
    oval="$(awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$tmp/bopt")"
    if [ "$oval" != "$val" ]; then
      echo "check-contract-diff: REVIEW — default for $(_describe "$key") changed '${oval}' -> '${val}' — re-pinning changes device behaviour with no config edit"
    fi
  done <"$tmp/hopt"

  rm -rf "$tmp"
  return "$breaking"
}

# Full gate: extract BASE and HEAD surfaces from git, classify, and require a breaking marker in
# the range when the contract change is breaking.
run_gate() {
  local base="$1" head="$2" rc=0 ref
  local tmp; tmp="$(mktemp -d)"

  # Fail CLOSED on anything that would leave the contract unexamined. CI checks out with
  # fetch-depth: 0 and passes explicit SHAs, so an unresolvable ref is a broken invocation, not a
  # benign shallow clone — and skipping here would remove the one safeguard on a permanent tag.
  for ref in "$base" "$head"; do
    if ! git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
      echo "check-contract-diff: FAIL — ref '${ref}' does not resolve to a commit here; the contract was NOT compared."
      echo "check-contract-diff:        CI must check out with fetch-depth: 0 and pass resolvable revisions."
      rm -rf "$tmp"; return 1
    fi
  done

  for ref in base head; do
    local val; val="$([ "$ref" = base ] && printf '%s' "$base" || printf '%s' "$head")"
    if ! _extract_ref "$val" "$tmp/$ref"; then
      echo "check-contract-diff: FAIL — could not extract the tree at '${val}'; the contract was NOT compared."
      rm -rf "$tmp"; return 1
    fi
  done

  : >"$tmp/malformed"; export _CONTRACT_ERR_FILE="$tmp/malformed"
  extract_surface "$tmp/base" >"$tmp/base.surface"
  extract_surface "$tmp/head" >"$tmp/head.surface"
  if [ -s "$_CONTRACT_ERR_FILE" ]; then
    echo "check-contract-diff: FAIL — malformed required-substitution guard(s); the surface is incomplete, so the diff cannot be trusted:"
    sed 's/^/check-contract-diff:        /' "$_CONTRACT_ERR_FILE"
    unset _CONTRACT_ERR_FILE; rm -rf "$tmp"; return 1
  fi
  unset _CONTRACT_ERR_FILE

  echo "check-contract-diff: comparing contract ${base} -> ${head}"
  if compare_surfaces "$tmp/base.surface" "$tmp/head.surface"; then
    echo "check-contract-diff: ok — no breaking contract change in ${base}..${head}"
  else
    if _range_declares_breaking "$base" "$head"; then
      echo "check-contract-diff: ok — breaking contract change is declared by a breaking commit marker in the range"
    else
      echo "check-contract-diff: FAIL — the substitution contract changed in a BREAKING way, but no commit in ${base}..${head} declares it."
      echo "check-contract-diff:        Mark the commit breaking (\`type(scope)!: ...\` or a 'BREAKING CHANGE:' footer) so the"
      echo "check-contract-diff:        released version says so. See README 'Versioning'."
      rc=1
    fi
  fi

  rm -rf "$tmp"
  return "$rc"
}

# ── negative-harness parity ───────────────────────────────────────────────────────────────────

# Assert the derived required set equals the set of tests/negative/omit_<name>.yaml fixtures.
check_negative_parity() {
  local root="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}" rc=0 name
  local tmp; tmp="$(mktemp -d)"

  : >"$tmp/malformed"; export _CONTRACT_ERR_FILE="$tmp/malformed"
  extract_surface "$root" | sed -nE 's/^required [^ ]+ ([A-Za-z0-9_]+)$/\1/p' | sort -u >"$tmp/derived"
  if [ -s "$_CONTRACT_ERR_FILE" ]; then
    echo "check-contract-diff: FAIL — malformed required-substitution guard(s); the required set is incomplete:"
    sed 's/^/check-contract-diff:        /' "$_CONTRACT_ERR_FILE"
    unset _CONTRACT_ERR_FILE; rm -rf "$tmp"; return 1
  fi
  unset _CONTRACT_ERR_FILE
  find "$root/tests/negative" -maxdepth 1 -name 'omit_*.yaml' -printf '%f\n' 2>/dev/null \
    | sed -E 's/^omit_(.*)\.yaml$/\1/' | sort -u >"$tmp/pinned"

  if [ ! -s "$tmp/derived" ] && [ ! -s "$tmp/pinned" ]; then
    echo "check-contract-diff: no required substitutions and no negative fixtures — vacuously ok"
    rm -rf "$tmp"; return 0
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    echo "check-contract-diff: FAIL — required substitution '${name}' has no tests/negative/omit_${name}.yaml fixture"
    rc=1
  done < <(comm -23 "$tmp/derived" "$tmp/pinned")

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    echo "check-contract-diff: FAIL — tests/negative/omit_${name}.yaml pins '${name}' as required, but it is not required by modules/ (stale fixture, or the substitution gained a default)"
    rc=1
  done < <(comm -13 "$tmp/derived" "$tmp/pinned")

  [ "$rc" -eq 0 ] && echo "check-contract-diff: ok — required set and negative harness agree ($(wc -l <"$tmp/derived") substitutions)"
  rm -rf "$tmp"
  return "$rc"
}

# ── release-time gate ─────────────────────────────────────────────────────────────────────────

# Run the gate from the LAST PUBLISHED tag to HEAD.
#
# The tag is resolved from the tags that ACTUALLY EXIST, deliberately not from
# .release-please-manifest.json. On the push that matters most — the release PR's own merge — the
# manifest at HEAD already carries the version being released, whose tag does not exist yet. Reading
# it there would resolve to an absent tag, take the "nothing to compare" path, and skip the gate on
# precisely the commit about to be tagged.
run_since_release() {
  local head="${1:-HEAD}" tag

  # Newest existing vMAJOR.MINOR.PATCH tag by version order.
  tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname 2>/dev/null | head -n1)"

  if [ -z "$tag" ]; then
    echo "check-contract-diff: no published tag yet — nothing to compare against, vacuously ok"
    return 0
  fi

  echo "check-contract-diff: gating the next release against the last published one (${tag})"
  run_gate "$tag" "$head"
}

# ── self-test ─────────────────────────────────────────────────────────────────────────────────

_mkmod() { mkdir -p "$1/modules"; cat >"$1/modules/core.yaml"; }

_expect_cmp() {
  local want="$1" a="$2" b="$3" label="$4"
  if compare_surfaces "$a" "$b" >/dev/null 2>&1; then
    [ "$want" = ok ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected BREAKING, got ok)"; return 1; }
  else
    [ "$want" = breaking ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected ok, got BREAKING)"; return 1; }
  fi
}

# Build a one-commit-per-state git repo and run the whole gate over it.
_expect_gate() {
  local want="$1" subject="$2" label="$3" old="$4" new="$5" repo rc
  repo="$(mktemp -d)"
  (
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email t@t; git config user.name t
    mkdir -p modules
    printf '%s' "$old" >modules/core.yaml
    git add -A && git commit -qm "chore: base"
    printf '%s' "$new" >modules/core.yaml
    git add -A && git commit -qm "$subject"
  ) >/dev/null 2>&1
  ( cd "$repo" && run_gate "HEAD~1" "HEAD" ) >/dev/null 2>&1
  rc=$?
  rm -rf "$repo"
  if [ "$rc" -eq 0 ]; then
    [ "$want" = pass ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected FAIL, got pass)"; return 1; }
  else
    [ "$want" = fail ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected pass, got FAIL)"; return 1; }
  fi
}

self_test() {
  local tmp rc=0 parity_out
  tmp="$(mktemp -d)"

  # --- extraction ---------------------------------------------------------------------------
  _mkmod "$tmp/a" <<'YAML'
substitutions:
  logger_level: NONE
  ota_attempts: "50" # tuned for power events
mqtt:
  broker: "${ mqtt_broker if mqtt_broker is defined else 1/0 }"
  client_id: ${mqtt_client_id}
YAML
  extract_surface "$tmp/a" >"$tmp/a.surface"
  if grep -qx 'required modules/core.yaml mqtt_broker' "$tmp/a.surface" \
     && grep -qx 'optional modules/core.yaml logger_level = NONE' "$tmp/a.surface" \
     && grep -qx 'optional modules/core.yaml ota_attempts = 50' "$tmp/a.surface"; then
    echo "self-test: PASS — surface extracts guards as required and defaults as optional (comment/quotes stripped)"
  else
    echo "self-test: FAILED — surface extraction"; cat "$tmp/a.surface"; rc=1
  fi

  # A PLAIN ${ref} with no default is required too — ESPHome fails on an undefined substitution
  # with or without the guard. This is how device_name is declared.
  if grep -qx 'required modules/core.yaml mqtt_client_id' "$tmp/a.surface"; then
    echo "self-test: PASS — a plain, undefaulted reference is required (the device_name case)"
  else
    echo "self-test: FAILED — plain undefaulted reference not treated as required"; rc=1
  fi

  # A name that is BOTH guarded and defaulted is optional — the default is what a silent consumer
  # gets. This is the ota_http_server_test case.
  _mkmod "$tmp/both" <<'YAML'
substitutions:
  ota_http_server_test: fallback
ota:
  url: "${ ota_http_server_test if ota_http_server_test is defined else 1/0 }"
YAML
  if extract_surface "$tmp/both" | grep -qx 'optional modules/core.yaml ota_http_server_test = fallback'; then
    echo "self-test: PASS — guarded AND defaulted resolves to optional (ota_http_server_test case)"
  else
    echo "self-test: FAILED — guarded+defaulted misclassified"; extract_surface "$tmp/both"; rc=1
  fi

  # A board scope resolves defaults against modules ∪ board: a name referenced only by a board but
  # defaulted in modules/ is NOT required. This is the framework_variant case.
  mkdir -p "$tmp/fw/modules" "$tmp/fw/hardware"
  printf 'substitutions:\n  framework_variant: esp-idf\n' >"$tmp/fw/modules/core.yaml"
  printf 'esphome:\n  framework: ${framework_variant}\n'  >"$tmp/fw/hardware/board.yaml"
  if extract_surface "$tmp/fw" | grep -qx 'optional modules/core.yaml framework_variant = esp-idf'; then
    echo "self-test: PASS — a board reference defaulted in modules/ is not required (framework_variant case)"
  else
    echo "self-test: FAILED — cross-scope default resolution"; extract_surface "$tmp/fw"; rc=1
  fi

  # Boards are separate scopes: the SAME name may carry DIFFERENT pins per board without either
  # collapsing or reading as a changed default.
  mkdir -p "$tmp/a/hardware"
  printf 'substitutions:\n  slot_1_in1: "7"\n'  >"$tmp/a/hardware/hds_v1_0.yaml"
  printf 'substitutions:\n  slot_1_in1: "23"\n' >"$tmp/a/hardware/hds_v1_1.yaml"
  extract_surface "$tmp/a" >"$tmp/a2.surface"
  if grep -qx 'optional hardware/hds_v1_0.yaml slot_1_in1 = 7' "$tmp/a2.surface" \
     && grep -qx 'optional hardware/hds_v1_1.yaml slot_1_in1 = 23' "$tmp/a2.surface"; then
    echo "self-test: PASS — per-board pin tables keep the same name under distinct scopes"
  else
    echo "self-test: FAILED — board scoping"; grep slot_1_in1 "$tmp/a2.surface"; rc=1
  fi
  _expect_cmp ok "$tmp/a2.surface" "$tmp/a2.surface" "a real two-board surface is stable against itself" || rc=1

  # --- classification -----------------------------------------------------------------------
  printf 'optional modules/core.yaml a = 1\nrequired modules/core.yaml r\n'             >"$tmp/base"
  printf 'optional modules/core.yaml a = 1\nrequired modules/core.yaml r\n'             >"$tmp/same"
  _expect_cmp ok "$tmp/base" "$tmp/same" "identical surfaces are non-breaking" || rc=1

  printf 'optional modules/core.yaml a = 1\n'                                  >"$tmp/reqgone"
  _expect_cmp breaking "$tmp/base" "$tmp/reqgone" "removing a required substitution is breaking" || rc=1

  printf 'optional modules/core.yaml a = 1\noptional modules/core.yaml r = x\n'         >"$tmp/relaxed"
  _expect_cmp ok "$tmp/base" "$tmp/relaxed" "a required substitution gaining a default is a relaxation" || rc=1

  printf 'optional modules/core.yaml a = 1\nrequired modules/core.yaml r\nrequired modules/core.yaml n\n' >"$tmp/newreq"
  _expect_cmp breaking "$tmp/base" "$tmp/newreq" "adding a required substitution is breaking" || rc=1

  printf 'required modules/core.yaml a\nrequired modules/core.yaml r\n'                 >"$tmp/tightened"
  _expect_cmp breaking "$tmp/base" "$tmp/tightened" "an optional substitution losing its default is breaking" || rc=1

  printf 'required modules/core.yaml r\n'                                      >"$tmp/optgone"
  _expect_cmp breaking "$tmp/base" "$tmp/optgone" "removing an optional substitution is breaking" || rc=1

  printf 'optional modules/core.yaml a = 1\noptional modules/core.yaml b = 2\nrequired modules/core.yaml r\n' >"$tmp/added"
  _expect_cmp ok "$tmp/base" "$tmp/added" "adding an optional substitution is non-breaking" || rc=1

  printf 'optional modules/core.yaml a = 9\nrequired modules/core.yaml r\n'             >"$tmp/defchg"
  _expect_cmp ok "$tmp/base" "$tmp/defchg" "a changed default is non-breaking (reported, not gated)" || rc=1
  if compare_surfaces "$tmp/base" "$tmp/defchg" | grep -q "REVIEW — default for 'a' (modules/core.yaml) changed"; then
    echo "self-test: PASS — a changed default is reported for review"
  else
    echo "self-test: FAILED — changed default not reported"; rc=1
  fi

  # A pin dropped from ONE board is breaking for that board's consumers even though the name
  # survives on another board — this is what name-only keying would have missed.
  printf 'optional hardware/hds_v1_0.yaml p = 7\noptional hardware/hds_v1_1.yaml p = 23\n' >"$tmp/twoboards"
  printf 'optional hardware/hds_v1_1.yaml p = 23\n'                                        >"$tmp/oneboard"
  _expect_cmp breaking "$tmp/twoboards" "$tmp/oneboard" "dropping a pin from one board is breaking for that board" || rc=1

  # A module that is NOT core gets its own scope, so a default in an unrelated module cannot mask
  # a required reference. Without per-module scoping both files merged into one namespace and the
  # reference in b.yaml resolved against a.yaml's default.
  mkdir -p "$tmp/mask/modules"
  printf 'substitutions:\n  shared_name: fromA\n' >"$tmp/mask/modules/a.yaml"
  printf 'x:\n  y: ${shared_name}\n'              >"$tmp/mask/modules/b.yaml"
  if extract_surface "$tmp/mask" | grep -qx 'required modules/b.yaml shared_name'; then
    echo "self-test: PASS — a default in an unrelated module does not mask a required reference"
  else
    echo "self-test: FAILED — cross-module masking"; extract_surface "$tmp/mask"; rc=1
  fi

  # A malformed guard must FAIL CLOSED, not just warn: it silently drops a name from the surface.
  mkdir -p "$tmp/bad/modules"
  printf 'x:\n  y: "${ alpha if beta is defined else 1/0 }"\n' >"$tmp/bad/modules/core.yaml"
  if extract_surface "$tmp/bad" >/dev/null 2>&1; then
    echo "self-test: FAILED — a malformed guard did not fail closed"; rc=1
  else
    echo "self-test: PASS — a malformed guard fails closed"
  fi

  # A ${ref} inside a commented-out line is dead text, not a contract reference.
  mkdir -p "$tmp/cmt/modules"
  printf 'substitutions:\n  a: "1"\nx:\n  # y: ${ghost_name}\n  z: ${a}\n' >"$tmp/cmt/modules/core.yaml"
  if extract_surface "$tmp/cmt" | grep -q 'ghost_name'; then
    echo "self-test: FAILED — a reference inside a comment was counted"; rc=1
  else
    echo "self-test: PASS — a reference inside a full-line comment is not counted"
  fi

  # An `is defined` guard whose else-branch is not `1/0` supplies a fallback instead of failing, so
  # the name is optional with a default this extractor cannot read. Guessing either way would be
  # wrong; fail closed.
  mkdir -p "$tmp/fallback/modules"
  printf 'x:\n  y: "${ pw if pw is defined else \"public\" }"\n' >"$tmp/fallback/modules/core.yaml"
  if extract_surface "$tmp/fallback" >/dev/null 2>&1; then
    echo "self-test: FAILED — a non-1/0 guard fallback was silently classified"; rc=1
  else
    echo "self-test: PASS — a guard with a non-1/0 fallback fails closed"
  fi

  # Flow-style substitutions are not parsed, so they must be rejected rather than silently skipped.
  mkdir -p "$tmp/flow/modules"
  printf 'substitutions: {a: 1}\nx:\n  y: ${a}\n' >"$tmp/flow/modules/core.yaml"
  if extract_surface "$tmp/flow" >/dev/null 2>&1; then
    echo "self-test: FAILED — flow-style substitutions were silently accepted"; rc=1
  else
    echo "self-test: PASS — flow-style substitutions fail closed rather than being skipped"
  fi

  # A module that declares no substitutions is still contract: its PATH is what consumers import.
  mkdir -p "$tmp/paths/modules"
  printf 'binary_sensor:\n  - platform: gpio\n' >"$tmp/paths/modules/controls.yaml"
  if extract_surface "$tmp/paths" | grep -qx 'path modules/controls.yaml'; then
    echo "self-test: PASS — a substitution-free module still appears on the surface as a path"
  else
    echo "self-test: FAILED — module path missing from the surface"; extract_surface "$tmp/paths"; rc=1
  fi
  printf 'path modules/controls.yaml\npath modules/core.yaml\n' >"$tmp/p_before"
  printf 'path modules/core.yaml\n'                              >"$tmp/p_after"
  _expect_cmp breaking "$tmp/p_before" "$tmp/p_after" "removing a module path is breaking" || rc=1
  _expect_cmp ok "$tmp/p_after" "$tmp/p_before" "adding a module path is non-breaking" || rc=1

  # --- negative-harness parity ----------------------------------------------------------------
  mkdir -p "$tmp/par/modules" "$tmp/par/tests/negative"
  printf 'esphome:\n  name: ${device_name}\n' >"$tmp/par/modules/core.yaml"
  : >"$tmp/par/tests/negative/omit_device_name.yaml"
  if check_negative_parity "$tmp/par" >/dev/null 2>&1; then
    echo "self-test: PASS — parity holds when every required name has its negative fixture"
  else
    echo "self-test: FAILED — parity rejected a matching pair"; rc=1
  fi
  printf 'mqtt:\n  port: ${mqtt_port}\n' >"$tmp/par/modules/mqtt.yaml"
  if check_negative_parity "$tmp/par" >/dev/null 2>&1; then
    echo "self-test: FAILED — parity accepted a required name with no negative fixture"; rc=1
  else
    echo "self-test: PASS — a required name with no negative fixture is rejected"
  fi
  : >"$tmp/par/tests/negative/omit_ghost.yaml"
  # Capture first: under `pipefail` a failing function would sink the pipeline even on a grep hit.
  parity_out="$(check_negative_parity "$tmp/par" 2>&1)"
  if grep -q "stale fixture" <<<"$parity_out"; then
    echo "self-test: PASS — a negative fixture with no matching required name is rejected as stale"
  else
    echo "self-test: FAILED — stale negative fixture not detected"; rc=1
  fi

  # An unresolvable ref must FAIL, not skip — skipping would silently drop the safeguard.
  if ( cd "$tmp" && run_gate "definitely-not-a-ref" "HEAD" ) >/dev/null 2>&1; then
    echo "self-test: FAILED — an unresolvable base ref was treated as a pass"; rc=1
  else
    echo "self-test: PASS — an unresolvable ref fails closed instead of skipping"
  fi

  # With no released tag yet there is nothing to compare against — vacuous, not a masked failure.
  if run_since_release >/dev/null 2>&1; then
    echo "self-test: PASS — --since-release is vacuously ok before the first tag exists"
  else
    echo "self-test: FAILED — --since-release did not handle the pre-first-release case"; rc=1
  fi

  # --- the gate over real commits -------------------------------------------------------------
  local OLD NEW_RENAMED NEW_ADDED
  OLD=$'substitutions:\n  wifi_ssid: ""\n'
  NEW_RENAMED=$'substitutions:\n  wifi_network: ""\n'
  NEW_ADDED=$'substitutions:\n  wifi_ssid: ""\n  wifi_ssid_2: ""\n'

  _expect_gate fail "feat(wifi): rename the ssid substitution" \
    "a breaking rename committed as plain feat is rejected" "$OLD" "$NEW_RENAMED" || rc=1
  _expect_gate pass "feat(wifi)!: rename the ssid substitution" \
    "the same rename marked with ! is accepted" "$OLD" "$NEW_RENAMED" || rc=1
  _expect_gate pass "feat(wifi): add a second station slot" \
    "a non-breaking addition needs no marker" "$OLD" "$NEW_ADDED" || rc=1
  # `! :` is not a valid Conventional Commit subject and release-please ignores it, so the gate
  # must not accept it either — otherwise the gate passes while the version disagrees.
  _expect_gate fail "feat(wifi)! : rename the ssid substitution" \
    "a detached '! :' marker is not accepted as breaking" "$OLD" "$NEW_RENAMED" || rc=1
  _expect_gate pass "feat(wifi): rename the ssid substitution

BREAKING CHANGE: wifi_ssid is now wifi_network" \
    "a BREAKING CHANGE footer is accepted as breaking" "$OLD" "$NEW_RENAMED" || rc=1

  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "self-test: all checks passed" || echo "self-test: FAILURES above"
  return "$rc"
}

# ── entrypoint ────────────────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --self-test) self_test; return "$?" ;;
    --surface)   extract_surface "${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"; return "$?" ;;
    --negative-parity) check_negative_parity "${2:-}"; return "$?" ;;
    --since-release)   run_since_release "${2:-HEAD}"; return "$?" ;;
  esac
  run_gate "${1:-origin/main}" "${2:-HEAD}"
}

main "$@"
