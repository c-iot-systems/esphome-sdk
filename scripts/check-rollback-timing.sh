#!/usr/bin/env bash
#
# check-rollback-timing.sh — enforce that the broker, not a boot timer, owns OTA validity.
#
# THE INVARIANT (see modules/ota.yaml + README OTA section): on esp-idf the post-OTA rollback
# watchdog (`script_rollback`) only rolls back an image still in ESP_OTA_IMG_PENDING_VERIFY. ESPHome's
# safe_mode independently confirms the running image — esp_ota_mark_app_valid_cancel_rollback() — once
# it judges the boot good, after `boot_is_good_after` (stock default 1min). If safe_mode confirms
# FIRST, the running partition leaves PENDING_VERIFY and the watchdog's gate can never fire: a bad OTA
# that boots but never reaches the broker would silently survive. So safe_mode's `boot_is_good_after`
# MUST be strictly greater than the watchdog's delay, handing the validity decision to MQTT for the
# whole watchdog window.
#
# This gate fails the build if, in modules/ota.yaml, safe_mode's `boot_is_good_after` is missing or
# resolves to a duration <= the `script_rollback` watchdog delay — so the dead-watchdog regression
# can never silently return. A repo with no modules/ota.yaml (ota module not yet introduced on an
# earlier link of the SDK chain) is a vacuous PASS.
#
# Usage:
#   check-rollback-timing.sh [ROOT]     # check ROOT/modules/ota.yaml (default: repo root)
#   check-rollback-timing.sh --self-test
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────

# Strip surrounding quotes and whitespace from a scalar.
_unquote() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"        # ltrim
  v="${v%"${v##*[![:space:]]}"}"        # rtrim
  if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# Resolve a RHS to its effective value: a `${name}` reference is looked up as name's substitution
# default in the SAME file (quote-aware); a literal is returned as-is. Empty if unresolvable.
_resolve_value() {
  local raw="$1" file="$2" v name def
  v="${raw%%#*}"                        # drop trailing inline comment
  v="$(_unquote "$v")"
  if [[ "$v" =~ ^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}$ ]]; then
    name="${BASH_REMATCH[1]}"
    def="$(grep -oE "^[[:space:]]*[\"']?${name}[\"']?[[:space:]]*:[[:space:]]*[^#]+" "$file" 2>/dev/null | head -n1 \
             | sed -E "s/^[[:space:]]*[\"']?${name}[\"']?[[:space:]]*:[[:space:]]*//")"
    _unquote "$def"
  else
    printf '%s' "$v"
  fi
}

# Convert an ESPHome duration to milliseconds on stdout; empty string if it does not parse. Accepts a
# decimal magnitude and a unit of ms | s | min | h | d (bare number is rejected — ESPHome requires a
# unit for these options, and silently guessing one could mask a real mistake).
_duration_to_ms() {
  local v; v="$(_unquote "$1")"
  [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)(ms|s|min|h|d)$ ]] || { printf ''; return; }
  local mag="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}" factor
  case "$unit" in
    ms)  factor=1 ;;
    s)   factor=1000 ;;
    min) factor=60000 ;;
    h)   factor=3600000 ;;
    d)   factor=86400000 ;;
  esac
  awk -v m="$mag" -v f="$factor" 'BEGIN{ printf "%.0f", m*f }'
}

# Print safe_mode's boot_is_good_after RHS (resolved) from an ota.yaml. Empty if the key is absent.
_boot_is_good_after() {
  local file="$1" line rhs
  line="$(grep -nE "^[[:space:]]*[\"']?boot_is_good_after[\"']?[[:space:]]*:" "$file" 2>/dev/null | head -n1)"
  [[ -z "$line" ]] && { printf ''; return; }
  rhs="${line#*:}"; rhs="${rhs#*:}"     # drop "lineno:" then "key:" -> value
  _resolve_value "$rhs" "$file"
}

# Print the script_rollback watchdog's first `delay:` RHS (resolved) from an ota.yaml. The scan starts
# at the `- id: script_rollback` list item and stops at the next `- id:` item, so unrelated `delay:`
# keys elsewhere in the file (on_end, on_value) are never picked up. Empty if not found.
_watchdog_delay() {
  local file="$1" raw
  raw="$(awk '
    /^[[:space:]]*-[[:space:]]*id[[:space:]]*:[[:space:]]*["'\'']?script_rollback["'\'']?[[:space:]]*$/ { inblk=1; next }
    inblk && /^[[:space:]]*-[[:space:]]*id[[:space:]]*:/ { exit }   # next script ends the block
    inblk && /^[[:space:]]*-?[[:space:]]*delay[[:space:]]*:/ {
      sub(/^[^:]*:/, "", $0); print; exit
    }
  ' "$file")"
  _resolve_value "${raw:-}" "$file"
}

# ── check ───────────────────────────────────────────────────────────────────────────────────────

