#!/usr/bin/env bash
#
# check-button-platform.sh — every button the platform can see must be able to answer.
#
# A stock ESPHome button is write-only on the wire: `mqtt_button.cpp` sets
# `SendDiscoveryConfig::state_topic = false` and the component never publishes, because Home
# Assistant models a button as a trigger with no state. The criotive platform instead confirms a
# command by reading telemetry back from the component's state topic, with `WaitForAckResponse`
# defaulting to true — so a press on a stock button can only ever time out. `ack_button` exists to
# close that gap, and this gate is what stops the next module from reopening it.
#
# The rule is about visibility, not about the `button:` key. A blanket ban is not implementable:
# `controls.yaml` needs `platform: shutdown` / `restart` / `safe_mode` / `factory_reset` to perform
# the reboot and the wipe, which `ack_button` cannot do. Those four are `internal: true`, which is
# precisely the statement "the platform never sees this": no discovery, no command topic, nothing
# to acknowledge. They are the target of a visible `ack_button`, and that visible button is the one
# the platform talks to.
#
# So: in modules/ and hardware/, every item of a top-level `button:` list that is not
# `internal: true` must be `platform: ack_button`.
#
# Scope is modules/ and hardware/ — what the SDK itself publishes — matching
# check-automation-syntax.sh. Fixtures under tests/ are consumer-shaped examples and may
# legitimately declare a stock button to contrast against one.
#
# Known limit, stated rather than assumed: a module that pulled in another package with its own
# inline `packages:` block could contribute a button this gate never sees, because ESPHome merges
# that fragment and the gate reads files as written. No module does — modules ARE the packages
# consumers import, and none of them imports another — and forbidding `packages:` outright would
# block a composition the SDK may legitimately want. The release gate's real `esphome compile`
# over tests/validate/ is what covers the merged result.
#
# The reader is an awk parser, not a YAML implementation, so it FAILS CLOSED: a button list written
# in a form it cannot decompose (an inline flow sequence, an entry opening with a bare `-`) is
# reported as unverifiable rather than skipped. Skipping would mean printing "ok" for a file the
# gate never actually read — the form is legal YAML, so ESPHome builds it and only the gate is
# blind. Block form and indentless-sequence form are both read normally; every accepted and refused
# spelling has a --self-test fixture.
#
# Usage:
#   check-button-platform.sh [ROOT]   # scan ROOT/modules and ROOT/hardware (default: repo root)
#   check-button-platform.sh --self-test
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' AWK_PROG <<'AWK' || true
function flush_item(   why) {
  # Close the button-list item that was open, and judge it.
  if (!item_open) return
  item_open = 0
  if (item_internal) return                      # invisible to the platform -> exempt
  if (item_platform == "ack_button") return
  why = (item_platform == "") ? "has no platform" : ("uses platform: " item_platform)
  printf "%s:%d: button %s; a button that is not `internal: true` must use `platform: ack_button`, or it cannot acknowledge a press and every awaited command against it times out\n", \
    item_file, item_line, why
  fail = 1
}

# Refuse a construct rather than skip it. A gate that quietly ignores a form it does not
# understand reports "ok" on a file it never actually checked, which is worse than a false alarm:
# the form is legal YAML, so ESPHome builds it and only the gate is blind.
function unverifiable(line, what) {
  printf "%s:%d: %s — this gate cannot read that form; write the button list in block form (`- platform: ...`) so every entry is checkable\n", \
    FILENAME, line, what
  fail = 1
}

