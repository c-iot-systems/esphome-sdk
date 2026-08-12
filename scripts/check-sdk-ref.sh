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

# The CI placeholder every validate fixture must carry; CI materializes it into the revision
# under test. A concrete ref in a fixture would pin PR/release CI to a published release.
PLACEHOLDER='__SDK_REF__'
# The SDK's own repo slug, used to scope package-shorthand ( github://owner/repo...@ref ) matching
# to the SDK — a fixture may legitimately pull an unrelated third-party package at a pinned tag.
SDK_REPO='c-iot-systems/esphome-sdk'

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

# Emit every explicit `ref:` scalar (block or flow, quoted or with whitespace before the colon),
# one per line. The `(^|[^A-Za-z0-9_])` boundary keeps `sdk_ref:` from matching the `ref:` key.
_extract_refs() {
  grep -oE "(^|[^A-Za-z0-9_])['\"]?ref['\"]?[[:space:]]*:[[:space:]]*[^,}[:space:]]+" "$1" \
    | sed -E 's/.*:[[:space:]]*//'
}

# Emit every `sdk_ref:` scalar (block `sdk_ref: X` or flow `{sdk_ref: X}`), one per line.
_extract_sdk_refs() {
  grep -oE "(^|[^A-Za-z0-9_])['\"]?sdk_ref['\"]?[[:space:]]*:[[:space:]]*[^,}[:space:]]+" "$1" \
    | sed -E 's/.*:[[:space:]]*//'
}

# Emit the ref pinned by every SDK-repo package/component shorthand ( github|gitlab://<SDK>...@ref ),
# one per line. Scoped to the SDK repo so an unrelated third-party pinned package is left alone.
_extract_sdk_shorthand_refs() {
  grep -oE "(github|gitlab)://${SDK_REPO}[^[:space:]'\"},]*@[^[:space:]'\"},]+" "$1" \
    | sed -E 's/.*@//'
}

