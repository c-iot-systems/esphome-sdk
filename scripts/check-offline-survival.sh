#!/usr/bin/env bash
#
# check-offline-survival.sh — enforce the offline-survival invariant on reboot_timeout defaults.
#
# THE INVARIANT (product requirement, see README + modules/core.yaml): a device MUST continue
# operating indefinitely while offline, WITHOUT rebooting. Field devices on unreliable uplinks must
# ride out an outage rather than power-cycle through it. In
# ESPHome, `reboot_timeout: 0s` DISABLES the connectivity reboot outright (both wifi and mqtt guard
# App.reboot() with `reboot_timeout_ != 0`), so both timeouts default to 0s here. ESPHome's stock
# default is 15min. This gate fails the build if any `reboot_timeout` under modules/ or hardware/
# resolves to a NON-ZERO default, so the regression can never silently return.
#
# It enforces BOTH halves of the contract, per top-level component block (quote-aware):
#   (a) every `reboot_timeout:` key resolves to a ZERO default. A literal duration must be zero; a
#       `${substitution}` reference is resolved to that substitution's in-file default. Zero means a
#       numeric value of 0 in any unit (0, 0s, 0ms, 0.0s); "0.5s", "15min", "500ms" are NON-zero.
#   (b) every declared CONNECTIVITY COMPONENT (`wifi:` / `mqtt:`) wires an active `reboot_timeout`
#       key INSIDE ITS OWN BLOCK. Otherwise deleting/commenting the key silently restores ESPHome's
#       non-zero stock default (15min) and the gate would go blind. Scoped per-component so a file
#       carrying both wifi and mqtt cannot satisfy mqtt with wifi's key.
#
# Robustness: comment lines never count; keys may be quoted (`"wifi":`, `'reboot_timeout':`); the
# presence check reads each component's own block, not the whole file. Modules are introduced
# incrementally across the SDK branch chain, so a file with no reboot_timeout key and no connectivity
# component (e.g. the SDK-1 scaffold, which has no modules) is a vacuous PASS — the self-test proves
# every FAIL path so this is no silent no-op.
#
# Usage:
#   check-offline-survival.sh [ROOT]     # scan ROOT/modules and ROOT/hardware (default: repo root)
#   check-offline-survival.sh --self-test
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Connectivity components whose reboot_timeout the offline invariant depends on.
CONNECTIVITY_COMPONENTS="wifi mqtt"

# ── low-level value helpers ───────────────────────────────────────────────────────────────────

# Strip surrounding quotes and whitespace from a scalar.
_unquote() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"        # ltrim
  v="${v%"${v##*[![:space:]]}"}"        # rtrim
  if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# True iff $1 is a zero-valued duration. The numeric part is everything up to the first unit letter
# and MAY carry a decimal point — ESPHome accepts fractional durations (e.g. 0.5s). Zero iff the
# numeric part contains a digit and NO non-zero digit: "0", "0s", "0.0s", "00ms" are zero, but
# "0.5s", "15min", "500ms" are NOT. A value with no numeric part (e.g. unresolved "${x}") is NOT zero.
_is_zero_duration() {
  local v; v="$(_unquote "$1")"
  local num="${v%%[a-zA-Z]*}"           # numeric part (before the unit); may contain '.'
  [[ "$num" =~ ^[0-9.]+$ ]] || return 1 # digits/dot only — rejects "", "${x}", junk
  [[ "$num" =~ [1-9] ]] && return 1     # any non-zero digit -> non-zero duration
  [[ "$num" =~ [0-9] ]]                 # must contain at least one digit
}

# Resolve a reboot_timeout RHS to its effective default. A `${name}` reference is looked up as
# `name`'s substitution default in the SAME file (quote-aware); a literal is returned as-is. Prints
# the resolved value (empty if a `${name}` reference has no in-file default).
_resolve_value() {
  local raw="$1" file="$2" v name def
  v="${raw%%#*}"                        # drop trailing inline comment
  v="$(_unquote "$v")"
  if [[ "$v" =~ ^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}$ ]]; then
    name="${BASH_REMATCH[1]}"
    # First mapping line `<name>: <value>` (optionally quoted key) — the substitution default.
    def="$(grep -oE "^[[:space:]]*[\"']?${name}[\"']?[[:space:]]*:[[:space:]]*[^#]+" "$file" 2>/dev/null | head -n1 \
             | sed -E "s/^[[:space:]]*[\"']?${name}[\"']?[[:space:]]*:[[:space:]]*//")"
    _unquote "$def"
  else
    printf '%s' "$v"
  fi
}

# ── structural helpers ────────────────────────────────────────────────────────────────────────

