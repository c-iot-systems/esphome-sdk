# Negative fixtures — configs that MUST fail `esphome config`

Each file here omits **exactly one** required substitution and therefore must make `esphome config`
exit non-zero. They are the proof that the substitution contract is enforced: if any of these were
to *succeed*, a required input silently gained a default — exactly the "public default password in
every device" failure the contract forbids. `scripts/check-negative.sh` runs `esphome config` over
every file here and fails if any one succeeds; it is wired into `validate.yml`.

Unlike the positive fixtures in `tests/validate/`, these import the modules with a **local
`!include`** (`../../modules/*.yaml`) rather than the GitHub `packages:` path. That keeps them
hermetic — they exercise the contract with no network fetch and no `__SDK_REF__` materialization, so
they run identically locally and in CI (`check-sdk-ref.sh` does not scan this directory).

Every fixture except `omit_sdk_ref.yaml` threads `vars: {sdk_ref: local-test}` into the includes,
because `sdk_ref` is itself a required substitution (guarded in `core.yaml`): without it, *every*
fixture would fail on the missing `sdk_ref` instead of on the one input it is meant to test.
`omit_sdk_ref.yaml` is the fixture that deliberately withholds it from `core.yaml`.

Coverage owned by SDK-2 (core.yaml + wifi.yaml): omitting `device_name`, `firmware_version`,
`sdk_ref`, `wifi_ssid`, `wifi_password` or `wifi_ap_password`.

Coverage owned by SDK-3 (criotive_mqtt.yaml + ota.yaml): omitting `mqtt_broker`,
`mqtt_ca_certificate`, `mqtt_username`, `mqtt_password`, `ota_password` or `ota_http_server`. The
MQTT/OTA fixtures import all four modules (core, wifi, criotive_mqtt, ota) so that the *only* missing
input is the one under test — the failure is attributable to that substitution, not to an unresolved
cross-module id (criotive_mqtt's `on_connect` references ota's `script_rollback`).
