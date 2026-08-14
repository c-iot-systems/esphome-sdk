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

The public SDK covers **xtensa-esp32** only. riscv32 (`mr60bha2dev`) and ESP8266
(`r`, `esp12`, `nodemcu32`) are out of scope and are never compile-tested here —
`ota.yaml`'s `http_request` OTA, `preferences` and parts of `wifi.yaml` genuinely differ on ESP8266.
Anyone using the SDK on an ESP8266 is off the supported path. ESP8266 can be added later if
customers ask.

Supported hardware:

| Hardware module | Board | Variant | Framework |
|---|---|---|---|
| `hds_v1_0` | `pico32` | `esp32` | `${framework_variant}` (default esp-idf) |
| `hds_v1_1` | `esp32dev` | `esp32` | `${framework_variant}` (default esp-idf) |

Each board is a single file whose esp32 framework is the `framework_variant` substitution, so one
board file serves both frameworks. The default is **esp-idf**; a device that wants the arduino
toolchain sets `framework_variant: arduino` (see "Hardware modules" below). Board and variant stay
concrete.

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
| `wifi_ssid` | no | *(empty)* | *(`wifi.yaml`)* station slot 1 — see **Up to three WiFi networks** |
| `wifi_password` | no | *(empty)* | required once slot 1 has an SSID; **no usable default, ever** |
| `wifi_ssid_2` | no | *(empty)* | station slot 2 |
| `wifi_password_2` | no | *(empty)* | required once slot 2 has an SSID |
| `wifi_ssid_3` | no | *(empty)* | station slot 3 |
| `wifi_password_3` | no | *(empty)* | required once slot 3 has an SSID |
| `wifi_ap_password` | **yes** | — | fallback AP; **no default, ever** |
| `wifi_reboot_timeout` | no | `0s` _(safety)_ | *(`wifi.yaml`)* — `0s` **disables** the WiFi reboot (offline survival) |
| `mqtt_broker` | **yes** | — | *(`criotive_mqtt.yaml`)* |
| `mqtt_ca_certificate` | **yes** | — | **the TLS trust anchor — see below** |
| `mqtt_port` | **yes** | — | *(`criotive_mqtt.yaml`)* — stated explicitly, no default; the port alone does **not** enable TLS |
| `mqtt_username` | **yes** | — | **no default, ever** |
| `mqtt_password` | **yes** | — | **no default, ever** |
| `mqtt_client_id` | no | `${device_name}` _(convenience)_ | MQTT client id; independent of `topic_prefix` — set it explicitly when a deployment needs a specific value — see below |
| `mqtt_reboot_timeout` | no | `0s` _(safety)_ | `0s` **disables** the MQTT reboot (offline survival) |
| `mqtt_discovery` | no | `true` _(convenience)_ | Home Assistant discovery |
| `ota_password` | **yes** | — | *(`ota.yaml`)* — **no default, ever** |
| `ota_attempts` | no | `50` _(safety)_ | safe-mode boot attempts — larger recovery budget (ESPHome stock is `5`) |
| `ota_http_server` | **yes** | — | HTTPS OTA download host |
| `ota_http_server_test` | no | `${ota_http_server}` _(convenience)_ | *(`ota.yaml`)* test/staging OTA host — see below |
| `logger_level` | no | `NONE` _(safety)_ | logging is **off by default** — see below |
| `logger_baud_rate` | no | `0` _(safety)_ | `0` **disables** the serial console (skips UART init) — see below |
| `logger_hardware_uart` | no | `UART0` _(convenience)_ | logger UART; `UART0` is the only console these boards can use — see below |
| `diagnostics_update_interval` | no | `60s` _(convenience)_ | *(`diagnostics.yaml`)* cadence for debug sensors a device attaches to the `debug` component — see below |

Defaults are tagged **_(safety)_** or **_(convenience)_**. A **safety** default encodes a deliberate
protective posture — offline survival (`*_reboot_timeout: 0s`), production-quiet logging
(`logger_level: NONE`, `logger_baud_rate: 0`), a larger recovery budget (`ota_attempts`) — and should
not be overridden without a specific reason; the same holds for the hardware-file safety defaults
(`framework_variant: esp-idf` and `ota_rollback: true`, which ship OTA rollback protection, and
`can_resistor_status: ALWAYS_ON`). A **convenience** default is just a sensible starting value
(`mqtt_client_id`, `mqtt_discovery`, `logger_hardware_uart`, `ota_http_server_test`) that a device
overrides freely.

