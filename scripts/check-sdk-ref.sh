#!/usr/bin/env bash
#
# check-sdk-ref.sh — enforce the ${sdk_ref} threading invariant.
#
# ESPHome treats `packages:` and `external_components:` as INDEPENDENT git sources: a module
# fetched at `@<ref>` does NOT pass that ref to an `external_components:` block inside it. The SDK
# closes this by threading the ref through ESPHome's per-file `vars:` — the consumer passes
# `vars: {sdk_ref: <ref>}` once and every module writes `ref: ${sdk_ref}`. Left implicit, the
# component source would follow the default branch while the YAML is pinned. This check guards
# both halves of that contract:
#
#   A. Validate-config consistency — in every tests/validate/*.yaml, each `vars.sdk_ref` value
#      must equal the package `ref:` value. (Both are the CI placeholder before materialization
#      and both are the same revision after; the check holds either way.)
#   B. Module ref hygiene — no file under modules/ or hardware/ may hard-code an
#      external_components ref. The only `ref:` such a file may contain is `${sdk_ref}`.
#
# Usage:
#   check-sdk-ref.sh [ROOT]      # check ROOT/tests/validate and ROOT/{modules,hardware}
#   check-sdk-ref.sh --self-test
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Strip surrounding quotes, inline comments and flow-mapping punctuation from a captured YAML
# scalar. A trailing flow close-brace is dropped only when it is NOT part of a ${...} expansion,
# so `${sdk_ref}` survives intact while `v0.1.0}` (from `{..., ref: v0.1.0}`) becomes `v0.1.0`.
_clean_value() {
  local v="$1"
  v="${v%%#*}"                       # drop trailing comment
  v="${v#"${v%%[![:space:]]*}"}"     # ltrim
  v="${v%"${v##*[![:space:]]}"}"     # rtrim
  v="${v%,}"                         # drop a flow-mapping trailing comma
  if [[ "$v" != *'{'* ]]; then v="${v%\}}"; fi   # drop a flow close-brace, but keep ${...}
  v="${v#\"}"; v="${v%\"}"           # strip double quotes
  v="${v#\'}"; v="${v%\'}"           # strip single quotes
  printf '%s' "$v"
}

# Check A: package ref == every sdk_ref, for one validate config file.
check_validate_file() {
  local file="$1" rc=0 line key val
  local pkg_ref="" have_ref=0
  local -a sdk_refs=()

  while IFS= read -r line; do
    # package ref: a top-of-block `ref:` scalar that is not the ${sdk_ref} placeholder
    if [[ "$line" =~ ^[[:space:]]*ref:[[:space:]]*(.+)$ ]]; then
      val="$(_clean_value "${BASH_REMATCH[1]}")"
      if [[ "$val" != '${sdk_ref}' && -n "$val" ]]; then
        if [[ "$have_ref" -eq 1 && "$val" != "$pkg_ref" ]]; then
          echo "$file: multiple differing package refs ('$pkg_ref' vs '$val')"; rc=1
        fi
        pkg_ref="$val"; have_ref=1
      fi
    fi
    # sdk_ref: matches both `vars: {sdk_ref: X}` and a block `sdk_ref: X`
    if [[ "$line" =~ sdk_ref:[[:space:]]*([^},[:space:]]+) ]]; then
      sdk_refs+=("$(_clean_value "${BASH_REMATCH[1]}")")
    fi
  done <"$file"

  if [[ "${#sdk_refs[@]}" -eq 0 ]]; then
    if [[ "$have_ref" -eq 1 ]]; then
      # A package ref with no vars.sdk_ref means the ref is never threaded to any module's
      # external_components — the component would silently follow the default branch.
      echo "$file: declares a package ref but no vars.sdk_ref to thread it to modules"; return 1
    fi
    return 0    # not an SDK-consuming config; nothing to bind
  fi
  if [[ "$have_ref" -eq 0 ]]; then
    echo "$file: has vars.sdk_ref but no package ref: to bind it to"; return 1
  fi
  for val in "${sdk_refs[@]}"; do
    if [[ "$val" != "$pkg_ref" ]]; then
      echo "$file: vars.sdk_ref '$val' != package ref '$pkg_ref'"; rc=1
    fi
  done
  return "$rc"
}