function unquote(s) { sub(/^['"]/, "", s); sub(/['"]$/, "", s); return s }

function scalar_after_colon(s,   v) {           # value text after `key:`, comments stripped
  v = s
  sub(/^[ \t]+/, "", v); sub(/[ \t]*#.*$/, "", v); sub(/[ \t]+$/, "", v)
  return v
}

# A new file: judge whatever item the previous one ended on (flush_item reports against the
# item's own file and line, captured when it opened — FILENAME/FNR have already moved here).
FNR == 1 { flush_item(); in_button = 0; list_indent = -1; root_indent = -1 }

{
  raw = $0
  sub(/\r$/, "", raw)                            # tolerate CRLF
  match(raw, /^[ ]*/); indent = RLENGTH          # YAML indent is spaces-only
  trimmed = substr(raw, indent + 1)
  if (trimmed ~ /^$/ || trimmed ~ /^#/) next     # blank and comment lines carry no structure

  if (trimmed ~ /^(---|\.\.\.)/) next            # document markers carry no keys

  is_seq = (trimmed ~ /^-([ \t]|$)/)             # a sequence entry, at any indent

  # The root mapping does not have to start at column 0 — YAML lets the whole document be
  # indented. Take the first structural line as the root level rather than assuming zero, so an
  # indented document is read normally instead of sliding past every check.
  if (root_indent == -1) {
    root_indent = indent
    if (trimmed ~ /^\{/) {                        # the entire root as one flow mapping
      unverifiable(FNR, "the document root is a flow mapping")
      next
    }
  }

  # ---- a top-level mapping key -------------------------------------------------------------
  # Only when it is NOT a sequence entry: YAML lets a sequence sit at the same indent as the key
  # that owns it, so `- platform: ...` at column 0 is still inside `button:`, not a new key.
  # A merge key splices a whole mapping — a button list, or the root itself — in from an anchor,
  # and the spliced content is not on this line. Checked before the root-key branch so a merge at
  # the root is refused too, rather than dismissed as "a key that is not button". Nothing in
  # modules/ or hardware/ uses one.
  if (trimmed ~ /^<<[ \t]*:/) {
    unverifiable(FNR, "a YAML merge key (`<<:`) can splice in keys this reader cannot follow")
    next
  }

  if (indent == root_indent && !is_seq) {
    flush_item()
    in_button = 0
    list_indent = -1

    # A top-level key this reader cannot resolve to a plain name might BE `button`, so it is
    # refused rather than assumed innocent: a YAML tag (`!!str button:`), the explicit-key form
    # (`? button`), and a double-quoted key carrying escapes (`"\x62utton":`) all normalize to
    # keys this gate would otherwise never recognise. None appear in this repo; the point is that
    # the gate's "ok" stays true for every input, not just the ones it happens to understand.
    if (trimmed ~ /^[!?&*]/) {
      unverifiable(FNR, "a top-level key carries a YAML tag, anchor, alias or the explicit-key form")
      next
    }
    if (trimmed ~ /^"[^"]*\\/) {
      unverifiable(FNR, "a top-level key is a quoted scalar containing an escape")
      next
    }

    key = trimmed
    q = ""
    if (key ~ /^['"]/) { q = substr(key, 1, 1); key = substr(key, 2) }   # `"button":` is the same key
    if (!match(key, /^button/)) next
    after = substr(key, RLENGTH + 1)
    if (q != "") {
      if (substr(after, 1, 1) != q) next         # opening quote never closed -> not this key
      after = substr(after, 2)
    }
    if (after !~ /^[ \t]*:/) next                # `buttons:` or a scalar, not `button:`
    sub(/^[ \t]*:/, "", after)

    rest = scalar_after_colon(after)
    if (rest == "" || rest == "[]") { in_button = 1; next }              # block form, or empty
    unverifiable(FNR, "`button:` holds an inline flow sequence")
    next
  }

  if (!in_button) next

  # ---- a sequence entry ---------------------------------------------------------------------
  if (is_seq) {
    if (list_indent == -1) list_indent = indent  # the first entry fixes the list's own level
    if (indent < list_indent) { flush_item(); in_button = 0; next }      # dedented out of the list
    if (indent == list_indent) {
      flush_item()
      if (trimmed ~ /^-[ \t]*$/) {               # `-` alone, mapping starts on the next line
        unverifiable(FNR, "a button entry opens with a bare `-`")
        next
      }
      match(trimmed, /^-[ \t]+/)
      item_open = 1; item_file = FILENAME; item_line = FNR
      item_platform = ""; item_internal = 0
      item_col = indent + RLENGTH                # where this entry's mapping keys start
      trimmed = substr(trimmed, RLENGTH + 1)     # `- platform: x` carries a key on the same line
      indent = item_col
    }
    # a deeper `- ` belongs to on_press:, filters, ... and is none of our business
  }

  if (!item_open || indent != item_col) next     # deeper lines belong to the entry's sub-blocks

  if (match(trimmed, /^platform[ \t]*:[ \t]*/)) {
    item_platform = unquote(scalar_after_colon(substr(trimmed, RLENGTH + 1)))
  } else if (match(trimmed, /^internal[ \t]*:[ \t]*/)) {
    # The exact true-set of esphome cv.boolean: true / yes / on / enable. Reading fewer would fail
    # a genuinely internal button — a false alarm, which is the one way a gate loses its authority.
    item_internal = (tolower(unquote(scalar_after_colon(substr(trimmed, RLENGTH + 1)))) \
                     ~ /^(true|yes|on|enable)$/)
  }
}

END { flush_item(); exit fail }
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
    echo "check-button-platform: no modules/ or hardware/ yet — vacuously ok"
    return 0
  fi
  if awk "$AWK_PROG" "${files[@]}"; then
    echo "check-button-platform: ok — every non-internal button uses platform: ack_button"
    return 0
  fi
  return 1
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/modules" "$tmp/hardware"

  # GOOD: the shape modules/controls.yaml actually uses — visible ack_buttons in front of
  # internal action platforms — plus the spellings the parser has to survive.
  cat >"$tmp/modules/good.yaml" <<'YAML'
button:
  - platform: ack_button
    name: "Restart"
    on_press:
      - then:
          - delay: 500ms
          - button.press: button_restart
  - platform: restart
    name: "Restart"
    id: button_restart
    internal: true
  - platform: "ack_button"          # quoted platform
    name: "Quoted"
  - platform: factory_reset
    internal: True                  # capitalised boolean
  - name: "Keys before platform"
    icon: mdi:gesture-tap-button
    platform: ack_button            # platform need not come first
binary_sensor:
  - platform: gpio                  # a non-button platform is none of our business
    pin: GPIO0
    on_click:
      - then:
          - button.press: button_restart
YAML
  cat >"$tmp/hardware/good_nested.yaml" <<'YAML'
button:
  - platform: ack_button
    name: "Nested lists must not be read as button entries"
    on_press:
      - then:
          - delay: 500ms
          - platform: template      # deeper `platform:` belongs to the automation, not the button
YAML
  # Legal spellings that must be READ, not skipped. An indentless sequence is the dangerous one:
  # the entries sit at column 0, the same as the key, so a parser that treats every column-0 line
  # as a new top-level key walks straight out of the list and passes a violation in silence.
  cat >"$tmp/modules/good_indentless.yaml" <<'YAML'
button:
- platform: ack_button
  name: "Indentless sequence"
- platform: restart
  id: r
  internal: true
sensor:
- platform: template
  name: "A different top-level key ends the button list"
YAML
  cat >"$tmp/modules/good_quoted_key.yaml" <<'YAML'
"button":
  - platform: ack_button
    name: "Quoted key"
YAML
  cat >"$tmp/modules/good_empty_flow.yaml" <<'YAML'
button: []
YAML
  # cv.boolean spellings: an internal button written any of these ways is still internal.
  cat >"$tmp/modules/good_bool_spellings.yaml" <<'YAML'
button:
  - platform: restart
    id: a
    internal: yes
  - platform: shutdown
    id: b
    internal: "on"
  - platform: factory_reset
    id: c
    internal: TRUE
  - platform: safe_mode
    id: d
    internal: enable
YAML
  # A document whose root mapping is indented is still a document.
  cat >"$tmp/modules/good_indented_root.yaml" <<'YAML'
  button:
    - platform: ack_button
      name: "Indented root"
YAML
  if scan_root "$tmp" >/dev/null 2>&1; then
    echo "self-test: PASS — good fixtures accepted"
  else
    echo "self-test: FAILED — good fixtures were rejected"; rc=1
  fi

  # BAD: one violation per run, each proven to fail on its own.
  local case_name
  for case_name in template no_platform internal_false indentless flow_seq bare_dash \
                   tagged_key explicit_key escaped_key \
                   indented_root flow_root anchored_key merge_key; do
    rm -f "$tmp/modules/bad.yaml"
    case "$case_name" in
      template)       cat >"$tmp/modules/bad.yaml" <<'YAML'
button:
  - platform: template
    name: "Silent"
YAML
        ;;
      no_platform)    cat >"$tmp/modules/bad.yaml" <<'YAML'
button:
  - name: "No platform at all"
YAML
        ;;
      internal_false) cat >"$tmp/modules/bad.yaml" <<'YAML'
button:
  - platform: template
    name: "Explicitly visible"
    internal: false
YAML
        ;;
      # A violation written as an indentless sequence must still be caught.
      indentless)     cat >"$tmp/modules/bad.yaml" <<'YAML'
button:
- platform: template
  name: "Silent, at column zero"
YAML
        ;;
      # Forms the parser cannot read must FAIL, never pass quietly. Both are legal YAML that
      # ESPHome builds, so skipping them would mean reporting ok on an unchecked file.
      flow_seq)       cat >"$tmp/modules/bad.yaml" <<'YAML'
button: [{platform: template, name: "Inline"}]
YAML
        ;;
      bare_dash)      cat >"$tmp/modules/bad.yaml" <<'YAML'
button:
  -
    platform: template
    name: "Dash on its own line"
YAML
        ;;
      # Key spellings that normalize to `button` but that a text reader cannot resolve. Refused,
      # not skipped — otherwise a visible stock button hides under one of them.
      tagged_key)     cat >"$tmp/modules/bad.yaml" <<'YAML'
