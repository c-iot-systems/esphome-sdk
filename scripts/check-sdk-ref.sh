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

# Strip surrounding quotes and inline trailing comments from a captured YAML scalar.
_clean_value() {
  local v="$1"
  v="${v%%#*}"                       # drop trailing comment
  v="${v#"${v%%[![:space:]]*}"}"     # ltrim
  v="${v%"${v##*[![:space:]]}"}"     # rtrim
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
    return 0    # not a package-consuming config; nothing to bind
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

# Check B: every ref: in a module/hardware file must be exactly ${sdk_ref}.
check_module_file() {
  local file="$1" rc=0 line val
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*ref:[[:space:]]*(.+)$ ]]; then
      val="$(_clean_value "${BASH_REMATCH[1]}")"
      if [[ "$val" != '${sdk_ref}' ]]; then
        echo "$file: hard-coded external_components ref '$val' — must be \${sdk_ref}"; rc=1
      fi
    fi
  done <"$file"
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

  # BAD 2: a module hard-codes a component ref.
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
    echo "self-test: PASS on bad fixture (hard-coded module ref rejected) — ok"
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
