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
  match(raw, /^[ ]*/); indent = RLENGTH
  trimmed = substr(raw, indent + 1)
  is_blank   = (trimmed ~ /^$/)
  is_comment = (trimmed ~ /^#/)

  # Resolve a pending on_* key against its first real child line.
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

  # on_* key with nothing meaningful after the colon -> block form, inspect its child next.
  if (trimmed ~ /^on_[a-z0-9_]+:[ \t]*(#.*)?$/) {
    key_indent = indent
    key_line   = NR
    key_name   = trimmed; sub(/:.*$/, "", key_name)
    pending    = 1
    next
  }

  # on_* key with an inline flow mapping ( on_x: { ... } ) -> mapping form, flag immediately.
  if (trimmed ~ /^on_[a-z0-9_]+:[ \t]*\{/) {
    kn = trimmed; sub(/:.*$/, "", kn)
    printf "%s:%d: %s uses an inline mapping form; automations must use explicit list syntax\n", FILENAME, NR, kn
    fail = 1
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
