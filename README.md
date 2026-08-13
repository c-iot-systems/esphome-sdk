# criotive ESPHome SDK

Shared ESPHome configuration for criotive firmware, consumed through ESPHome's native
[`packages:`](https://esphome.io/components/packages.html) mechanism. The firmware-generation path
and the build service assemble a device's `main.yaml` by importing modules from this repository at a
pinned tag.

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
| `hds_v1_0` / `hds_v1_0_idf` | `pico32` | `esp32` | arduino / esp-idf |
| `hds_v1_1` / `hds_v1_1_idf` | `esp32dev` | `esp32` | arduino / esp-idf |
| `hds_v2_0` / `hds_v2_0_idf` | `esp32-s3-devkitc-1` | `esp32s3` | arduino / esp-idf |

Each board ships an arduino and an esp-idf variant as separate files with concrete framework values
(see "Hardware modules" below); a device imports exactly one.

## Substitution contract

`core.yaml` is the one documented place answering *"what must every firmware supply?"*. Every
parameter arrives as a YAML `substitutions:` value — **nothing is a C++ preprocessor define**, because
the build path injects no compiler flags. Substitution names are `lower_snake_case`.

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
| `wifi_reboot_timeout` | no | `0s` | *(`wifi.yaml`)* — `0s` **disables** the WiFi reboot (offline survival) |
| `mqtt_broker` | **yes** | — | *(`criotive_mqtt.yaml`)* |
| `mqtt_ca_certificate` | **yes** | — | **the TLS trust anchor — see below** |
| `mqtt_port` | no | `8883` | conventional TLS port; the port alone does **not** enable TLS |
| `mqtt_username` | **yes** | — | **no default, ever** |
| `mqtt_password` | **yes** | — | **no default, ever** |
| `mqtt_client_id` | no | `${device_name}` | MQTT client id; independent of `topic_prefix` — set it explicitly when a deployment needs a specific value — see below |
| `mqtt_reboot_timeout` | no | `0s` | `0s` **disables** the MQTT reboot (offline survival) |
| `mqtt_discovery` | no | `true` | Home Assistant discovery |
| `ota_password` | **yes** | — | *(`ota.yaml`)* — **no default, ever** |
| `ota_attempts` | no | `50` | safe-mode boot attempts — larger recovery budget (ESPHome stock is `5`) |
| `ota_http_server` | **yes** | — | HTTPS OTA download host |
| `ota_http_server_test` | no | `${ota_http_server}` | *(`ota.yaml`)* test/staging OTA host — see below |
| `logger_level` | no | `NONE` | logging is **off by default** — see below |

**No credential has a default.** A default password in a public repo is a default password in every
device that forgets to override it. A missing required substitution must fail validation loudly, and
the PR-time `esphome config` check plus the negative-fixture harness prove it does.

### A device never reboots through an outage — offline survival is an invariant

**A device MUST continue operating indefinitely while offline, without rebooting.** Field devices on
unreliable uplinks must ride out an outage rather than power-cycle through it. This is not a
preference; both reboot timeouts are pinned to `0s` for exactly this reason.

- `wifi_reboot_timeout` and `mqtt_reboot_timeout` both default to **`0s`**, which **disables** the
  respective connectivity reboot outright. Verified against ESPHome 2026.5.1 source — both components
  guard `App.reboot()` with `reboot_timeout_ != 0` (`wifi/wifi_component.cpp:867`,
  `mqtt/mqtt_client.cpp:418`), so `0s` makes the reboot branch unreachable. ESPHome's stock default
  is `15min` for both; leaving that in place would power-cycle a device every 15 minutes it is
  offline. Both stay overridable per device — only the default is pinned to `0s`.
- **No component may introduce a connectivity-driven reboot.** `ota.yaml`'s rollback watchdog is
  gated so it only ever affects a firmware image still pending verification right after an OTA — a
  confirmed image that is merely long-offline is never rolled back (see the OTA rollback section).
- **Regression guard.** `scripts/check-offline-survival.sh` (wired into `validate.yml`, with a
  self-test proving it fails on a known-bad `reboot_timeout: 15min`) fails the build if any
  `reboot_timeout` default under `modules/` or `hardware/` resolves to a non-zero value.

#### "Never auto-publish": use `update_interval: never`

A "never auto-publish" periodic sensor must **not** be expressed with a magic maximum-interval
number. ESPHome's `update_interval: never` literal says exactly that, far more clearly, and is used
at every such site here (`firmware_version`, `sensor_boots`, `ota_status`, `google_location`). Future
entities that should publish only on an explicit `publish_state()` must use `never`, not a numeric
sentinel.

### Logging is off in production by default

`logger_level` defaults to **`NONE`**: a device ships silent and its `logger:` emits nothing until a
consumer raises the level **deliberately**, per device — never on by default. A chatty default is not
free: it costs flash, CPU and (when a device also publishes logs) broker traffic on every unit that
forgot to turn it down.

To raise it, set the substitution per device to one of ESPHome's levels — `INFO`, `DEBUG`,
`VERBOSE` or `VERY_VERBOSE`:

```yaml
substitutions:
  logger_level: DEBUG   # opt in per device; production stays NONE
```

The knob is unchanged — only its default flipped from `INFO` back to `NONE`.

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
`certificate_authority`. The CA is supplied by the caller, so different deployments can select their
own trust anchor and rotate it without an SDK release.

### `mqtt_client_id` — set it explicitly when a deployment needs a specific value

The MQTT client id is **not** the topic prefix. `mqtt_client_id` sets the MQTT `client_id`; it
defaults to `${device_name}` (so `client_id == topic_prefix` for the common case) and is overridden
per device when a specific value is required. It is the SDK's own knob — the SDK does not otherwise
depend on what a broker does with it, and only what the SDK owns is documented here.

Whether the client id matters, and how, depends on the broker:

- **Some brokers require `client_id == username`** and reject a mismatch at CONNACK. Others do not —
  a broker whose authenticator matches, say, a client certificate's common name against the username
  never compares the client id, so a device with `client_id != username` connects fine there.
- **Some brokers use the client id to namespace topics**, so an unexpected id can misroute a
  device's messages. Set `mqtt_client_id` explicitly when a deployment relies on either behaviour.

`client_id` and `topic_prefix` are kept **independent**: a device may use a non-prefixed client id
while keeping the device-name topic prefix, so `mqtt_client_id` is its own override and is never
derived from the prefix. `criotive_mqtt.yaml` also sets `client_id` **explicitly** rather than
relying on ESPHome's default — left unset, ESPHome (`mqtt/mqtt_client.cpp:44`) sets it to
`${device_name}-<mac>`, which is unpredictable and can break both broker behaviours above.
`tests/validate/mqtt_client_id.yaml` proves an overridden id resolves into `mqtt: client_id:` while
`topic_prefix` stays `${device_name}`; `tests/validate/mqtt_ota.yaml` proves the default path
resolves `client_id` to the device name.

### MQTT log publishing is off by default

`criotive_mqtt.yaml` ships with MQTT log publishing off: **no device streams its logs to MQTT unless
a consumer opts in.**

This is not the same as omitting the key. ESPHome's `mqtt` component (`mqtt/__init__.py`,
`validate_config`) **re-injects** a default `${topic_prefix}/debug` log topic (with `retain: true`)
whenever a `topic_prefix` is set, so merely deleting `log_topic` would leave every device publishing
its logs. Disabling requires the key to be **present but empty** — `log_topic:` with a null value —
which drives the codegen branch `if not log_topic: disable_log_message()`. `esphome config` over
`tests/validate/mqtt_ota.yaml` proves it: the dumped `mqtt:` shows `log_topic: null` and no `/debug`
topic, the same standard by which the fixture proves the TLS `certificate_authority`.