!!str button:
  - platform: template
    name: "Hidden behind a tag"
YAML
        ;;
      explicit_key)   cat >"$tmp/modules/bad.yaml" <<'YAML'
? button
:
  - platform: template
    name: "Hidden behind the explicit-key form"
YAML
        ;;
      escaped_key)    cat >"$tmp/modules/bad.yaml" <<'YAML'
"\x62utton":
  - platform: template
    name: "Hidden behind an escape"
YAML
        ;;
      # An indented root must be READ (and so caught), not slid past.
      indented_root)  cat >"$tmp/modules/bad.yaml" <<'YAML'
  button:
    - platform: template
      name: "Hidden behind an indented root mapping"
YAML
        ;;
      # A whole-document flow mapping cannot be decomposed here, so it is refused.
      flow_root)      cat >"$tmp/modules/bad.yaml" <<'YAML'
{button: [{platform: template, name: "Flow root"}]}
YAML
        ;;
      # An anchor in front of the key hides it exactly as a tag does.
      anchored_key)   cat >"$tmp/modules/bad.yaml" <<'YAML'
&button_key button:
  - platform: template
    name: "Hidden behind an anchor"
YAML
        ;;
      # A merge key splices in content that is not on the line, so it is refused. The fixture is
      # otherwise spotless — no button list at all — so the merge key is the only possible reason
      # it fails, which is what makes this case prove that check rather than another one.
      merge_key)      cat >"$tmp/modules/bad.yaml" <<'YAML'