check_root() {
  local root="$1"
  local file="$root/modules/ota.yaml"
  if [[ ! -f "$file" ]]; then
    echo "check-rollback-timing: no modules/ota.yaml under ${root} — vacuously ok"
    return 0
  fi

  local good_raw delay_raw good_ms delay_ms
  good_raw="$(_boot_is_good_after "$file")"
  delay_raw="$(_watchdog_delay "$file")"

  if [[ -z "$delay_raw" ]]; then
    echo "check-rollback-timing: FAIL — ${file}: could not find the script_rollback watchdog delay"
    return 1
  fi
  if [[ -z "$good_raw" ]]; then
    echo "check-rollback-timing: FAIL — ${file}: safe_mode sets no boot_is_good_after, so ESPHome's 1min default confirms the image ~4min before the ${delay_raw} watchdog — the rollback gate can never fire"
    return 1
  fi

  good_ms="$(_duration_to_ms "$good_raw")"
  delay_ms="$(_duration_to_ms "$delay_raw")"
  if [[ -z "$good_ms" ]]; then
    echo "check-rollback-timing: FAIL — ${file}: boot_is_good_after '${good_raw}' is not a parseable duration"
    return 1
  fi
  if [[ -z "$delay_ms" ]]; then
    echo "check-rollback-timing: FAIL — ${file}: watchdog delay '${delay_raw}' is not a parseable duration"
    return 1
  fi

  if (( good_ms > delay_ms )); then
    echo "check-rollback-timing: ok — ${file}: boot_is_good_after ${good_raw} > watchdog ${delay_raw} (MQTT owns validity for the whole watchdog window)"
    return 0
  fi
  echo "check-rollback-timing: FAIL — ${file}: boot_is_good_after ${good_raw} <= watchdog ${delay_raw} — safe_mode would confirm the image before the watchdog fires, making the rollback gate dead code"
  return 1
}

# ── self-test ─────────────────────────────────────────────────────────────────────────────────

_expect() {
  local want="$1" root="$2" label="$3"
  if check_root "$root" >/dev/null 2>&1; then
    [ "$want" = pass ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected FAIL, got pass)"; return 1; }
  else
    [ "$want" = fail ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected pass, got FAIL)"; return 1; }
  fi
}

# Emit an ota.yaml with the given boot_is_good_after line (may be empty to omit) and watchdog delay.
_fixture() {
  local dir="$1" good_line="$2" delay="$3"
  mkdir -p "$dir/modules"
  {
    echo "safe_mode:"
    echo "  num_attempts: \"50\""
    [[ -n "$good_line" ]] && echo "  ${good_line}"
    echo "script:"
    echo "  - id: perform_ota_update"
    echo "    then:"
    echo "      - delay: 1s"
    echo "  - id: script_rollback"
    echo "    then:"
    echo "      - delay: ${delay}"
    echo "      - lambda: |-"
    echo "          rollback();"
  } > "$dir/modules/ota.yaml"
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"

  # GOOD: 330s confirmation > 300s watchdog.
  _fixture "$tmp/a" "boot_is_good_after: 330s" "300s"
  _expect pass "$tmp/a" "330s > 300s watchdog accepted" || rc=1

  # GOOD: substitution default resolves and exceeds the watchdog.
  mkdir -p "$tmp/b/modules"
  cat >"$tmp/b/modules/ota.yaml" <<'YAML'
substitutions:
  ota_confirm: 6min
safe_mode:
  boot_is_good_after: ${ota_confirm}
script:
  - id: script_rollback
    then:
      - delay: 300s
      - lambda: |-
          rollback();
YAML
  _expect pass "$tmp/b" "substitution default 6min > 300s accepted" || rc=1

  # BAD: stock default (no boot_is_good_after key at all).
  _fixture "$tmp/c" "" "300s"
  _expect fail "$tmp/c" "missing boot_is_good_after rejected" || rc=1

  # BAD: confirmation equal to the watchdog (tie is not strictly greater).
  _fixture "$tmp/d" "boot_is_good_after: 300s" "300s"
  _expect fail "$tmp/d" "boot_is_good_after == watchdog rejected" || rc=1

  # BAD: confirmation shorter than the watchdog (the original regression).
  _fixture "$tmp/e" "boot_is_good_after: 1min" "300s"
  _expect fail "$tmp/e" "1min < 300s watchdog rejected" || rc=1

  # BAD: cross-unit comparison — 5min == 300s must be caught, not fooled by the smaller number.
  _fixture "$tmp/f" "boot_is_good_after: 5min" "300s"
  _expect fail "$tmp/f" "5min (==300s) rejected across units" || rc=1

  # GOOD: cross-unit — 301s > 5min? no. Use 6min > 300s already covered; here 310s > 300s.
  _fixture "$tmp/g" "boot_is_good_after: 310s" "300s"
  _expect pass "$tmp/g" "310s > 300s accepted" || rc=1

  # BAD: unparseable confirmation duration.
  _fixture "$tmp/h" "boot_is_good_after: soon" "300s"
  _expect fail "$tmp/h" "non-duration boot_is_good_after rejected" || rc=1

  # BAD: an unrelated `delay:` (on_end 1s) must NOT be mistaken for the watchdog delay. Here the real
  # watchdog is 300s and confirmation is 330s (GOOD); the fixture carries a decoy 1s delay in another
  # script FIRST to prove scoping picks the script_rollback delay, not the decoy.
  mkdir -p "$tmp/i/modules"
  cat >"$tmp/i/modules/ota.yaml" <<'YAML'
safe_mode:
  boot_is_good_after: 330s
script:
  - id: perform_ota_update
    then:
      - delay: 1s
  - id: script_rollback
    then:
      - delay: 300s
      - lambda: |-
          rollback();
YAML
  _expect pass "$tmp/i" "decoy delay in another script ignored (scoped to script_rollback)" || rc=1

  # VACUOUS: no ota.yaml at all.
  mkdir -p "$tmp/j/modules"
  _expect pass "$tmp/j" "no modules/ota.yaml is vacuously ok" || rc=1

  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then echo "self-test: all cases passed"; fi
  return "$rc"
}

main() {
  case "${1:-}" in
    --self-test) self_test ;;
    "" ) check_root "$(dirname "$SCRIPT_DIR")" ;;
    *  ) check_root "$1" ;;
  esac
}

main "$@"