**No credential — and now no connection port — has a default.** A default password in a public repo is
a default password in every device that forgets to override it, and a defaulted `mqtt_port` could be
silently wrong; a missing required substitution must fail validation loudly, and the PR-time
`esphome config` check plus the negative-fixture harness prove it does.

### Up to three WiFi networks — and the provisioning-only mode

`wifi.yaml` configures **up to three** candidate station networks, in three slots:
`wifi_ssid`/`wifi_password`, `wifi_ssid_2`/`wifi_password_2`, `wifi_ssid_3`/`wifi_password_3`. A slot
is used only when its SSID is non-empty, so a single-network device fills slot 1 and ignores the
rest, and filling slots 1 and 3 yields a two-entry list with no gap.

```yaml
substitutions:
  wifi_ssid: site-main
  wifi_password: main-network-password
  wifi_ssid_2: site-backup          # optional; omit the pair entirely to leave the slot unused
  wifi_password_2: backup-network-password
```

**Order is not priority.** ESPHome scans and connects to the best network it can see among those
configured, so the slots are alternatives rather than a fallback chain. Three is a product choice,
not a platform limit — ESPHome's own cap is `MAX_WIFI_NETWORKS = 127`.

**A slot is all-or-nothing.** Every slot is optional and defaults to empty, which is *not* a
credential default: an empty SSID is unusable, and no password is usable without its SSID. But a
password set against an **empty SSID** is a hard `esphome config` failure, via the same `1/0` guard
idiom used for required substitutions. That keeps the likely misconfiguration — a forgotten or
mistyped SSID name — loud. The case it cannot catch is a typo in *both* names of a pair, which
leaves the slot silently unused.

**Leaving every slot empty is supported**, and is how a device ships when WiFi is provisioned in the
field through the captive portal rather than baked into the firmware. It is not simply "the same
config minus the credentials" — it changes where ESPHome keeps the credentials the captive portal
saves (`wifi_component.cpp:648`):

```cpp
uint32_t hash = this->has_sta() ? App.get_config_version_hash() : 88491487UL;
this->pref_ = global_preferences->make_preference<wifi::SavedWifiSettings>(hash, true);
```

`get_config_version_hash()` is an FNV-1a over the **entire rendered config dump**
(`core/__init__.py:706`). So:

- **With any slot filled**, captive-portal credentials are keyed to that exact config and are
  silently dropped by *any* change to it — a new entity, an ESPHome upgrade, or simply a
  `firmware_version` bump, which means **every OTA release**. The device then falls back to the
  configured slots. Fine when the slots are the real networks; surprising if someone re-provisioned
  a unit by hand and expected it to stick.
- **With no slot filled**, `has_sta()` is false at boot, the key is the constant `88491487UL`, and
  the saved credentials survive OTAs and config changes.

Either way the captive-portal network **replaces** the configured slots rather than joining them:
`WiFiComponent::start()` applies the saved credentials through `set_sta()`, which begins with
`clear_sta()` (`wifi_component.cpp:1003`).

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

#### The serial console — `logger_baud_rate` and `logger_hardware_uart`

`logger_level` gates which records are ever *produced*; `logger_baud_rate` gates whether a UART
*console* exists to print them on. They are **independent**, and the console is **off by default**:
`logger_baud_rate` defaults to **`0`**, which skips UART init entirely (ESPHome 2026.5.1 guards it
with `if (this->baud_rate_ > 0)` and `0` still validates, since the field is `positive_int`
= `int_range(min=0)`). So **raising serial logs takes both knobs** — a non-`NONE` `logger_level`
*and* a non-zero `logger_baud_rate`:

```yaml
substitutions:
  logger_level: INFO       # gate record production
  logger_baud_rate: "115200"  # AND open the UART console — both are required
```

