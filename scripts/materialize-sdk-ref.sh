#!/usr/bin/env bash
#
# materialize-sdk-ref.sh — resolve the __SDK_REF__ placeholder in validate fixtures to a concrete
# revision, then prove the substitution was total.
#
# WHY A PLACEHOLDER AT REST: a fixture pins the SDK it pulls (`packages:` ref + `vars.sdk_ref`).
# If that were a published tag in the repo, PR and release CI would compile the LAST RELEASE
# instead of the revision under test, and a broken change would sail through green. So fixtures
# carry `__SDK_REF__` at rest and every CI job materializes the revision it is actually testing:
# validate.yml the PR head SHA, release-gate.yml the main SHA, release.yml the released tag.
#
# The substitution is only trustworthy if it is TOTAL, so this script asserts both halves:
#   (a) no `__SDK_REF__` survives in any fixture, and
#   (b) every resolved `ref:` / `sdk_ref:` value equals REF exactly — catching a fixture that
#       hard-codes a different revision instead of using the placeholder.
#
# An empty fixture directory is a vacuous PASS (the scaffold has nothing to compile); the
# self-test proves every FAIL path, so this is no silent no-op.
#
# Usage:
#   materialize-sdk-ref.sh REF [ROOT]     # rewrite ROOT/tests/validate in place (default: repo root)
#   materialize-sdk-ref.sh --self-test
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLACEHOLDER='__SDK_REF__'

# Rewrite every fixture under ROOT/tests/validate from PLACEHOLDER to REF, then verify totality.
materialize() {
  local ref="$1" root="$2" rc=0 f val
  local -a files=()
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find "$root/tests/validate" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null | sort -z)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "materialize-sdk-ref: no validate fixtures under ${root}/tests/validate — vacuously ok"
    return 0
  fi

  echo "materialize-sdk-ref: materializing ref '${ref}' into ${#files[@]} fixture(s)"
  for f in "${files[@]}"; do
    sed -i "s/${PLACEHOLDER}/${ref}/g" "$f"
  done

  # (a) the placeholder must be gone everywhere.
  for f in "${files[@]}"; do
    if grep -q "$PLACEHOLDER" "$f"; then
      echo "materialize-sdk-ref: FAIL — ${f}: still contains ${PLACEHOLDER} after materialization"
      rc=1
    fi
  done

  # (b) every resolved ref must equal REF — a fixture may not pin a different revision by hand.
  for f in "${files[@]}"; do
    while IFS= read -r val; do
      if [ "$val" != "$ref" ]; then
        echo "materialize-sdk-ref: FAIL — ${f}: resolved ref '${val}' != expected '${ref}'"
        rc=1
      fi
    done < <(grep -oE '(^[[:space:]]*ref:|sdk_ref:)[[:space:]]*[^},[:space:]]+' "$f" \
               | sed -E 's/.*:[[:space:]]*//')
  done

  [ "$rc" -eq 0 ] && echo "materialize-sdk-ref: ok — every fixture resolves to '${ref}'"
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────────────────────

_expect() {
  local want="$1" root="$2" label="$3"
  if materialize "vTEST" "$root" >/dev/null 2>&1; then
    [ "$want" = pass ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected FAIL, got pass)"; return 1; }
  else
    [ "$want" = fail ] && echo "self-test: PASS — ${label}" || { echo "self-test: FAILED — ${label} (expected pass, got FAIL)"; return 1; }
  fi
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"

  # GOOD: placeholder in both the package ref and vars.sdk_ref.
  mkdir -p "$tmp/good/tests/validate"
  cat >"$tmp/good/tests/validate/core.yaml" <<'YAML'
packages:
  core:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    vars: {sdk_ref: __SDK_REF__}
YAML
  _expect pass "$tmp/good" "placeholder in ref and vars.sdk_ref resolves to REF" || rc=1
  if ! grep -q 'ref: vTEST' "$tmp/good/tests/validate/core.yaml"; then
    echo "self-test: FAILED — rewrite did not reach the file"; rc=1
  else
    echo "self-test: PASS — rewrite reached the file on disk"
  fi

  # BAD: a hand-pinned ref that ignores the placeholder — CI would test the wrong revision.
  mkdir -p "$tmp/pinned/tests/validate"
  cat >"$tmp/pinned/tests/validate/core.yaml" <<'YAML'
packages:
  core:
    ref: v0.1.0
    vars: {sdk_ref: __SDK_REF__}
YAML
  _expect fail "$tmp/pinned" "hand-pinned ref that differs from REF is rejected" || rc=1

  # BAD: vars.sdk_ref disagrees with the package ref after materialization.
  mkdir -p "$tmp/split/tests/validate"
  cat >"$tmp/split/tests/validate/core.yaml" <<'YAML'
packages:
  core:
    ref: __SDK_REF__
    vars: {sdk_ref: someotherref}
YAML
  _expect fail "$tmp/split" "vars.sdk_ref disagreeing with the package ref is rejected" || rc=1

  # VACUOUS: no fixtures at all.
  mkdir -p "$tmp/empty/tests/validate"
  _expect pass "$tmp/empty" "no fixtures is a vacuous pass" || rc=1

  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "self-test: all checks passed" || echo "self-test: FAILURES above"
  return "$rc"
}

# ── entrypoint ────────────────────────────────────────────────────────────────────────────────

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    return "$?"
  fi
  if [ "$#" -lt 1 ]; then
    echo "usage: materialize-sdk-ref.sh REF [ROOT] | --self-test" >&2
    return 2
  fi
  materialize "$1" "${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"
}

main "$@"