**Opting in (per device).** A consumer that wants a device's logs on the broker sets **two** things
in that device's config: its own `mqtt: log_topic:` block (which merges over the module's null) **and**
a non-`NONE` `logger_level`. Both are needed — the global `logger:` level gates which records are ever
produced, so a `log_topic` with `logger_level: NONE` (the default) publishes nothing and the topic
stays silent:

```yaml
substitutions:
  logger_level: INFO   # or DEBUG/VERBOSE/VERY_VERBOSE — REQUIRED, or nothing is published
mqtt:
  log_topic:
    topic: ${device_name}/debug
    qos: 0
    retain: false      # REQUIRED for a log topic — see below
```

`retain` **must be `false`** here. Retain is correct for birth / will / shutdown, where the retained
message is the device's *current* online state a new subscriber should see immediately. A log topic
is a rolling stream: each line overwrites the last, so a retained log topic makes the broker replay
one arbitrary, stale log line to every new subscriber — never what a log consumer wants.
`tests/validate/mqtt_log_optin.yaml` exercises this opt-in path.

### OTA rollback watchdog is offline-safe

`ota.yaml` arms a 300s post-boot rollback watchdog and `criotive_mqtt.yaml` cancels it once the
broker is reached — so a freshly-flashed image that cannot reach the broker rolls back to the last
known-good build. Audited against the offline-survival invariant: ESP-IDF's
`esp_ota_mark_app_invalid_rollback_and_reboot()` does **not** check the running image's OTA state, so
unguarded it would roll back even a **confirmed** image whenever a rollback target exists — rebooting
a healthy device that merely power-cycled during an outage and can't reach the broker within 300s.
The watchdog is therefore gated on `ESP_OTA_IMG_PENDING_VERIFY` (ESP-IDF's own idiom in
`esp_ota_begin`): only a freshly-flashed, not-yet-verified image can roll back; a confirmed,
long-offline image is never touched. OTA safety is preserved and offline survival is guaranteed.

