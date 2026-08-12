#!/usr/bin/env bash
#
# check-offline-survival.sh — enforce the offline-survival invariant on reboot_timeout defaults.
#
# THE INVARIANT (product requirement, see README + modules/core.yaml): a device MUST continue
# operating indefinitely while offline, WITHOUT rebooting. Field units (freezer monitors, escape-room
# props) sit on flaky uplinks and must ride out an outage rather than power-cycle through it. In
# ESPHome, `reboot_timeout: 0s` DISABLES the connectivity reboot outright (both wifi and mqtt guard
# App.reboot() with `reboot_timeout_ != 0`), so legacy pinned both timeouts to 0s. ESPHome's stock
# default is 15min. This gate fails the build if any `reboot_timeout` under modules/ or hardware/
# resolves to a NON-ZERO default, so the regression can never silently return.
#
# What it checks: every `reboot_timeout:` KEY in modules/ and hardware/ YAML (not the
# `*_reboot_timeout` substitution names, not comments). Its value is either a literal duration or a
# `${substitution}` reference; a reference is resolved to that substitution's in-file default. The
# resolved default must be a ZERO duration (0, 0s, 0ms, 0min, 0h). A non-zero default — or a
# `${...}` reference with no discoverable in-file default (an un-provable default) — fails the gate.
#
# Usage:
#   check-offline-survival.sh [ROOT]     # scan ROOT/modules and ROOT/hardware (default: repo root)
#   check-offline-survival.sh --self-test
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# True iff $1 is a zero-valued duration: a leading numeric run that is all zeros ("0", "0s", "00ms").
# A value with no leading digit (e.g. an unresolved "${x}") is NOT zero.
_is_zero_duration() {
  local v="$1"
  v="${v//\"/}"; v="${v//\'/}"          # strip quotes
  v="${v#"${v%%[![:space:]]*}"}"        # ltrim
  v="${v%"${v##*[![:space:]]}"}"        # rtrim
  local num="${v%%[!0-9]*}"             # leading digit run
  [[ -n "$num" ]] || return 1
  [[ "$num" =~ ^0+$ ]]
}

# Resolve a reboot_timeout RHS to its effective default. A `${name}` reference is looked up as
# `name`'s substitution default in the SAME file; a literal is returned as-is. Prints the resolved
# value (empty if a `${name}` reference has no in-file default).
_resolve_value() {
  local raw="$1" file="$2" v name def
  v="${raw%%#*}"                        # drop trailing inline comment
  v="${v#"${v%%[![:space:]]*}"}"        # ltrim
  v="${v%"${v##*[![:space:]]}"}"        # rtrim
  if [[ "$v" =~ ^\$\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}$ ]]; then
    name="${BASH_REMATCH[1]}"
    # First mapping line `<name>: <value>` in the file — the substitution default. Comments (`#...`)
    # never match this anchored pattern.
    def="$(grep -oE "^[[:space:]]*${name}[[:space:]]*:[[:space:]]*[^#]+" "$file" 2>/dev/null | head -n1 \
             | sed -E "s/^[[:space:]]*${name}[[:space:]]*:[[:space:]]*//")"
    def="${def%"${def##*[![:space:]]}"}"   # rtrim
    printf '%s' "$def"
  else
    printf '%s' "$v"
  fi
}

# Scan one file. Prints one line per reboot_timeout key; returns non-zero if any resolves non-zero.
scan_file() {
  local file="$1" rc=0 lineno content value resolved trimmed
  # `(^|[^A-Za-z0-9_])reboot_timeout[[:space:]]*:` — the boundary keeps `wifi_reboot_timeout:` /
  # `mqtt_reboot_timeout:` (the substitution names, preceded by `_`) from matching.
  while IFS= read -r line; do
    lineno="${line%%:*}"
    content="${line#*:}"
    trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue                 # skip comment lines
    value="${content#*reboot_timeout}"                  # drop up to the key name
    value="${value#*:}"                                 # drop the colon
    resolved="$(_resolve_value "$value" "$file")"
    if [[ -z "$resolved" ]]; then
      echo "check-offline-survival: FAIL — ${file}:${lineno}: reboot_timeout '$(echo "$value" | xargs)' has no resolvable in-repo default (must default to 0s)"
      rc=1
    elif _is_zero_duration "$resolved"; then
      echo "check-offline-survival: ok — ${file}:${lineno}: reboot_timeout default resolves to '${resolved}' (reboot disabled)"
    else
      echo "check-offline-survival: FAIL — ${file}:${lineno}: reboot_timeout default resolves to '${resolved}' (non-zero — a device would reboot ${resolved} into an outage)"
      rc=1
    fi
  done < <(grep -nE '(^|[^A-Za-z0-9_])reboot_timeout[[:space:]]*:' "$file" 2>/dev/null)
  return "$rc"
}

# Scan ROOT/modules and ROOT/hardware. Zero reboot_timeout keys is a vacuous PASS (nothing to
# disable), but the self-test proves the FAIL path works so this is not a silent no-op.
scan_root() {
  local root="$1" rc=0 found=0 f
  local -a dirs=("$root/modules" "$root/hardware")
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do
      if grep -qE '(^|[^A-Za-z0-9_])reboot_timeout[[:space:]]*:' "$f" 2>/dev/null; then
        found=1
        scan_file "$f" || rc=1
      fi
    done < <(find "$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  done
  if [ "$found" -eq 0 ]; then
    echo "check-offline-survival: no reboot_timeout keys under ${root}/{modules,hardware} — vacuously ok"
  fi
  return "$rc"
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/modules" "$tmp/hardware"

  # GOOD: a literal 0s, and a ${sub} whose in-file default is 0s. scan_root must PASS.
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
substitutions:
  wifi_reboot_timeout: 0s
wifi:
  reboot_timeout: ${wifi_reboot_timeout}
YAML
  cat >"$tmp/hardware/board.yaml" <<'YAML'
mqtt:
  reboot_timeout: 0s
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: PASS on good tree (0s literal + 0s substitution default) — ok"
  else
    echo "self-test: FAILED — a good 0s tree was rejected"; rc=1
  fi

  # BAD 1: a literal non-zero default (reboot_timeout: 15min). scan_root MUST fail.
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
wifi:
  reboot_timeout: 15min
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — a literal reboot_timeout: 15min was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad tree (literal 15min rejected) — ok"
  fi

  # BAD 2: a ${sub} reference whose in-file default is non-zero. Proves substitution resolution.
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
substitutions:
  wifi_reboot_timeout: 15min
wifi:
  reboot_timeout: ${wifi_reboot_timeout}
YAML
  cat >"$tmp/hardware/board.yaml" <<'YAML'
# nothing here
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — a ${sub} defaulting to 15min was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad tree (substitution default 15min rejected) — ok"
  fi

  # BAD 3: a ${sub} reference with no discoverable in-file default (un-provable). MUST fail.
  cat >"$tmp/modules/wifi.yaml" <<'YAML'
wifi:
  reboot_timeout: ${wifi_reboot_timeout}
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — a reboot_timeout with no in-repo default was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad tree (unresolvable default rejected) — ok"
  fi

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
