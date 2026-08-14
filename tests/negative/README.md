# Negative fixtures — configs that MUST fail `esphome config`

Each file here breaks **exactly one** rule the SDK enforces at config time, and therefore must make
`esphome config` exit non-zero. `scripts/check-negative.sh` runs `esphome config` over every file
here and fails if any one succeeds; it is wired into `validate.yml`.

Two kinds of rule live here:

- **The substitution contract** — `omit_*.yaml` omits a required substitution, `orphan_wifi_*.yaml`
  half-fills a WiFi station slot. These are the proof the contract is enforced: if one were to
  *succeed*, a required input silently gained a default — exactly the "public default password in
  every device" failure the contract forbids. `check-contract-diff.sh --negative-parity` holds this
  set in step with the required substitutions derived from `modules/`, so it looks at `omit_*.yaml`
  and nothing else.
- **Component invariants** — a rule a component enforces in its own `CONFIG_SCHEMA`, which has no
  substitution to omit. `ack_button_shared_topic.yaml` and `ack_button_wildcard_topic.yaml` are the
  first: an `ack_button` whose acknowledgement would land back on its own subscription must not
  validate. These are named after the component and the invariant, never `omit_*`, so the parity
  gate keeps ignoring them. They source the component through a **local** `external_components`
  path rather than `modules/ack_button.yaml`, because that module fetches over git — a fixture that
  failed on an unreachable ref would pass this suite while proving nothing.

Unlike the positive fixtures in `tests/validate/`, these import the modules with a **local
`!include`** (`../../modules/*.yaml`) rather than the GitHub `packages:` path. That keeps them
hermetic — they exercise the contract with no network fetch and no `__SDK_REF__` materialization, so
they run identically locally and in CI (`check-sdk-ref.sh` does not scan this directory).

Every fixture except `omit_sdk_ref.yaml` threads `vars: {sdk_ref: local-test}` into the includes,
because `sdk_ref` is itself a required substitution (guarded in `core.yaml`): without it, *every*
fixture would fail on the missing `sdk_ref` instead of on the one input it is meant to test.
`omit_sdk_ref.yaml` is the fixture that deliberately withholds it from `core.yaml`.

Coverage owned by SDK-2 (core.yaml + wifi.yaml): omitting `device_name`, `firmware_version`,
`sdk_ref` or `wifi_ap_password`.

The `orphan_wifi_password*.yaml` pair covers the WiFi station slots instead. The slots themselves are
optional — a device may legitimately fill one, three or none of them — so there is no "omitted
`wifi_ssid`" failure to test; what the contract enforces is that a slot is **all-or-nothing**. Each
fixture sets a slot's password with no SSID (slot 1 in one, slot 2 in the other) and must fail. That
is the guard against a forgotten or mistyped SSID name quietly turning a configured network into no
network at all.

Coverage owned by SDK-3 (criotive_mqtt.yaml + ota.yaml): omitting `mqtt_broker`,
`mqtt_ca_certificate`, `mqtt_username`, `mqtt_password`, `ota_password` or `ota_http_server`. The
MQTT/OTA fixtures import all four modules (core, wifi, criotive_mqtt, ota) so that the *only* missing
input is the one under test — the failure is attributable to that substitution, not to an unresolved
cross-module id (criotive_mqtt's `on_connect` references ota's `script_rollback`).