That gate only holds if **nothing confirms the image before the broker does**. ESPHome's `safe_mode`
auto-confirms the running image on a timer — `esp_ota_mark_app_valid_cancel_rollback()` after
`boot_is_good_after`, whose stock default is `1min` — and on esp-idf (where OTA rollback is enabled by
default) that is the only early confirmer. At the stock 1 minute the image would already be
`ESP_OTA_IMG_VALID` four minutes before the 300s watchdog fires, so its `PENDING_VERIFY` gate could
never trigger and a genuinely bad OTA would silently survive. `ota.yaml` therefore sets
`safe_mode: boot_is_good_after: 330s` — past the watchdog — so the **broker**, not a boot timer, owns
validity confirmation for the whole window. The trade-off: on esp-idf a freshly-flashed image stays
subject to bootloader rollback-on-reboot until it either reaches the broker or survives 330s, slightly
longer than ESPHome's default; a device that has already confirmed once is unaffected. The
`check-rollback-timing.sh` gate fails the build if `boot_is_good_after` ever drops to or below the
watchdog delay, so this ordering can never silently regress.

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
  hardware/                     # per-board files: hds_v1_0/1_1/2_0 (arduino) + *_idf variants,
                                #   the hds_v1_1_sw1 opt-in unit, and each board's slot pin table
  components/                   # ESPHome custom components (C++)
  tests/validate/               # minimal configs exercised by CI (see tests/validate/README.md)
  tests/negative/               # configs that MUST fail (missing required substitutions)
  scripts/                      # CI check scripts (automation-syntax, sdk-ref, negative, offline-survival)
  .github/workflows/            # validate (PR) and release (tag) CI
