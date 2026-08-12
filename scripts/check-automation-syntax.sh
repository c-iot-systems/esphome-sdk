#!/usr/bin/env bash
#
# check-automation-syntax.sh — enforce the explicit-list-syntax invariant for automations.
#
# Package merging (esphome/config_helpers.py) happens on RAW YAML, before ESPHome's schema
# normalizes a single-automation mapping into a list. So two modules that each write an
# automation trigger (on_boot, on_connect, ...) in the *mapping* form:
#
#     on_boot:
#       priority: 600
#       then: [...]
#
# merge as DICTS: `priority` is overwritten by the last module and only the nested `then:`
# lists concatenate, silently collapsing two automations into one at the wrong priority.
# The *sequence* form is required:
#
#     on_boot:
#       - priority: 600
#         then: [...]
#
# This check fails when ANY `on_*` key in modules/ or hardware/ uses the mapping form. It is
# deliberately not a fixed allow-list of trigger names: every automation-shaped `on_*` key is
# subject to the same silent-collapse failure, so every one is checked.
#
# Usage:
#   check-automation-syntax.sh [ROOT]   # scan ROOT/modules and ROOT/hardware (default: repo root)
#   check-automation-syntax.sh --self-test
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The awk program that flags mapping-form on_* keys. Reads one or more YAML files.
# Exit status is non-zero if any violation was printed.
read -r -d '' AWK_PROG <<'AWK' || true
{
  raw = $0
  sub(/\r$/, "", raw)                        # tolerate CRLF
  match(raw, /^[ ]*/); indent = RLENGTH      # raw leading spaces (YAML indent is spaces-only)
  trimmed = substr(raw, indent + 1)
  is_blank   = (trimmed ~ /^$/)
  is_comment = (trimmed ~ /^#/)

  # Resolve a pending on_* key against its first real child line. key_indent is the COLUMN of the
  # key name (past any leading "- " sequence marker), so a sibling in the same list-item mapping
  # (indented to the marker's content, not deeper) is correctly seen as a dedent, not a child.
  if (pending) {
    if (is_blank || is_comment) { next }
    if (indent > key_indent) {
      if (trimmed ~ /^-([ ]|$)/) {
        # sequence form -> OK
      } else {
        printf "%s:%d: %s uses the mapping form; automations must use explicit list syntax (- priority: ...)\n", FILENAME, key_line, key_name
        fail = 1
      }
      pending = 0
      # a child line is never itself a top-of-block on_* key we must re-open, fall through
    } else {
      pending = 0                            # empty/# dedented block; re-evaluate this line below
    }
  }

  if (is_blank || is_comment) { next }

  # Normalize the line so every valid YAML spelling of an automation key is classified the same:
  #   - a leading "- " sequence marker ( "- on_press:" puts the key on the list-item line )
  #   - a single- or double-quoted key   ( "'on_press':" / '"on_press":' )
  #   - whitespace before the colon       ( "on_error :" )
  # key_col is the column where the key name starts, used as the child-indent baseline above.
  keytext = trimmed
  key_col = indent
  if (match(keytext, /^-+[ \t]+/)) {           # one or more dashes then whitespace
    key_col = indent + RLENGTH
    keytext = substr(keytext, RLENGTH + 1)
  }
  q = ""
  if (keytext ~ /^['"]/) { q = substr(keytext, 1, 1); keytext = substr(keytext, 2) }

  # on_* key? (any automation-shaped name; deliberately not a fixed allow-list)
  if (match(keytext, /^on_[a-z0-9_]+/)) {
    key_name = substr(keytext, 1, RLENGTH)
    after    = substr(keytext, RLENGTH + 1)
    if (q != "") {
      if (substr(after, 1, 1) != q) { next }   # opening quote never closed on the key -> not a key
      after = substr(after, 2)
    }
    if (after !~ /^[ \t]*:/) { next }          # no mapping colon -> a scalar like `on_foo` in a value
    sub(/^[ \t]*:/, "", after)                 # drop optional whitespace and the colon
    rest = after
    sub(/^[ \t]+/, "", rest)                   # trim leading whitespace
    sub(/^[&!][^ \t]+[ \t]*/, "", rest)        # strip a leading YAML anchor (&x) or tag (!x)
    sub(/[ \t]*#.*$/, "", rest)                # strip a trailing comment
    sub(/[ \t]+$/, "", rest)

    if (rest == "") {
      # nothing (or only an anchor/tag) after the key -> block form, inspect its child next.
      key_indent = key_col
      key_line   = NR
      pending    = 1
      next
    }
    if (rest ~ /^\{/) {
      # inline flow mapping ( on_x: { ... } ) -> mapping form, flag immediately.
      printf "%s:%d: %s uses an inline mapping form; automations must use explicit list syntax\n", FILENAME, NR, key_name
      fail = 1
      next
    }
    # rest starts with '[' (flow sequence) or another scalar -> not a mapping we can flag.
    next
  }
}
END { exit fail }
AWK

scan_root() {
  local root="$1"
  local files=()
  local d f
  for d in modules hardware; do
    [ -d "$root/$d" ] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find "$root/$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  done
  if [ "${#files[@]}" -eq 0 ]; then
    return 0    # empty scaffold: nothing to check, and that is a pass
  fi
  awk "$AWK_PROG" "${files[@]}"
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"

  # GOOD fixture: sequence form for a spread of triggers well beyond on_boot/on_connect.
  mkdir -p "$tmp/modules" "$tmp/hardware"
  cat >"$tmp/modules/good.yaml" <<'YAML'
esphome:
  on_boot:
    - priority: 600
      then:
        - logger.log: booted
  on_shutdown:
    - then:
        - logger.log: bye
wifi:
  on_connect:
    - then:
        - logger.log: up
  on_disconnect:
    - then:
        - logger.log: down
sensor:
  - platform: template
    on_value:
      - then:
          - logger.log: v
mqtt:
  on_message:
    - topic: t
      then:
        - logger.log: m
binary_sensor:
  - platform: gpio
    on_press:
      - then:
          - logger.log: p
ota:
  on_error:
    - then:
        - logger.log: e
button:
  - platform: template
    on_press: &shared_press   # anchored sequence is still the list form
      - then:
          - logger.log: anchored
YAML
  cat >"$tmp/hardware/good_flow.yaml" <<'YAML'
sensor:
  - platform: template
    on_value: []      # inline flow sequence is also acceptable
YAML

  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: PASS on good fixtures (sequence form) — ok"
  else
    echo "self-test: FAILED — good fixtures were rejected"; rc=1
  fi

  # BAD fixtures: mapping form, one per trigger, each proven to fail on its own.
  local trig
  for trig in on_disconnect on_message on_press on_error on_boot; do
    rm -f "$tmp/modules/bad.yaml"
    cat >"$tmp/modules/bad.yaml" <<YAML
component:
  ${trig}:
    priority: 600
    then:
      - logger.log: nope
YAML
    if scan_root "$tmp" >/dev/null 2>&1; then
      echo "self-test: FAILED — mapping form of ${trig} was NOT rejected"; rc=1
    else
      echo "self-test: PASS on bad fixture (${trig} mapping form rejected) — ok"
    fi
  done
  rm -f "$tmp/modules/bad.yaml"

  # BAD fixture: inline flow mapping form.
  cat >"$tmp/modules/bad_flow.yaml" <<'YAML'
component:
  on_press: { then: [logger.log: nope] }
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — inline mapping form was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (inline mapping form rejected) — ok"
  fi
  rm -f "$tmp/modules/bad_flow.yaml"

  # BAD fixture: anchored mapping form ( on_x: &anchor then a mapping child ).
  cat >"$tmp/modules/bad_anchor.yaml" <<'YAML'
component:
  on_press: &handler
    priority: 600
    then:
      - logger.log: nope
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — anchored mapping form was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (anchored mapping form rejected) — ok"
  fi
  rm -f "$tmp/modules/bad_anchor.yaml"

  # BAD fixture: whitespace before the colon ( on_error : ) still a mapping-form key.
  cat >"$tmp/modules/bad_spaced.yaml" <<'YAML'
component:
  on_error :
    priority: 600
    then:
      - logger.log: nope
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — spaced-colon mapping form was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (spaced-colon mapping form rejected) — ok"
  fi
  rm -f "$tmp/modules/bad_spaced.yaml"

  # BAD fixture: a quoted key ( "on_press": ) in mapping form.
  cat >"$tmp/modules/bad_quoted.yaml" <<'YAML'
component:
  "on_press":
    priority: 600
    then:
      - logger.log: nope
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — quoted-key mapping form was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (quoted-key mapping form rejected) — ok"
  fi
  rm -f "$tmp/modules/bad_quoted.yaml"

  # BAD fixture: the key shares the list-item line ( - on_press: ) with a mapping child.
  cat >"$tmp/modules/bad_listitem.yaml" <<'YAML'
binary_sensor:
  - platform: gpio
    triggers:
      - on_press:
          priority: 600
          then:
            - logger.log: nope
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — list-item mapping form was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (list-item mapping form rejected) — ok"
  fi
  rm -f "$tmp/modules/bad_listitem.yaml"

  # GOOD fixture: the same quoted and list-item spellings in the SEQUENCE form must pass.
  cat >"$tmp/modules/good_spellings.yaml" <<'YAML'
component:
  "on_press":
    - then:
        - logger.log: ok
  on_error :
    - then:
        - logger.log: ok
switches:
  - platform: gpio
    triggers:
      - on_press:
          - then:
              - logger.log: ok
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: PASS on good fixture (quoted/spaced/list-item sequence form accepted) — ok"
  else
    echo "self-test: FAILED — good quoted/spaced/list-item sequence form was rejected"; rc=1
  fi
  rm -f "$tmp/modules/good_spellings.yaml"

  rm -rf "$tmp"
  return "$rc"
}

main() {
  case "${1:-}" in
    --self-test) self_test ;;
    "" ) # default: scan the repo root (parent of scripts/)
         scan_root "$(dirname "$SCRIPT_DIR")" ;;
    * )  scan_root "$1" ;;
  esac
}

main "$@"
