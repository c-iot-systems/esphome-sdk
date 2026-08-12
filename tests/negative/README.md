# Negative fixtures — configs that MUST fail `esphome config`

Each file here omits **exactly one** required substitution and therefore must make `esphome config`
exit non-zero. They are the proof that the substitution contract is enforced: if any of these were
to *succeed*, a required input silently gained a default — exactly the "public default password in
every device" failure the contract forbids. `scripts/check-negative.sh` runs `esphome config` over
every file here and fails if any one succeeds; it is wired into `validate.yml`.

Unlike the positive fixtures in `tests/validate/`, these import the modules with a **local
`!include`** (`../../modules/*.yaml`) rather than the GitHub `packages:` path. That keeps them
hermetic — they exercise the contract with no network fetch and no `__SDK_REF__` materialization, so
they run identically locally and in CI. The modules under test carry no `external_components`, so no
`${sdk_ref}` threading is needed here (`check-sdk-ref.sh` does not scan this directory).

Coverage owned by SDK-2 (core.yaml + wifi.yaml): omitting `device_name`, `firmware_version`,
`wifi_ssid`, `wifi_password` or `wifi_ap_password`. MQTT and OTA omissions belong to SDK-3, which
owns those modules.