```

## Continuous integration

- **`validate.yml`** runs on every pull request: it materializes the PR head SHA into each validate
  config's package `ref` and `vars.sdk_ref`, runs `esphome config` over `tests/validate/`, and runs
  the `check-automation-syntax.sh`, `check-sdk-ref.sh`, `check-negative.sh` and
  `check-offline-survival.sh` gates (the last fails the build if any `reboot_timeout` default under
  `modules/`/`hardware/` is non-zero — the offline-survival invariant). This validates the *revision
  under test*, never a published tag.
- **`release.yml`** runs on a version tag: it materializes `GITHUB_REF_NAME`, asserts every fixture
  resolves to that tag, and runs a real `esphome compile` over `tests/validate/` — so no version is
  ever published without every shipped component having been built at least once.

CI validates against ESPHome **2026.5.1** (pinned in `validate.yml` / `release.yml`). This is the
version the SDK is checked and compiled against; it is not a claim about which ESPHome version any
build service installs.

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

A device imports one of these **only if it has that hardware** — they are drivers, not business
logic, and are not replaceable by standard switches. Each module declares **only** its own
`external_components` source (pinned to `${sdk_ref}`); it does **not** instantiate the component,
because the instance is inherently device-specific (I2C address, UART bus, which pins, key layout).
A device imports the module to make the driver available and then declares the instance in its own
private config. Each has a validate fixture under `tests/validate/` that instantiates it, so release
CI compiles the C++ at least once per release.

- **`tca8418.yaml` — TCA8418 I2C GPIO expander.** `TCA8418Component` extends
  `gpio_expander::CachedGpioExpander<uint32_t, 32>` and registers `TCA8418GPIOPin` as a real
  `GPIOPin`, adding 18 pins (ROW0–ROW7, COL0–COL9) over I2C that any component can use as a pin
  source — a `binary_sensor`/`switch` on `platform: gpio`, etc. A general capability, unrelated to
  ESPHome's native `matrix_keypad`/`key_collector` (those *scan* a keypad matrix; this *provides*
  pins). **Import it when** a board runs short on native GPIO. The
  component AUTO_LOADs `gpio_expander` and DEPENDS on `i2c`, so the device must also declare an
  `i2c:` bus. Instantiate `tca8418:` with the board's address, then reference a pin as
  `pin: {tca8418: <id>, number: 0-17, mode: {...}}`.
- **`medeawiz.yaml` — MedeaWiz Sprite 4K serial video-player driver.** Controls a Sprite (DV-S4)
  over its TTL serial port with a bespoke single-byte protocol (play file N, seek, volume,
  request position/duration, end-of-file feedback); no ESPHome-native equivalent exists. **Import
  it when** the device drives a MedeaWiz Sprite. DEPENDS on `uart`, so the device must declare a
  `uart:` bus **with a tx pin** (the Sprite receives commands on tx). Instantiate `medeawiz:` on
  that bus and use its actions (`medeawiz.play_file`, `medeawiz.seek`, …) and triggers
  (`on_file`, `on_end_of_file`).
- **`phone.yaml` — matrix-keypad "phone" keypad driver.** Scans a keypad matrix (or individual column
  buttons when no rows are given), debounces presses, tracks on/off-hook from an optional
  `binary_sensor`, and matches typed sequences against configured passwords, firing right/wrong
  triggers. No ESPHome-native component does this. **Import it when** the device drives a keypad
  "phone" device. Instantiate `phone:` with the concrete `rows`/`columns` pins (plain `GPIOPin`s — so
  they may be native GPIO **or** a `tca8418` expander pin), the `keys` layout (length must equal
  rows × columns), and any hook sensor / passwords / automations the device needs.

### Hardware modules

A hardware module owns the platform component (`esp32:`) and the board's own I/O. Board, variant
and framework are **concrete** — never a `${...}` board/variant/framework substitution. A device
imports exactly one hardware module. The ESP32-only scope excludes the `mr60bha2dev`, `r`, `esp12`
and `nodemcu32` boards.

| Module | board | variant | framework | board revision |
|---|---|---|---|---|
| `hds_v1_0.yaml` | `pico32` | `esp32` | `arduino` | v1.0 |
| `hds_v1_0_idf.yaml` | `pico32` | `esp32` | `esp-idf` | v1.0 |
| `hds_v1_1.yaml` | `esp32dev` | `esp32` | `arduino` | v1.1 |
| `hds_v1_1_idf.yaml` | `esp32dev` | `esp32` | `esp-idf` | v1.1 |
| `hds_v2_0.yaml` | `esp32-s3-devkitc-1` | `esp32s3` | `arduino` | v2.0 (ESP32-S3) |
| `hds_v2_0_idf.yaml` | `esp32-s3-devkitc-1` | `esp32s3` | `esp-idf` | v2.0 (ESP32-S3) |

- `hds_v1_0.yaml` — CAN termination resistor on GPIO12.
- `hds_v1_1.yaml` — the CAN termination resistor on GPIO12. The on-board SW1 button is **not** wired
  here (see "SW1 / GPIO1" below).
- `hds_v2_0.yaml` — the ESP32-S3 board definition only; the v2.0 board has no fixed on-board I/O.

**CAN termination — `can_resistor_status`.** `hds_v1_0` and `hds_v1_1` carry the CAN bus
termination resistor and own an optional `can_resistor_status` substitution (default `ALWAYS_ON`)
that sets its restore mode. Only the two endpoint nodes of a CAN segment should terminate; a node
wired mid-bus **must** override `can_resistor_status: ALWAYS_OFF`, or two terminators become three
and the bus is corrupted. The two v1 validate fixtures exercise both values — `hds_v1_0` at the
`ALWAYS_ON` default and `hds_v1_1` overriding to `ALWAYS_OFF`.

**OTA visual feedback / LED ownership.** If a hardware file has indicator LEDs it owns its own OTA
visual feedback and drives those LED ids itself — no module reaches into a hardware id. None of
these boards has indicator LEDs, so none ships OTA LED feedback and `ota.yaml` keeps no reference to
any hardware id.

#### esp-idf framework variants

Framework is a **concrete** value, so each board ships as two separate files rather than a templated
`framework:` — an arduino build (`hds_v1_0.yaml`) and an esp-idf build (`hds_v1_0_idf.yaml`), and a
device imports exactly one. The `_idf` file reuses its arduino sibling wholesale (same board, variant
and the full slot pin table) and overrides **only** `esp32.framework` to `esp-idf`, so the two can
never drift.

The framework choice has one behavioural consequence in the shared modules: `ota.yaml`'s post-boot
**rollback watchdog is compiled inside `#ifdef USE_ESP_IDF`**. So on an **arduino** build it is
compiled out entirely (there is no ESP-IDF rollback API on that path) and carries no protection; on
an **esp-idf** build it is active and guards a freshly-flashed image (see the OTA rollback section).
A device that needs the post-OTA rollback safety must therefore be on an esp-idf board file. The
`*_idf` validate fixtures compile that guard on release.

