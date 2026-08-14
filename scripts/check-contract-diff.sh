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
# Usage:
#   check-contract-diff.sh [BASE [HEAD]]   # default: origin/main HEAD
#   check-contract-diff.sh --surface [ROOT]
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
  while IFS= read -r hit; do
    a="$(printf '%s' "$hit" | sed -E 's/^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
    b="$(printf '%s' "$hit" | sed -E 's/.*[[:space:]]if[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+is[[:space:]]+defined.*/\1/')"
    if [ "$a" != "$b" ]; then
      echo "check-contract-diff: MALFORMED — ${file}: guard '${hit}' names '${a}' but tests '${b}'" >&2
      continue
    fi
    printf '%s\n' "$a"
  done < <(grep -oE '\$\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+if[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+is[[:space:]]+defined' "$file" 2>/dev/null)

  grep -oE '\$\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}' "$file" 2>/dev/null \
    | sed -E 's/^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}$/\1/'
}

# Print `name<TAB>value` for every key of the top-level `substitutions:` block in one file. The
# block runs from a column-0 `substitutions:` to the next column-0, non-comment content line; only
# direct children are contract keys (a nested mapping is that key's value, not a new key).
_defaults_in_file() {
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
#   required <scope> <name>
#   optional <scope> <name> = <default>
#
# A name is CONTRACT if it is referenced or defaulted; it is OPTIONAL if a default is reachable in
# its scope and REQUIRED otherwise. Scopes follow how a config is actually assembled: `modules`
# resolves within modules/ alone, and each board resolves against modules/ PLUS that one board —
# which is why `framework_variant`, referenced by every board but defaulted in modules/core.yaml,
# is not required. A name already carried by the `modules` scope is not repeated per board, so a
# module-level default change is reported once rather than once per board.
extract_surface() {
  local root="$1" scope f name val
  local tmp; tmp="$(mktemp -d)"

  : >"$tmp/mrefs"; : >"$tmp/mdefs"
  _collect "$root/modules" "$tmp/mrefs" "$tmp/mdefs"
  cut -f1 "$tmp/mdefs" | sort -u >"$tmp/mdefn"

  # names owned by the modules scope: everything referenced or defaulted there.
  cat "$tmp/mrefs" "$tmp/mdefn" | grep -v '^$' | sort -u >"$tmp/mnames"
  while IFS= read -r name; do
    if grep -qxF "$name" "$tmp/mdefn"; then
      val="$(awk -F'\t' -v k="$name" '$1==k {print $2; exit}' "$tmp/mdefs")"
      printf 'optional modules %s = %s\n' "$name" "$(_clean_value "$val")"
    else
      printf 'required modules %s\n' "$name"
    fi
  done <"$tmp/mnames" | sort -u

  # each board is its own scope, resolving against modules ∪ board.
  [ -d "$root/hardware" ] || { rm -rf "$tmp"; return 0; }
  while IFS= read -r -d '' f; do
    scope="$(basename "$f")"; scope="${scope%.*}"
    : >"$tmp/brefs"; : >"$tmp/bdefs"
    _refs_in_file "$f" >>"$tmp/brefs"
    _defaults_in_file "$f" >>"$tmp/bdefs"
    cut -f1 "$tmp/bdefs" | sort -u >"$tmp/bdefn"

    cat "$tmp/brefs" "$tmp/bdefn" | grep -v '^$' | sort -u >"$tmp/bnames"
    while IFS= read -r name; do
      grep -qxF "$name" "$tmp/mnames" && continue        # already stated by the modules scope
      if grep -qxF "$name" "$tmp/bdefn"; then
        val="$(awk -F'\t' -v k="$name" '$1==k {print $2; exit}' "$tmp/bdefs")"
        printf 'optional %s %s = %s\n' "$scope" "$name" "$(_clean_value "$val")"
      else
        printf 'required %s %s\n' "$scope" "$name"
      fi
    done <"$tmp/bnames" | sort -u
  done < <(find "$root/hardware" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)

  rm -rf "$tmp"
}

# Materialize a git ref into DIR (whole tree; the repo is small enough that this is cheaper than
# reasoning about which paths exist at that revision).
_extract_ref() {
  local ref="$1" dir="$2"
  mkdir -p "$dir"
  git archive "$ref" 2>/dev/null | tar -x -C "$dir" 2>/dev/null
}

# ── commit-range inspection ───────────────────────────────────────────────────────────────────

# True iff any commit in BASE..HEAD declares a breaking change, by either Conventional Commits
# marker: `type(scope)!:` in the subject, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer.
_range_declares_breaking() {
  local base="$1" head="$2" subj body
  while IFS= read -r subj; do
    [[ "$subj" =~ ^[a-zA-Z]+(\([^\)]*\))?![[:space:]]*: ]] && return 0
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
  local base="$1" head="$2" rc=0
  local tmp; tmp="$(mktemp -d)"

  if ! git rev-parse --verify --quiet "$base" >/dev/null; then
    echo "check-contract-diff: SKIP — base ref '${base}' is not resolvable here (shallow clone?); contract diff not evaluated"
    rm -rf "$tmp"; return 0
  fi

  _extract_ref "$base" "$tmp/base"
  _extract_ref "$head" "$tmp/head"
  extract_surface "$tmp/base" >"$tmp/base.surface"
  extract_surface "$tmp/head" >"$tmp/head.surface"

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

  extract_surface "$root" | sed -nE 's/^required modules ([A-Za-z0-9_]+)$/\1/p' | sort -u >"$tmp/derived"
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
  if grep -qx 'required modules mqtt_broker' "$tmp/a.surface" \
     && grep -qx 'optional modules logger_level = NONE' "$tmp/a.surface" \
     && grep -qx 'optional modules ota_attempts = 50' "$tmp/a.surface"; then
    echo "self-test: PASS — surface extracts guards as required and defaults as optional (comment/quotes stripped)"
  else
    echo "self-test: FAILED — surface extraction"; cat "$tmp/a.surface"; rc=1
  fi

  # A PLAIN ${ref} with no default is required too — ESPHome fails on an undefined substitution
  # with or without the guard. This is how device_name is declared.
  if grep -qx 'required modules mqtt_client_id' "$tmp/a.surface"; then
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
  if [ "$(extract_surface "$tmp/both")" = "optional modules ota_http_server_test = fallback" ]; then
    echo "self-test: PASS — guarded AND defaulted resolves to optional (ota_http_server_test case)"
  else
    echo "self-test: FAILED — guarded+defaulted misclassified"; extract_surface "$tmp/both"; rc=1
  fi

  # A board scope resolves defaults against modules ∪ board: a name referenced only by a board but
  # defaulted in modules/ is NOT required. This is the framework_variant case.
  mkdir -p "$tmp/fw/modules" "$tmp/fw/hardware"
  printf 'substitutions:\n  framework_variant: esp-idf\n' >"$tmp/fw/modules/core.yaml"
  printf 'esphome:\n  framework: ${framework_variant}\n'  >"$tmp/fw/hardware/board.yaml"
  if [ "$(extract_surface "$tmp/fw")" = "optional modules framework_variant = esp-idf" ]; then
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
  if grep -qx 'optional hds_v1_0 slot_1_in1 = 7' "$tmp/a2.surface" \
     && grep -qx 'optional hds_v1_1 slot_1_in1 = 23' "$tmp/a2.surface"; then
    echo "self-test: PASS — per-board pin tables keep the same name under distinct scopes"
  else
    echo "self-test: FAILED — board scoping"; grep slot_1_in1 "$tmp/a2.surface"; rc=1
  fi
  _expect_cmp ok "$tmp/a2.surface" "$tmp/a2.surface" "a real two-board surface is stable against itself" || rc=1

  # --- classification -----------------------------------------------------------------------
  printf 'optional modules a = 1\nrequired modules r\n'             >"$tmp/base"
  printf 'optional modules a = 1\nrequired modules r\n'             >"$tmp/same"
  _expect_cmp ok "$tmp/base" "$tmp/same" "identical surfaces are non-breaking" || rc=1

  printf 'optional modules a = 1\n'                                  >"$tmp/reqgone"
  _expect_cmp breaking "$tmp/base" "$tmp/reqgone" "removing a required substitution is breaking" || rc=1

  printf 'optional modules a = 1\noptional modules r = x\n'         >"$tmp/relaxed"
  _expect_cmp ok "$tmp/base" "$tmp/relaxed" "a required substitution gaining a default is a relaxation" || rc=1

  printf 'optional modules a = 1\nrequired modules r\nrequired modules n\n' >"$tmp/newreq"
  _expect_cmp breaking "$tmp/base" "$tmp/newreq" "adding a required substitution is breaking" || rc=1

  printf 'required modules a\nrequired modules r\n'                 >"$tmp/tightened"
  _expect_cmp breaking "$tmp/base" "$tmp/tightened" "an optional substitution losing its default is breaking" || rc=1

  printf 'required modules r\n'                                      >"$tmp/optgone"
  _expect_cmp breaking "$tmp/base" "$tmp/optgone" "removing an optional substitution is breaking" || rc=1

  printf 'optional modules a = 1\noptional modules b = 2\nrequired modules r\n' >"$tmp/added"
  _expect_cmp ok "$tmp/base" "$tmp/added" "adding an optional substitution is non-breaking" || rc=1

  printf 'optional modules a = 9\nrequired modules r\n'             >"$tmp/defchg"
  _expect_cmp ok "$tmp/base" "$tmp/defchg" "a changed default is non-breaking (reported, not gated)" || rc=1
  if compare_surfaces "$tmp/base" "$tmp/defchg" | grep -q "REVIEW — default for 'a' (modules) changed"; then
    echo "self-test: PASS — a changed default is reported for review"
  else
    echo "self-test: FAILED — changed default not reported"; rc=1
  fi

  # A pin dropped from ONE board is breaking for that board's consumers even though the name
  # survives on another board — this is what name-only keying would have missed.
  printf 'optional hds_v1_0 p = 7\noptional hds_v1_1 p = 23\n'      >"$tmp/twoboards"
  printf 'optional hds_v1_1 p = 23\n'                                >"$tmp/oneboard"
  _expect_cmp breaking "$tmp/twoboards" "$tmp/oneboard" "dropping a pin from one board is breaking for that board" || rc=1

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

  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "self-test: all checks passed" || echo "self-test: FAILURES above"
  return "$rc"
}

# ── entrypoint ────────────────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --self-test) self_test; return "$?" ;;
    --surface)   extract_surface "${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"; return 0 ;;
    --negative-parity) check_negative_parity "${2:-}"; return "$?" ;;
  esac
  run_gate "${1:-origin/main}" "${2:-HEAD}"
}

main "$@"