# Check A: every SDK reference in a validate fixture must be the CI placeholder. This subsumes the
# old package-ref==sdk_ref consistency check and additionally rejects (a) a fixture with no SDK
# reference at all — vacuously "consistent" but exercising nothing — and (b) a fixture pinned to a
# concrete release via an explicit ref, a threaded sdk_ref, or a github/gitlab package shorthand.
check_validate_file() {
  local file="$1" rc=0 val
  local -a refs=() sdk_refs=() shorts=()

  while IFS= read -r val; do [[ -n "$val" ]] && refs+=("$(_clean_value "$val")"); done < <(_extract_refs "$file")
  while IFS= read -r val; do [[ -n "$val" ]] && sdk_refs+=("$(_clean_value "$val")"); done < <(_extract_sdk_refs "$file")
  while IFS= read -r val; do [[ -n "$val" ]] && shorts+=("$(_clean_value "$val")"); done < <(_extract_sdk_shorthand_refs "$file")

  local n_pkg=$(( ${#refs[@]} + ${#shorts[@]} ))
  if [[ "$n_pkg" -eq 0 && "${#sdk_refs[@]}" -eq 0 ]]; then
    echo "$file: no SDK reference — a validate fixture must consume the SDK at the ${PLACEHOLDER} placeholder"
    return 1
  fi
  if [[ "$n_pkg" -eq 0 ]]; then
    echo "$file: has vars.sdk_ref but no package ref: to bind it to"; return 1
  fi
  if [[ "${#sdk_refs[@]}" -eq 0 ]]; then
    # A package ref with no vars.sdk_ref means the ref is never threaded to any module's
    # external_components — the component would silently follow the default branch.
    echo "$file: declares a package ref but no vars.sdk_ref to thread it to modules"; return 1
  fi
  for val in "${refs[@]}" "${shorts[@]}" "${sdk_refs[@]}"; do
    if [[ "$val" != "$PLACEHOLDER" ]]; then
      echo "$file: SDK ref '$val' must be the ${PLACEHOLDER} placeholder (CI materializes the revision under test)"; rc=1
    fi
  done
  return "$rc"
}

# Check B: every external_components ref in a module/hardware file must be exactly ${sdk_ref}.
# `${sdk_ref}` is first substituted to a brace-free sentinel so flow-map close braces do not
# confuse parsing; then two ref spellings are inspected against it:
#   (a) an explicit `ref:` key — block ( "  ref: v0.1.0" ), flow ( "{..., ref: v0.1.0}" ),
#       quoted ( "'ref': v0.1.0" ), or with whitespace before the colon ( "ref : v0.1.0" ); and
#   (b) a github/gitlab source shorthand that pins a ref via @<ref> ( "github://owner/repo@tag" ).
check_module_file() {
  local file="$1" rc=0 val sub
  local ok='__SDKREF_OK__'   # brace-free stand-in so flow-map close braces do not confuse parsing
  sub="$(sed 's/\${sdk_ref}/'"$ok"'/g' "$file")"

  # (a) explicit ref: keys, all spellings.
  while IFS= read -r val; do
    [[ -z "$val" ]] && continue
    val="$(_clean_value "$val")"
    if [[ "$val" != "$ok" ]]; then
      echo "$file: hard-coded external_components ref '$val' — must be \${sdk_ref}"; rc=1
    fi
  done < <(printf '%s\n' "$sub" \
             | grep -oE "(^|[^A-Za-z0-9_])['\"]?ref['\"]?[[:space:]]*:[[:space:]]*[^,}[:space:]]+" \
             | sed -E 's/.*:[[:space:]]*//')

  # (b) github/gitlab shorthand sources that pin a ref via @<ref> (any repo — a module must fetch
  #     every component at ${sdk_ref}, never a hard-coded tag/branch/sha).
  while IFS= read -r val; do
    [[ -z "$val" ]] && continue
    val="$(_clean_value "$val")"
    if [[ "$val" != "$ok" ]]; then
      echo "$file: hard-coded external_components ref '$val' in a github/gitlab shorthand — must be \${sdk_ref}"; rc=1
    fi
  done < <(printf '%s\n' "$sub" \
             | grep -oE "(github|gitlab)://[^[:space:]'\"},]*@[^[:space:]'\"},]+" \
             | sed -E 's/.*@//')
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

  # ---- Round-2 hardening: valid YAML spellings, shorthand sources, vacuous fixtures ----
  # Restore both sides to a known-good baseline first.
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: __SDK_REF__}
YAML

  # BAD 5: a module hard-codes a component ref via GitHub shorthand ( source: github://...@tag ).
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source: github://c-iot-systems/esphome-sdk@v0.1.0
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — hard-coded github-shorthand ref was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (github-shorthand ref rejected) — ok"
  fi

  # GOOD: the same shorthand threaded through ${sdk_ref} must pass.
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source: github://c-iot-systems/esphome-sdk@${sdk_ref}
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo 'self-test: PASS on good fixture (github-shorthand @${sdk_ref} accepted) — ok'
  else
    echo 'self-test: FAILED — github-shorthand @${sdk_ref} was rejected'; rc=1
  fi

  # BAD 6: a module ref key with whitespace before the colon ( ref : v0.1.0 ).
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source:
      type: git
      url: https://github.com/c-iot-systems/esphome-sdk
      ref : v0.1.0
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — spaced ref key was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (spaced ref key rejected) — ok"
  fi

  # BAD 7: a module ref key that is quoted ( 'ref': v0.1.0 ).
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source:
      type: git
      url: https://github.com/c-iot-systems/esphome-sdk
      'ref': v0.1.0
    components: [google_location]
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — quoted ref key was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (quoted ref key rejected) — ok"
  fi
  # restore a good module for the validate-side cases
  cat >"$tmp/modules/location.yaml" <<'YAML'
external_components:
  - source: {type: git, url: https://github.com/c-iot-systems/esphome-sdk, ref: ${sdk_ref}}
    components: [google_location]
YAML

  # BAD 8: a validate fixture with no SDK reference at all (previously a vacuous pass).
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
esphome:
  name: no-sdk-here
esp32:
  board: esp32dev
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — validate fixture with no SDK ref was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (no-SDK-ref validate config rejected) — ok"
  fi

  # BAD 9: a validate fixture that pins a release via package shorthand ( @v0.1.0 ).
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive: github://c-iot-systems/esphome-sdk/modules/core.yaml@v0.1.0
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — release-pinned shorthand validate fixture was NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (release-pinned shorthand validate config rejected) — ok"
  fi

  # BAD 10: a validate fixture whose refs are internally consistent but concrete (pin a release).
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: v0.1.0
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: v0.1.0}
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: FAILED — concrete (non-placeholder) validate refs were NOT rejected"; rc=1
  else
    echo "self-test: PASS on bad fixture (concrete non-placeholder validate refs rejected) — ok"
  fi

  # GOOD: a fixture carrying the placeholder in both the package ref and a threaded sdk_ref passes.
  cat >"$tmp/tests/validate/good.yaml" <<'YAML'
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: __SDK_REF__}
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: PASS on good fixture (placeholder package ref + threaded sdk_ref) — ok"
  else
    echo "self-test: FAILED — good placeholder fixture was rejected"; rc=1
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