#### SW1 / GPIO1 — opt-in, because it silences serial logging

The v1.1 board has an on-board push button, SW1, on **GPIO1** — which is the ESP32's **U0TXD**
(primary UART TX). Configuring SW1 as a GPIO input takes GPIO1 away from the UART, so **the serial
console goes silent** on that board. Because that trade-off must be a deliberate choice, SW1 is **not**
wired in the board file; it lives in the importable unit **`hardware/hds_v1_1_sw1.yaml`**. To use the
button, a device imports `hds_v1_1_sw1.yaml` **and** `controls.yaml` (SW1's `on_click` presses
`button_restart` on a short click and `button_factory` on longer holds). To keep serial logs on the
board instead, simply **do not** import `hds_v1_1_sw1.yaml` — GPIO1 stays on the UART. A substitution
cannot conditionally omit a YAML block, so the two-file split is what makes SW1 genuinely optional.

#### Slot pin tables — `slot_<n>_<module>_<signal>`

Each board file also carries a static table of **slot pin substitutions**. A board has a set of
numbered module slots; a pluggable module wired into a slot exposes named signals; and each
`slot_<n>_<module>_<signal>` substitution resolves that signal, for that module in that slot, to the
physical GPIO it lands on. Names are `lower_snake_case`. For example, a Double Relay wired into slot 3
uses `${slot_3_double_relay_relay_1}` for relay 1's pin; an Audio module's RX in slot 7 uses
`${slot_7_audio_rx}`. Only combinations that physically fit a board are listed, and each board's table
is board-specific — the same module in the same slot resolves to different pins on different boards.

The values are **static data**, transcribed from the board's slot/module definitions and cross-checked
against them; there is no generator, codegen step or regeneration procedure in this repository. Which
slot actually holds which module is the **consumer's** responsibility: the SDK never sees a device's
populated slot map, so it **cannot** validate that `slot_3_double_relay_*` is used on a board whose
slot 3 really holds a Double Relay. A tool that consumes an explicit populated slot map could enforce
that pairing; this SDK does not, so it becomes authoring discipline. `esphome config` still catches a
**mistyped** name (its `${...}` stays a literal
and fails the pin schema), which the `slot_pins_*` validate fixtures exercise — one substitution per
module type per board — but it cannot catch a *wrong-but-valid* slot choice.