`logger_hardware_uart` selects which UART the console uses. It defaults to **`UART0`**, which is the
only console the supported boards can actually use: `UART1`/`UART2`'s default pins are wired to flash
on these modules and the logger schema exposes no `tx_pin` override.

**A serial console and a GPIO1 button are mutually
exclusive — a hardware constraint, not a configuration choice.** `UART0`'s TX is **GPIO1 (U0TXD)**,
the same pin `hds_v1_1`'s on-board **SW1** button uses. `UART1`/`UART2`'s default pins are wired to
flash on typical modules and the logger schema exposes no `tx_pin` override, so there is no way to
keep both. **Raising `logger_baud_rate` does NOT free GPIO1** — SW1 still owns the pin whenever the
SW1 `binary_sensor` exists, so the baud rate is *not* the SW1 opt-out. The opt-out is the
compile-time **`hds_v1_1_sw1_enabled`** flag: set it `false` (unquoted) to drop SW1, and a device that
needs serial logs also sets a real `logger_baud_rate` (see the [SW1 / GPIO1](#sw1--gpio1--gated-by-a-compile-time-flag)
section for the full table). `esphome config` cannot catch the pin overlap — it is a
physical-pin conflict the schema never sees — so it is stated here as a hardware fact.

### Required substitutions fail loudly — the guard idiom

Merely *referencing* `${x}` does **not** make a substitution required. ESPHome 2026.5.1 runs the
substitution pass non-strict (`components/substitutions/__init__.py`): an undefined `${x}` only logs
a **warning** and leaves the literal text in place, so `esphome config` still exits 0 unless the
leftover literal happens to break a field's schema. `device_name` is the lucky case — it lands in
`esphome: name:`, whose identifier schema rejects the `${device_name}` literal. Every other required
substitution lands in a free-form string field that accepts the literal, so each is wrapped in a
guard:

```yaml
password: "${ wifi_ap_password if wifi_ap_password is defined else 1/0 }"
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
`boot_is_good_after`, whose stock default is `1min` — and on esp-idf (where the board files pin
`esp32: framework: advanced: enable_ota_rollback: true`, defining `USE_OTA_ROLLBACK`, so `esp32/hal.cpp`
guards its own immediate boot-time mark-valid with `#ifndef USE_OTA_ROLLBACK` and defers to safe_mode)
that timer is the only early confirmer. At the stock 1 minute the image would already be
`ESP_OTA_IMG_VALID` four minutes before the 300s watchdog fires, so its `PENDING_VERIFY` gate could
never trigger and a genuinely bad OTA would silently survive. `ota.yaml` therefore sets
`safe_mode: boot_is_good_after: 330s` — past the watchdog — so the **broker**, not a boot timer, owns
validity confirmation for the whole window. The trade-off is twofold. First, on esp-idf a
freshly-flashed image stays subject to bootloader rollback-on-reboot until it either reaches the
broker or survives 330s, slightly longer than ESPHome's default; an image that has already confirmed
(reached the broker once, or lived past 330s) is `ESP_OTA_IMG_VALID` and is never rolled back by this
mechanism. Second — and this affects **every** boot, not just a freshly-flashed one — `safe_mode`
clears its boot-loop counter inside the same `mark_successful()` that confirms the image, so raising
`boot_is_good_after` from ESPHome's stock `1min` to `330s` also delays that counter reset to 330s on
each boot. A device that power-cycles repeatedly within 330s of boot therefore accumulates those boots
toward safe mode even though it is otherwise healthy. The SDK's `num_attempts: 50` (ten times
ESPHome's stock `5`) absorbs this: fifty sub-330s power-cycles in a row would be required before
safe mode triggers, far beyond any normal power event. The `check-rollback-timing.sh` gate fails the
build if `boot_is_good_after` ever drops to or below the watchdog delay, so the confirmation ordering
can never silently regress.

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
- **Semantic versioning over the substitution contract.** The SDK's public surface is the set of
  substitutions a config supplies: renaming or removing one — required *or* optional — is a
  breaking change plus a migration of stored configs. Removing an *optional* one is the worse case,
  because the value a stored config sets is not rejected, it is silently ignored and the device
  takes a different default.
- **Pre-1.0 the number answers one question:** *is it safe to re-pin?*

  | bump  | means                                                                   |
  |-------|-------------------------------------------------------------------------|
  | minor | **migration required** — a breaking change to the substitution contract  |
  | patch | **safe to re-pin** — features and fixes                                  |

- The first tag is **`v0.1.0`** — the module boundaries have not survived a real product yet.
- Versions are computed from [Conventional Commit](https://www.conventionalcommits.org/) subjects
  by [release-please](https://github.com/googleapis/release-please), which keeps a release PR open
  carrying the proposed version and the generated `CHANGELOG.md`; merging that PR is what publishes
  a tag. `scripts/check-contract-diff.sh` fails any PR whose substitution-contract change is
  breaking without a commit that declares it breaking, so the computed number cannot disagree with
  what actually changed. See [`AGENTS.md`](AGENTS.md) for the commit convention and release steps.
- **No secrets, ever.** Every credential arrives as a substitution; a value committed to a public
  repo is permanent and cannot be revoked by deletion.

## Repository layout

```
esphome-sdk/
  README.md                     # this file — substitution contract, scope, versioning
  AGENTS.md                     # commit convention, release process, gate index
  modules/                      # shared + optional-hardware modules
  hardware/                     # per-board files: hds_v1_0/1_1/2_0 (framework via ${framework_variant}),
                                #   hds_v1_1's SW1 flag, and each board's slot pin table
  components/                   # ESPHome custom components (C++)
  tests/validate/               # minimal configs exercised by CI (see tests/validate/README.md)
  tests/negative/               # configs that MUST fail (missing required substitutions)
  scripts/                      # CI gate scripts, each with a --self-test
  version.txt                   # current version, maintained by release-please
  CHANGELOG.md                  # generated by release-please
  release-please-config.json    # versioning policy (pre-1.0 bump mapping, changelog sections)
  .github/workflows/            # validate (PR), release-gate (main: compile then release), release (tag)
```

## Continuous integration

Every gate is a script under `scripts/` carrying a `--self-test` that proves its own FAIL paths;
CI runs the self-test before the real check, so a gate that has been defanged fails loudly instead
of passing silently.

- **`validate.yml`** — every pull request. Materializes the PR head SHA into each validate config's
  package `ref` and `vars.sdk_ref`, runs `esphome config` over `tests/validate/`, and runs the
  `check-automation-syntax.sh`, `check-sdk-ref.sh`, `check-negative.sh`, `check-offline-survival.sh`,
  `check-rollback-timing.sh` and `check-contract-diff.sh` gates. This validates the *revision under
  test*, never a published tag.
- **`release-gate.yml`** — every push to `main`. `compile` runs the real `esphome compile`, one
  parallel job per fixture (the list is discovered, not hardcoded, so a new fixture cannot escape
  the gate); `negative` runs the executable negative harness; `gates` re-runs every invariant script
  plus the contract gate against the last published tag. `release` (release-please, which maintains
  the release PR and creates the tag) **needs** all three. Merging the release PR is itself a push to `main`, so the commit that gets
  tagged is compiled first — if it does not build, no tag is ever created. This is the gate that can
  still **stop** a bad release, rather than merely report one.
- **`release.yml`** — a published tag, or `workflow_dispatch` with a tag input. Re-verifies a tag
  end-to-end. Belt-and-braces: by the time it runs the tag is already public and permanent, which is
  why the blocking compile lives in `release-gate.yml`.

CI validates against ESPHome **2026.5.1** (pinned in each workflow). This is the version the SDK is
checked and compiled against; it is not a claim about which ESPHome version any build service
installs.

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
- `diagnostics.yaml` — `debug` platform, device info, reset reason. Its `debug` component polls on
  `diagnostics_update_interval` (default `60s`). The interval is neither `0s` nor `never` on purpose:
  ESPHome coerces a 0 ms interval to **1 ms** (a 1 kHz wakeup on every device), while `never` would
  silence any numeric debug sensors — free heap, loop time, cpu frequency — that a **consuming**
  firmware attaches to this same component, since `DebugComponent::update()` is the only place those
  publish. The module's own two text sensors are unaffected either way: they publish from
  `dump_config()` at boot. A device with no debug sensors may set `never`.
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

  **A password may be templatable.** `password:` accepts a lambda as well as a literal, and it is
  resolved on every submission — so `password: !lambda "return id(my_text).state;"` lets an operator
  change the code from a `text:` entity without a reflash, while a literal still compiles to a
  constant. A prop whose codes are configured from the platform wants the lambda form.

  **`phone.submit` / `phone.clear` drive it from outside the matrix.** `enter_keys` and `clear_keys`
  can only name keys on the phone's own matrix, so a prop whose enter button is a separate GPIO — or
  whose reset is driven by an automation — has no key to name. The two actions submit and clear the
  accumulated input directly; `phone.submit` ignores empty input, exactly as the enter key does.

  **Prefer `on_no_match` to a per-password `on_password_wrong`.** The per-entry trigger fires once
  for **every** entry the input did not match, so with N passwords configured a single wrong code
  fires it N times — right when the passwords are independent locks, wrong when they are
  alternatives (one keypad, one code per colour). The component-level `on_no_match` fires exactly
  once per submission that matched nothing, which is what a single wrong-code effect should hang on.

### Hardware modules

A hardware module owns the platform component (`esp32:`) and the board's own I/O. Board and variant
are **concrete** — never a `${...}` board/variant substitution. The build **framework** is the one
esp32 field that varies per device, so it is the `framework_variant` substitution consumed inside the
board file's own `esp32.framework.type` (default `esp-idf`, declared in `core.yaml`). A device imports
exactly one hardware module. The ESP32-only scope excludes the `mr60bha2dev`, `r`, `esp12` and
`nodemcu32` boards.

| Module | board | variant | framework | board revision |
|---|---|---|---|---|
| `hds_v1_0.yaml` | `pico32` | `esp32` | `${framework_variant}` (default esp-idf) | v1.0 |
| `hds_v1_1.yaml` | `esp32dev` | `esp32` | `${framework_variant}` (default esp-idf) | v1.1 |

- `hds_v1_0.yaml` — CAN termination resistor on GPIO12.
- `hds_v1_1.yaml` — the CAN termination resistor on GPIO12, and the on-board SW1 button on GPIO1
  gated by the compile-time `hds_v1_1_sw1_enabled` flag (default `true`; see "SW1 / GPIO1" below).

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

#### Framework selection — `framework_variant`

Board and variant are concrete, but the build **framework** is a per-device choice, so it is a single
`framework_variant` substitution consumed inside the board file's own `esp32.framework.type` rather
than a doubled `_idf` board file. `core.yaml` declares the DEFAULT (`framework_variant: esp-idf`); a
device overrides it per device with `framework_variant: arduino`. One board file therefore serves both
frameworks, and the board/variant/framework stay a single logical block in one place. The valid tokens
are `esp-idf` and `arduino`; substitution is textual and runs before schema validation, so the
resolved literal is what the esp32 schema checks — the same mechanism `can_resistor_status` already
uses.

**The default is `esp-idf`.** Earlier revisions of these board files defaulted to arduino; a device
that relied on that must now set `framework_variant: arduino` explicitly. The framework choice has one
behavioural consequence in the shared modules: `ota.yaml`'s post-boot **rollback watchdog and
`criotive_mqtt.yaml`'s MQTT confirmation are both compiled inside `#ifdef USE_ESP_IDF`**. So on an
**arduino** build they are compiled out entirely and the build carries no post-OTA rollback
protection; on an **esp-idf** build they are active and guard a freshly-flashed image (see the OTA
rollback section). Because the default is esp-idf, a default build ships that protection; a device
that opts into arduino gives it up.

The rollback SUPPORT flag itself — `esp32: framework: advanced: enable_ota_rollback` — is NOT
esp-idf-only, however. ESPHome 2026.5.1 emits its `USE_OTA_ROLLBACK` define and
`CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE` sdkconfig option for **both** frameworks (the
`enable_ota_rollback` branch in `components/esp32/__init__.py`'s `to_code` runs unconditionally, not
under the esp-idf-only branch). `USE_OTA_ROLLBACK` makes `esp32/hal.cpp` defer boot-time image
confirmation to `safe_mode` and arms bootloader rollback. If it were left on for arduino — where the
watchdog and the broker's confirmation are compiled out — a healthy freshly-flashed image that
power-cycled within `boot_is_good_after` would be rolled back by the bootloader with nothing able to
confirm it early. So the board files drive `enable_ota_rollback` from the **`ota_rollback`
substitution** (default `true`), and an **arduino device must pair `framework_variant: arduino` with
`ota_rollback: false`** — leaving `USE_OTA_ROLLBACK` undefined so `hal.cpp` confirms at boot and no
rollback machinery is compiled at all. Rollback protection therefore lives only on esp-idf, as stated.
The `framework_variant: arduino` validate fixture exercises exactly that pairing, and the default
(esp-idf) fixtures cover the rollback path; release CI compiles each for real.

#### SW1 / GPIO1 — gated by a compile-time flag

The v1.1 board has an on-board push button, **SW1**, on **GPIO1** — which is the ESP32's **U0TXD**
(primary UART TX). Configuring SW1 as a GPIO input takes GPIO1 away from the UART, so **the serial
console goes silent** on that board. Raising `logger_baud_rate` does **not** change that — SW1 owns
GPIO1 for as long as its `binary_sensor` exists, so the baud rate is not the opt-out. Because the
trade-off must be a deliberate choice, SW1 is wired in the board file behind a single flag,
**`hds_v1_1_sw1_enabled`** (default `true`), so the board stays **one YAML file** — the product
requirement is exactly one file per hardware.

The flag works through ESPHome's `!remove`: SW1 is declared with a stable `id: sw1_button`, and a
second `binary_sensor` item carries
`id: !remove '${"sw1_button" if hds_v1_1_sw1_enabled | string | lower in ["false", "0", ""] else false}'`.
The substitution pass expands substitutions inside a `!remove` value and evaluates the expression, so
a falsy flag makes the target resolve to `sw1_button` and SW1 (with its `on_click`) is dropped;
anything else resolves to the string `false`, which matches no id and is a no-op, so SW1 stays.

The comparison is against the **falsy spellings** rather than a truthiness test, because a
consumer's substitutions are frequently strings and a non-empty string is truthy. ESPHome's own
`-s key value` always yields a string, so a truthiness test made the flag impossible to set from the
command line — `-s hds_v1_1_sw1_enabled false` left SW1 enabled with no error. A YAML boolean
`false`, the string `"false"` (any case), `"0"` and `""` all disable SW1 now. It is a flag rather than a commented-out block because the SDK is consumed as a **remote git
package** — a device cannot edit or comment `hds_v1_1.yaml` at all, but it can set a substitution in
its own config.

Pick **one** in the device's own config:

| Goal | `hds_v1_1_sw1_enabled` | `logger_baud_rate` | `controls.yaml` |
|---|---|---|---|
| **normal device** | `true` (default) | `0` (default — console off) | required |
| **reading serial logs** | `false` (or `"false"` / `"0"` / `""`) | a real rate, e.g. `115200` | not needed |

- In the **normal** row SW1 works and the console is off, because GPIO1 (U0TXD) is taken by the
  button. `controls.yaml` is required because SW1's `on_click` presses `button_restart` on a short
  click and `button_factory` on longer holds, both owned by `controls.yaml` by id.
- In the **reading serial logs** row SW1 is removed, GPIO1 stays on the UART and the console prints.
  A device sets `hds_v1_1_sw1_enabled: false` **plus** a real `logger_baud_rate`.

Both rows are covered by validate fixtures: `hds_v1_1_sw1.yaml` (enabled, the default) and
`hds_v1_1_sw1_disabled.yaml` (disabled, console on, and no `controls.yaml`).

One footgun to know:

- **A mistyped flag name (or id) is a silent no-op** — the `!remove` matches nothing and SW1 stays
  enabled, with no error. Check the generated config if you expected the console back and it is still
  silent.

It is a **compile-time** choice: switching sides changes which firmware is built, so it needs a
**rebuild**, not live pin multiplexing. Do **not** work around the conflict by relocating SW1 to a
spare pin — a floating input can spuriously fire, and SW1's handlers press restart / factory-reset.
See the "serial console" note under
[Logging](#logging-is-off-in-production-by-default).

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