# Anchored, quote-aware, comment-safe match for an ACTIVE `reboot_timeout:` mapping key. A comment
# line (`# reboot_timeout: ...`) never matches: after leading space the first token is `#`, not the
# (optionally quoted) key. `wifi_reboot_timeout:` never matches either: the key must follow the
# leading space/quote directly.
_RT_KEY_RE='^[[:space:]]*["'\'']?reboot_timeout["'\'']?[[:space:]]*:'

# Top-level component key, quote-aware, at column 0.
_comp_key_re() { printf '^["'\'']?%s["'\'']?[[:space:]]*:' "$1"; }

# True iff file $1 declares top-level component $2.
_file_has_component() { grep -qE "$(_comp_key_re "$2")" "$1" 2>/dev/null; }

# True iff component $2's OWN top-level block in file $1 has a DIRECT reboot_timeout child. The
# block runs from the component key line to the next column-0, non-comment content line. A match must
# be a real mapping key at the component's direct-child indentation — NOT text buried in a deeper
# block scalar (e.g. `ssid: |` content) or a nested sub-block, which sit at a greater indent. This is
# ESPHome-correct: reboot_timeout is a direct option of wifi:/mqtt:, at the same indent as ssid/broker.
_component_has_reboot_timeout() {
  local file="$1" comp="$2"
  awk -v start="$(_comp_key_re "$comp")" '
    function indent(s){ match(s, /^ */); return RLENGTH }
    $0 ~ start { inblk=1; child=-1; next }
    inblk {
      if ($0 ~ /^[^ \t#]/)               { inblk=0; next }   # next top-level construct ends the block
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next           # blank or comment
      ind = indent($0)
      if (child < 0) child = ind                             # first real child sets the direct-child indent
      if (ind == child) {
        rest = substr($0, ind + 1)
        if (rest ~ /^["'\'']?reboot_timeout["'\'']?[ \t]*:/) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# ── scanning ──────────────────────────────────────────────────────────────────────────────────

# Check every active reboot_timeout key in one file resolves to a zero default. Prints one line per
# key; returns non-zero if any resolves non-zero (or unresolvable).
scan_file_values() {
  local file="$1" rc=0 lineno content value resolved
  while IFS= read -r line; do
    lineno="${line%%:*}"
    content="${line#*:}"
    value="$(printf '%s\n' "$content" | sed -E "s/${_RT_KEY_RE}[[:space:]]*//")"
    resolved="$(_resolve_value "$value" "$file")"
    if [[ -z "$resolved" ]]; then
      echo "check-offline-survival: FAIL — ${file}:${lineno}: reboot_timeout '$(_unquote "$value")' has no resolvable in-repo default (must default to 0s)"
      rc=1
    elif _is_zero_duration "$resolved"; then
      echo "check-offline-survival: ok — ${file}:${lineno}: reboot_timeout default resolves to '${resolved}' (reboot disabled)"
    else
      echo "check-offline-survival: FAIL — ${file}:${lineno}: reboot_timeout default resolves to '${resolved}' (non-zero — a device would reboot ${resolved} into an outage)"
      rc=1
    fi
  done < <(grep -nE "$_RT_KEY_RE" "$file" 2>/dev/null)
  return "$rc"
}

# Scan ROOT/modules and ROOT/hardware. Enforces (a) values resolve to 0s and (b) each connectivity
# component wires its own active reboot_timeout. Zero of both across the tree is a vacuous PASS.
scan_root() {
  local root="$1" rc=0 found=0 f comp
  local -a dirs=("$root/modules" "$root/hardware")
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do
      # (a) every reboot_timeout key present must resolve to 0s.
      if grep -qE "$_RT_KEY_RE" "$f" 2>/dev/null; then
        found=1
        scan_file_values "$f" || rc=1
      fi
      # (b) each declared connectivity component must wire its OWN active reboot_timeout.
      for comp in $CONNECTIVITY_COMPONENTS; do
        if _file_has_component "$f" "$comp"; then
          found=1
          if ! _component_has_reboot_timeout "$f" "$comp"; then
            echo "check-offline-survival: FAIL — ${f}: '${comp}:' block wires no active reboot_timeout — it would inherit ESPHome's non-zero stock default (15min)"
            rc=1
          fi
        fi
      done
    done < <(find "$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  done
  if [ "$found" -eq 0 ]; then
    echo "check-offline-survival: no reboot_timeout keys or connectivity components under ${root}/{modules,hardware} — vacuously ok"
  fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────────────────────

# Run scan_root over a scratch tree and assert it PASSES ($1=pass) or FAILS ($1=fail).
_expect() {
  local want="$1" root="$2" label="$3"
  if scan_root "$root" >/dev/null 2>&1; then
    [ "$want" = pass ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected FAIL, got pass)"; return 1; }
  else
    [ "$want" = fail ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected pass, got FAIL)"; return 1; }
  fi
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/modules" "$tmp/hardware"

  # GOOD: literal 0s + a ${sub} whose default is 0s, in separate files, each component with its key.
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
substitutions:
  wifi_reboot_timeout: 0s
wifi:
  ssid: x
  reboot_timeout: ${wifi_reboot_timeout}
YAML
  cat >"$tmp/hardware/board.yaml" <<'YAML'
mqtt:
  reboot_timeout: 0s
YAML
  _expect pass "$tmp" "good tree (0s literal + 0s substitution default)" || rc=1

  # BAD 1: a literal non-zero default.
  printf 'wifi:\n  reboot_timeout: 15min\n' >"$tmp/modules/wifi.yaml"; : >"$tmp/hardware/board.yaml"
  _expect fail "$tmp" "literal reboot_timeout: 15min rejected" || rc=1

  # BAD 2: a ${sub} whose in-file default is non-zero (proves substitution resolution).
  printf 'substitutions:\n  wifi_reboot_timeout: 15min\nwifi:\n  reboot_timeout: ${wifi_reboot_timeout}\n' >"$tmp/modules/wifi.yaml"
  _expect fail "$tmp" "substitution default 15min rejected" || rc=1

  # BAD 3: a ${sub} with no discoverable in-file default (un-provable).
  printf 'wifi:\n  reboot_timeout: ${wifi_reboot_timeout}\n' >"$tmp/modules/wifi.yaml"
  _expect fail "$tmp" "unresolvable default rejected" || rc=1

  # BAD 4: a FRACTIONAL non-zero duration (0.5s) — a leading-digits-only test would wrongly accept it.
  printf 'wifi:\n  reboot_timeout: 0.5s\n' >"$tmp/modules/wifi.yaml"
  _expect fail "$tmp" "fractional 0.5s rejected" || rc=1

  # BAD 5: a connectivity component with NO reboot_timeout key.
  printf 'wifi:\n  ssid: x\n  password: y\n' >"$tmp/modules/wifi.yaml"
  _expect fail "$tmp" "connectivity component missing reboot_timeout rejected" || rc=1

  # BAD 6: a connectivity component whose reboot_timeout is COMMENTED OUT.
  printf 'substitutions:\n  wifi_reboot_timeout: 0s\nwifi:\n  ssid: x\n  # reboot_timeout: ${wifi_reboot_timeout}\n' >"$tmp/modules/wifi.yaml"
  _expect fail "$tmp" "commented-out reboot_timeout rejected" || rc=1

  # BAD 7: ONE file with BOTH wifi and mqtt where only wifi has the key — mqtt must still be caught
  # (per-component, not file-wide).
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
wifi:
  reboot_timeout: 0s
mqtt:
  broker: x
YAML
  _expect fail "$tmp" "combined wifi+mqtt with mqtt key missing rejected" || rc=1

  # BAD 8: QUOTED keys with a non-zero timeout must not slip through as a vacuous pass.
  printf '"wifi":\n  "reboot_timeout": 15min\n' >"$tmp/modules/wifi.yaml"
  _expect fail "$tmp" "quoted wifi/reboot_timeout keys with 15min rejected" || rc=1

  # GOOD 2: quoted keys resolving to 0s must PASS.
  printf '"wifi":\n  "reboot_timeout": 0s\n' >"$tmp/modules/wifi.yaml"
  _expect pass "$tmp" "quoted keys resolving to 0s accepted" || rc=1

  # BAD 9: a reboot_timeout buried in a BLOCK SCALAR (not a direct child of wifi) must NOT satisfy
  # the presence check — wifi has no real reboot_timeout and would inherit the 15min default.
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
wifi:
  ssid: |
    reboot_timeout: 0s
  password: x
YAML
  _expect fail "$tmp" "block-scalar reboot_timeout does not satisfy presence" || rc=1

  # GOOD 3: a real direct-child reboot_timeout at the component indent, alongside a block scalar
  # elsewhere, must PASS (the block scalar must not disturb the direct-child detection).
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
wifi:
  ssid: |
    multiline banner
  reboot_timeout: 0s
  password: x
YAML
  _expect pass "$tmp" "direct-child reboot_timeout alongside a block scalar accepted" || rc=1

  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then echo "self-test: all cases passed"; fi
  return "$rc"
}

main() {
  case "${1:-}" in
    --self-test) self_test ;;
    "" ) scan_root "$(dirname "$SCRIPT_DIR")" ;;
    *  ) scan_root "$1" ;;
  esac
}

main "$@"