<<: *a_root_fragment_that_may_carry_buttons
sensor:
  - platform: template
    name: "Not a button, and not the point"
YAML
        ;;
    esac
    if scan_root "$tmp" >/dev/null 2>&1; then
      echo "self-test: FAILED — a violating fixture ($case_name) was accepted"; rc=1
    else
      echo "self-test: PASS — violating fixture ($case_name) rejected"
    fi
  done
  rm -f "$tmp/modules/bad.yaml"

  # The report must name the item's OWN file and line, and both are captured when the item opens.
  # Two independent ways to get this wrong, so the fixture is built to catch both at once:
  #   * NR instead of FNR — NR keeps counting across files, so every line after the first file is
  #     wrong. Caught by putting a padding file FIRST, which makes NR != FNR.
  #   * FILENAME instead of the captured name — the last item of a file is judged on the first line
  #     of the NEXT one, by which point FILENAME has moved on. Caught by making the violation the
  #     last item of a file that is not the last file scanned.
  # Files are scanned in sorted order, so the names below fix the order.
  rm -f "$tmp/modules/good.yaml" "$tmp/hardware/good_nested.yaml" \
        "$tmp/modules/good_indentless.yaml" "$tmp/modules/good_quoted_key.yaml" \
        "$tmp/modules/good_empty_flow.yaml" "$tmp/modules/good_bool_spellings.yaml" \
        "$tmp/modules/good_indented_root.yaml"
  cat >"$tmp/modules/aaa_pad.yaml" <<'YAML'
# padding so that NR and FNR diverge in the file that follows
button:
  - platform: ack_button
    name: "Fine"
    on_press:
      - then:
          - delay: 500ms
YAML
  cat >"$tmp/modules/mmm_violator.yaml" <<'YAML'
# line 1
# line 2
button:
  - platform: ack_button
    name: "Fine"
  - platform: template
    name: "Bad, and the last item of a file that is not scanned last"
YAML
  cat >"$tmp/modules/zzz_last.yaml" <<'YAML'
button:
  - platform: ack_button
    name: "Fine"
YAML
  local report
  report="$(scan_root "$tmp" 2>&1 || true)"
  if printf '%s' "$report" | grep -q "mmm_violator\.yaml:6:"; then
    echo "self-test: PASS — violation reported against its own file and line"
  else
    echo "self-test: FAILED — expected mmm_violator.yaml:6, got: ${report}"; rc=1
  fi
  rm -f "$tmp/modules/aaa_pad.yaml" "$tmp/modules/mmm_violator.yaml" "$tmp/modules/zzz_last.yaml"

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
