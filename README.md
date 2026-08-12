# criotive ESPHome SDK

Shared ESPHome configuration for criotive firmware, consumed through ESPHome's native
[`packages:`](https://esphome.io/components/packages.html) mechanism. The AI firmware-generation
path and the builder sidecar assemble a device's `main.yaml` by importing modules from this
repository at a pinned tag.

```yaml
packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: v0.1.0
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: v0.1.0}
```

No custom import machinery: ESPHome resolves, caches and merges the remote packages itself.

## This repository is public — nothing secret may ever be committed

`c-iot-systems/esphome-sdk` is **public from creation**. No credential is involved anywhere in the
fetch path, and no authentication is ever added — a private repo would force every clone to
authenticate, and a token in a generated `main.yaml` would be a token shown to the customer.

**Every credential reaches a device as a substitution, never as a value in a config in this
repository.** A value pushed to a public repo is permanent and is *not* revoked by deletion. No
substitution that carries a credential has a default: a missing required credential fails
validation loudly rather than shipping a public default password to every device that forgot to
override it.

## Supported scope: ESP32 only

The public SDK covers **xtensa-esp32 and xtensa-esp32s3** only. riscv32 (`mr60bha2dev`) and ESP8266
(`r`, `esp12`, `nodemcu32`) are out of scope and are never compile-tested here —
`ota.yaml`'s `http_request` OTA, `preferences` and parts of `wifi.yaml` genuinely differ on ESP8266.
Anyone using the SDK on an ESP8266 is off the supported path. ESP8266 can be added later if
customers ask.

Supported hardware:

| Hardware module | Board | Variant | Framework |
|---|---|---|---|
| `hds_v1_0` | `pico32` | `esp32` | arduino |
| `hds_v1_1` | `esp32dev` | `esp32` | arduino |
| `hds_v2_0` | `esp32-s3-devkitc-1` | `esp32s3` | arduino |

## Substitution contract

`core.yaml` is the one documented place answering *"what must every firmware supply?"*. Every
parameter arrives as a YAML `substitutions:` value — **nothing is a C++ preprocessor define**, because
the builder sidecar injects no build flags. Substitution names are `lower_snake_case`.

**"Required" is scoped to the module that uses it.** Only `device_name`, `firmware_version` and
`sdk_ref` are required by `core.yaml` and therefore by every device. `wifi_*` is required by
`wifi.yaml`, `mqtt_*` by `criotive_mqtt.yaml`, `ota_*` by `ota.yaml`. A module must not make another
module's inputs globally mandatory — that would defeat opt-in composition. A device compiles only
the modules it imports.

| Substitution | Required | Default | Notes |
|---|---|---|---|
| `device_name` | **yes** | — | ESPHome node name; also the MQTT topic prefix |
| `firmware_version` | **yes** | — | published as a text sensor |
| `sdk_ref` | **yes** | — | must equal the package `ref`; CI-enforced |
| `wifi_ssid` | **yes** | — | *(`wifi.yaml`)* |
| `wifi_password` | **yes** | — | *(`wifi.yaml`)* — **no default, ever** |
| `wifi_ap_password` | **yes** | — | fallback AP; **no default, ever** |
| `wifi_reboot_timeout` | no | `15min` | *(`wifi.yaml`)* |
| `mqtt_broker` | **yes** | — | *(`criotive_mqtt.yaml`)* |
| `mqtt_ca_certificate` | **yes** | — | **the TLS trust anchor — see below** |
| `mqtt_port` | no | `8883` | conventional TLS port; the port alone does **not** enable TLS |
| `mqtt_username` | **yes** | — | **no default, ever** |
| `mqtt_password` | **yes** | — | **no default, ever** |
| `mqtt_reboot_timeout` | no | `15min` | |
| `mqtt_discovery` | no | `true` | Home Assistant discovery |
| `ota_password` | **yes** | — | *(`ota.yaml`)* — **no default, ever** |
| `ota_attempts` | no | `5` | safe-mode attempts |
| `ota_http_server` | **yes** | — | HTTPS OTA download host |
| `ota_http_server_test` | no | `${ota_http_server}` | *(`ota.yaml`)* test/staging OTA host — see below |
| `logger_level` | no | `INFO` | |

**No credential has a default.** A default password in a public repo is a default password in every
device that forgets to override it. A missing required substitution must fail validation loudly, and
the PR-time `esphome config` check plus the negative-fixture harness prove it does.

### Required substitutions fail loudly — the guard idiom

Merely *referencing* `${x}` does **not** make a substitution required. ESPHome 2026.5.1 runs the
substitution pass non-strict (`components/substitutions/__init__.py`): an undefined `${x}` only logs
a **warning** and leaves the literal text in place, so `esphome config` still exits 0 unless the
leftover literal happens to break a field's schema. `device_name` is the lucky case — it lands in
`esphome: name:`, whose identifier schema rejects the `${device_name}` literal. Every other required
substitution lands in a free-form string field that accepts the literal, so each is wrapped in a
guard:

```yaml
password: "${ wifi_password if wifi_password is defined else 1/0 }"
```

When the value is present the expression returns it unchanged; when it is missing the
`ZeroDivisionError` is re-raised as a hard `cv.Invalid` (the non-strict pass demotes `UndefinedError`
to a warning but re-raises every *other* expression error), so `esphome config` exits non-zero with
the offending expression — which names the variable — in the message. **Any module that adds a
required substitution to a free-form field must apply this guard** (`criotive_mqtt.yaml` and
`ota.yaml` do so for their credentials). `tests/negative/` proves each required input fails when
omitted, and `scripts/check-negative.sh` (wired into `validate.yml`) asserts every negative fixture
exits non-zero.

### MQTT is TLS only when a CA is configured

**Port `8883` does not enable TLS.** ESPHome calls `set_ca_certificate` only when
`certificate_authority` is present in the config; without it the transport is plain TCP whatever the
port, and a config that sets `8883` and no CA sends credentials in the clear. `criotive_mqtt.yaml`
therefore takes a **required `mqtt_ca_certificate` substitution with no default**, wired to
`certificate_authority`. The platform injects the broker's CA when generating the config, so staging
and production can differ and the CA can rotate without an SDK release.

## `${sdk_ref}` — pinning the components with the YAML

ESPHome treats `packages:` and `external_components:` as **independent** git sources: a module
fetched at `@<ref>` does *not* pass that ref to an `external_components:` block inside it. Left
implicit, a module's C++ component would follow the default branch while its YAML is pinned. The SDK
threads the ref through ESPHome's per-file `vars:` — the consumer passes `vars: {sdk_ref: <ref>}`
once and every module writes `ref: ${sdk_ref}`:

```yaml
external_components:
  - source:
      type: git
      url: https://github.com/c-iot-systems/esphome-sdk
      ref: ${sdk_ref}
    components: [google_location]
```

CI (`scripts/check-sdk-ref.sh`) asserts every validate config's `vars.sdk_ref` equals its package
`ref`, and that no module hard-codes a ref.

## Automations use explicit list syntax

Package merging happens on **raw YAML, before** ESPHome normalizes a single-automation mapping into
a list. So every automation-shaped `on_*` key (`on_boot`, `on_shutdown`, `on_connect`, `on_value`,
…) must use the **sequence** form, or two modules' automations merge as dicts and silently collapse:

```yaml
# CORRECT — stacks into two automations, priorities preserved
esphome:
  on_boot:
    - priority: 600
      then: [...]
```

CI (`scripts/check-automation-syntax.sh`) enforces this across `modules/` and `hardware/`.

## Versioning

- Every generated config **pins an exact tag** (`@v0.1.0`), never a branch. A device never changes
  because the SDK moved; upgrading is an explicit platform action, and therefore also a migration
  point.
- **Semantic versioning.** A module rename or a substitution rename is a **major** bump plus a
  migration of stored configs.
- The first tag is **`v0.1.0`** — the module boundaries have not survived a real product yet.
- **No secrets, ever.** Every credential arrives as a substitution; a value committed to a public
  repo is permanent and cannot be revoked by deletion.

## Repository layout

```
esphome-sdk/
  README.md                     # this file — substitution contract, scope, versioning
  modules/                      # shared + optional-hardware modules
  hardware/                     # hds_v1_0, hds_v1_1, hds_v2_0
  components/                   # ESPHome custom components (C++)
  tests/validate/               # minimal configs exercised by CI (see tests/validate/README.md)
  tests/negative/               # configs that MUST fail (missing required substitutions)
  scripts/                      # CI check scripts (automation-syntax, sdk-ref, negative)
  .github/workflows/            # validate (PR) and release (tag) CI
```

## Continuous integration

- **`validate.yml`** runs on every pull request: it materializes the PR head SHA into each validate
  config's package `ref` and `vars.sdk_ref`, runs `esphome config` over `tests/validate/`, and runs
  the `check-automation-syntax.sh`, `check-sdk-ref.sh` and `check-negative.sh` gates. This validates
  the *revision under test*, never a published tag.
- **`release.yml`** runs on a version tag: it materializes `GITHUB_REF_NAME`, asserts every fixture
  resolves to that tag, and runs a real `esphome compile` over `tests/validate/` — so no version is
  ever published without every shipped component having been built at least once.

ESPHome is pinned to **2026.5.1** in CI, matching what the builder sidecar installs.

## Modules

Each module group below owns a section here; later work appends to its own group without
restructuring the others.

### Shared modules

- `core.yaml` — substitution contract, `esphome:`, device identity, firmware_version, boot counter,
  `preferences`, `logger`, `time`/sntp. Mandatory for every device; imports nothing.
- `wifi.yaml` — `wifi:`, `captive_portal`, AP-name lambda, wifi_info text sensors, wifi signal
  sensor.
- `criotive_mqtt.yaml` — mqtt client, topic prefix, birth / last-will / shutdown messages,
  `on_connect`.
- `ota.yaml` — `safe_mode`, both OTA platforms, `http_request`, ota_status, `perform_ota_update`,
  rollback script. `perform_ota_update` only flashes a binary whose name starts with
  `${device_name}_` (a build for another device is rejected into an error state). It picks the
  download host by detecting a `.test` token in the requested version name — routing test builds to
  the optional `ota_http_server_test` (default `${ota_http_server}`) and everything else to the
  required `ota_http_server`. `.test` is matched only as a whole dotted segment, because version
  names are sorted and `.test` is not necessarily the last suffix. The rollback watchdog armed on
  boot here is cancelled by `criotive_mqtt.yaml`'s `on_connect` once the broker is reached.
- `diagnostics.yaml` — `debug` platform, device info, reset reason.
- `controls.yaml` — shutdown / restart / safe-mode / factory-reset buttons.
- `location.yaml` — `google_location` and its `external_components`.

### Optional hardware modules

A device imports one of these only if it has that hardware.

- `tca8418.yaml` — I2C GPIO expander (`TCA8418GPIOPin`); a general capability, usable as a pin
  source by any component.
- `medeawiz.yaml` — serial video-player driver.
- `phone.yaml` — prop driver.

### Hardware modules

A hardware module owns the platform component (`esp32:`) and the board's own I/O. Board, variant
and framework are **concrete** — never `${DEVICE_BOARD}`/`${DEVICE_VARIANT}` templating. A device
imports exactly one hardware module. Names were renamed from the legacy `ciot_*`; the legacy names
do not appear in the SDK, and the ESP32-only scope excludes the legacy `mr60bha2dev`, `r`, `esp12`
and `nodemcu32` boards.

| Module | board | variant | framework | ported from |
|---|---|---|---|---|
| `hds_v1_0.yaml` | `pico32` | `esp32` | `arduino` | legacy `ciot_v1_0` |
| `hds_v1_1.yaml` | `esp32dev` | `esp32` | `arduino` | legacy `ciot_v1_1` |
| `hds_v2_0.yaml` | `esp32-s3-devkitc-1` | `esp32s3` | `arduino` | legacy `ciot_v2_0` |

- `hds_v1_0.yaml` — CAN termination resistor on GPIO12 (`ALWAYS_ON`).
- `hds_v1_1.yaml` — on-board push button SW1 on GPIO1 and the CAN termination resistor on GPIO12
  (`ALWAYS_ON`). SW1 presses the standard `controls.yaml` buttons (`button_restart` on a short
  click, `button_factory` on longer holds), so a device with this board imports `controls.yaml`.
- `hds_v2_0.yaml` — the ESP32-S3 board definition only; the legacy board declared no on-board I/O.

**OTA visual feedback / LED ownership.** If a hardware file has indicator LEDs it owns its own OTA
visual feedback and drives those LED ids itself — no module reaches into a hardware id. None of
these three boards has indicator LEDs (the legacy blink-on-OTA animation was gated on
`#ifdef HARDWARE_FREEZER`, a board that is out of scope here), so none ships OTA LED feedback; the
`ota.yaml` module keeps no reference to any hardware id.