# Check B: every ref: in a module/hardware file must be exactly ${sdk_ref}. Handles both block
# style ( "  ref: ${sdk_ref}" ) and flow style ( "source: {type: git, ..., ref: v0.1.0}" ). The
# `(^|[^A-Za-z0-9_])` boundary keeps `sdk_ref:` (a substitution name) from matching the `ref:` key.
check_module_file() {
  local file="$1" rc=0 raw val
  local ok='__SDKREF_OK__'   # brace-free stand-in so flow-map close braces do not confuse parsing
  while IFS= read -r raw; do
    val="$(_clean_value "$raw")"
    if [[ "$val" != "$ok" ]]; then
      echo "$file: hard-coded external_components ref '$val' — must be \${sdk_ref}"; rc=1
    fi
  done < <(sed 's/\${sdk_ref}/'"$ok"'/g' "$file" \
             | grep -oE '(^|[^A-Za-z0-9_])ref:[[:space:]]*[^,[:space:]]+' \
             | sed -E 's/.*ref:[[:space:]]*//')
  return "$rc"
}

scan_root() {
  local root="$1" rc=0 f
  if [[ -d "$root/tests/validate" ]]; then
    while IFS= read -r -d '' f; do
      check_validate_file "$f" || rc=1
    done < <(find "$root/tests/validate" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  fi
  local d
  for d in modules hardware; do
    [[ -d "$root/$d" ]] || continue
    while IFS= read -r -d '' f; do
      check_module_file "$f" || rc=1
    done < <(find "$root/$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)
  done
  return "$rc"
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/tests/validate" "$tmp/modules" "$tmp/hardware"

  # GOOD: package ref matches every sdk_ref; module uses ${sdk_ref}.
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: __SDK_REF__}
      - path: modules/location.yaml
        vars:
          sdk_ref: __SDK_REF__
YAML
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source:
      type: git
      url: https://github.com/c-iot-systems/esphome-sdk
      ref: ${sdk_ref}
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: PASS on good fixtures — ok"
  else
    echo "self-test: FAILED — good fixtures were rejected"; rc=1
  fi

  # BAD 1: a sdk_ref that differs from the package ref.
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: v0.1.0}
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — mismatched sdk_ref was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (sdk_ref != package ref rejected) — ok"
  fi
  # restore the good validate config for the next case
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: __SDK_REF__}
YAML

  # BAD 2: a module hard-codes a component ref (block style).
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source:
      type: git
      url: https://github.com/c-iot-systems/esphome-sdk
      ref: v0.1.0
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — hard-coded module ref was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (hard-coded block ref rejected) — ok"
  fi

  # BAD 3: a module hard-codes a component ref in FLOW style on one line.
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source: {type: git, url: https://github.com/c-iot-systems/esphome-sdk, ref: v0.1.0}
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — hard-coded inline flow ref was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (hard-coded inline flow ref rejected) — ok"
  fi
  # restore a good module for the next case
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source: {type: git, url: https://github.com/c-iot-systems/esphome-sdk, ref: ${sdk_ref}}
    components: [google_location]
YAML

  # BAD 4: a validate fixture declares a package ref but no vars.sdk_ref to thread it.
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — package ref without vars.sdk_ref was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (package ref without vars.sdk_ref rejected) — ok"
  fi

  rm -rf "$tmp"
  return "$rc"
}

main() {
  case "${1:-}" in
    --self-test) self_test ;;
    "" ) scan_root "$(dirname "$SCRIPT_DIR")" ;;
    * )  scan_root "$1" ;;
  esac
}

main "$@"
