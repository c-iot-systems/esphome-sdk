# Changelog

## 0.1.0 (2026-08-14)


### ⚠ BREAKING CHANGES

* **hardware:** hardware/hds_v2_0.yaml and its 104 slot substitutions are gone. Nothing ever depended on them: no version of this SDK has been released, and the board was only ever a concept.

### Features

* **ci:** add check-offline-survival gate for reboot_timeout defaults (AIOT-98) ([bb00dcf](https://github.com/c-iot-systems/esphome-sdk/commit/bb00dcf4549c0fd2158a7a283c2f1df7d7c7be4b))
* **ci:** compile validate fixtures on main, while a release is still only a proposal (AIOT-111) ([7276fd4](https://github.com/c-iot-systems/esphome-sdk/commit/7276fd4ce8e2c287ca5cb97d60f346d900bf7dd4))
* **ci:** compute versions with release-please and a pre-1.0 re-pin mapping (AIOT-111) ([30d4b0a](https://github.com/c-iot-systems/esphome-sdk/commit/30d4b0aceb3386003dfc26bbadf3ad70a324172a))
* **ci:** gate breaking substitution-contract changes on a breaking commit marker (AIOT-111) ([769a2a2](https://github.com/c-iot-systems/esphome-sdk/commit/769a2a2991d02f1ee45eed4600a33f91aedc1b78))
* **hardware:** add esp-idf board variants and opt-in SW1 unit off GPIO1 (AIOT-101) ([94d061f](https://github.com/c-iot-systems/esphome-sdk/commit/94d061fc1f6c6fa5a725b8840bce8a224ccb2dfe))
* **hardware:** add static slot pin tables for hds_v1_0/v1_1/v2_0 with slot-name fixtures (AIOT-102) ([897a023](https://github.com/c-iot-systems/esphome-sdk/commit/897a02303da4ee36689aca46b6ff148793f9d0c8))
* **mqtt:** add settable mqtt_client_id defaulting to device_name (AIOT-100) ([0d297ce](https://github.com/c-iot-systems/esphome-sdk/commit/0d297ce0260d58258b7445cac3c10c4fc62e7339))
* **sdk:** core.yaml, wifi.yaml, substitution contract and negative harness (AIOT-87) ([126b463](https://github.com/c-iot-systems/esphome-sdk/commit/126b46390eefc56702e40e33a10982d2c73c1712))
* **wifi:** three optional station slots and a provisioning-only mode (AIOT-107) ([ceb5427](https://github.com/c-iot-systems/esphome-sdk/commit/ceb542735d9bf573dc791810088b50e0867f2f52))


### Bug Fixes

* **ci:** close review gaps — fixture-only guard, flow/anchor detection, sdk_ref presence (AIOT-86) ([70b248f](https://github.com/c-iot-systems/esphome-sdk/commit/70b248f094a183af864ef5f5b21c57e309049a4e))
* **ci:** compile every fixture before failing, so one run reports every break (AIOT-112) ([6ce07ce](https://github.com/c-iot-systems/esphome-sdk/commit/6ce07ce0a5083f6ef926ad8468ad2bce59fbc36e))
* **ci:** detect list-item/quoted/spaced on_* keys and shorthand/vacuous SDK refs (AIOT-86) ([e920a03](https://github.com/c-iot-systems/esphome-sdk/commit/e920a03931f4963b85e73b30007caaf55cf9f378))
* **ci:** gate the release on the contract since the last tag, not only on the PR pass (AIOT-111) ([79664e0](https://github.com/c-iot-systems/esphome-sdk/commit/79664e0047ae75acc3586a67da0f450b93ebbf40))
* **ci:** ignore commented-out reboot_timeout in presence check (AIOT-98) ([36ffd81](https://github.com/c-iot-systems/esphome-sdk/commit/36ffd811026c34c67ba6c14cde7d79cbfe45288d))
* **ci:** make the release job need the compile so a tag cannot outrun it (AIOT-111) ([f288b0b](https://github.com/c-iot-systems/esphome-sdk/commit/f288b0b4a90978f4a595d6e2c3cfa5d7cd14579c))
* **ci:** per-component quote-aware reboot_timeout presence check (AIOT-98) ([a7e4cad](https://github.com/c-iot-systems/esphome-sdk/commit/a7e4cad98ff45e6d7165f0301bd91ec478c267b9))
* **ci:** publish only from the run that verified the release commit, and run the negative harness pre-release (AIOT-111) ([01575c6](https://github.com/c-iot-systems/esphome-sdk/commit/01575c6e2921b51585b00ab60b596c18f47c5826))
* **ci:** reject fractional non-zero timeouts and missing reboot_timeout keys (AIOT-98) ([a86215d](https://github.com/c-iot-systems/esphome-sdk/commit/a86215d6c9ea4d263be5e6701e67b6d8d395f31b))
* **ci:** report a deleted module as one path finding, not one per substitution (AIOT-113) ([ef0da48](https://github.com/c-iot-systems/esphome-sdk/commit/ef0da48183ea9fc1deb68d5eedbba77a4da14f31))
* **ci:** require reboot_timeout as a direct component child (block-scalar safe) (AIOT-98) ([201bdff](https://github.com/c-iot-systems/esphome-sdk/commit/201bdff15e6bee28d05d3101f4b1856fdeb6ea62))
* **ci:** scope the contract per module and fail closed on malformed guards and unresolvable refs (AIOT-111) ([1b9d6c4](https://github.com/c-iot-systems/esphome-sdk/commit/1b9d6c4be870380f0131f75f9517ea13ec7898d5))
* **ci:** treat module paths as contract and guard the release with every invariant gate (AIOT-111) ([4bf4e8a](https://github.com/c-iot-systems/esphome-sdk/commit/4bf4e8ab00f7cda1a2bd60fc310488d70c369aa5))
* **core:** default logger_level to NONE for production parity (AIOT-96) ([d74e994](https://github.com/c-iot-systems/esphome-sdk/commit/d74e9941f2725b63fb41309ba135f76f2a13723b))
* **core:** do not reintroduce infinite_* substitutions per master correction (AIOT-98) ([ba4e87c](https://github.com/c-iot-systems/esphome-sdk/commit/ba4e87c8ac8e4bfb94ac953928e3e707613caad2))
* **diagnostics:** poll on a real interval, not `never` ([f18f030](https://github.com/c-iot-systems/esphome-sdk/commit/f18f030dd00fec06f35aab9fc0cb715fcf650238))
* **google_location:** AUTO_LOAD json so the geolocation request body compiles (AIOT-112) ([08ab1eb](https://github.com/c-iot-systems/esphome-sdk/commit/08ab1ebf3a36d6d8a12c419ff8297784eccfa51e))
* **hardware:** make the SW1 flag settable from a string and stop diagnostics polling at 1 kHz ([bfc0d25](https://github.com/c-iot-systems/esphome-sdk/commit/bfc0d259058f618cefc2111dd049b5c29597a743))
* **hardware:** remove hds_v2_0 — the v2.0 board never existed (AIOT-113) ([2695623](https://github.com/c-iot-systems/esphome-sdk/commit/26956235e77d0835b5b6fa97d743d2e10d7d205a))
* **hardware:** restore hds_v1_1_sw1 opt-in; composition, not baud rate, gates SW1 (AIOT-101) ([c5e1119](https://github.com/c-iot-systems/esphome-sdk/commit/c5e11190459579607b3473520ccb1fa5aac4a65a))
* **logger:** gate serial console on logger_baud_rate so SW1 rejoins hds_v1_1 (AIOT-101) ([9db0858](https://github.com/c-iot-systems/esphome-sdk/commit/9db08582d9b12232b52f8ec9062d7f7e5128b860))
* **mqtt:** make mqtt_port a required substitution with no default (AIOT-87) ([6002378](https://github.com/c-iot-systems/esphome-sdk/commit/60023788617b938771e7c0c15a437ecb0c64260e))
* **ota:** defer safe_mode confirmation past the rollback watchdog so bad OTAs still roll back (AIOT-101) ([822696e](https://github.com/c-iot-systems/esphome-sdk/commit/822696ea3d1566f0803e68f6c3815b31785f5bb8))
* **ota:** gate enable_ota_rollback on ${ota_rollback} so rollback support is esp-idf-only (AIOT-98) ([ff062fc](https://github.com/c-iot-systems/esphome-sdk/commit/ff062fcc85aa9cb1113cf39eb568f64aa1b22eeb))
* **ota:** pin enable_ota_rollback and collapse _idf boards into ${framework_variant} (default esp-idf) (AIOT-98) ([a3d1755](https://github.com/c-iot-systems/esphome-sdk/commit/a3d17557a1a21eaffc1d899a3091337b42cedac8))
* **repo:** restore SDK-3 through SDK-6 changes (RECOVERY) ([9d72e00](https://github.com/c-iot-systems/esphome-sdk/commit/9d72e00523d59886c007c3e6e316d852e45311fb))
* **sdk:** enforce sdk_ref, schema-safe AP SSID, escaped AP password (AIOT-87) ([e6a0c5c](https://github.com/c-iot-systems/esphome-sdk/commit/e6a0c5c87fedd2efcee460d0baee6fa1afe48092))
* **wifi,core:** default reboot timeouts to 0s and restore infinite_* substitutions (AIOT-98) ([18b8a0c](https://github.com/c-iot-systems/esphome-sdk/commit/18b8a0c7dd7215723534780bc0f53030f6cd999b))


### Performance

* **ci:** compile each validate fixture in its own job, ~52 min serial to ~5 min (AIOT-114) ([ad07d59](https://github.com/c-iot-systems/esphome-sdk/commit/ad07d5925bbb798f4d4bb3890fb80507e9b7063e))


### Refactors

* **ci:** factor SDK-ref materialization into a self-testing gate script (AIOT-111) ([e0e2f16](https://github.com/c-iot-systems/esphome-sdk/commit/e0e2f16686cfefc831d31db62e0bc94937972581))
* **hardware:** gate hds_v1_1 SW1 behind a compile-time flag, one file per board (AIOT-101) ([14e6187](https://github.com/c-iot-systems/esphome-sdk/commit/14e618754329ea492b9caa6e7607c8edb276bf19))


### Documentation

* **hardware:** state SW1/serial-console exclusivity on hds_v1_0 as a hardware constraint (AIOT-101) ([ceba105](https://github.com/c-iot-systems/esphome-sdk/commit/ceba105c9ad56a24d5317ace5ba5c28f3a1faa4f))
* **sdk:** adopt strict Conventional Commits with the Jira key in the subject tail (AIOT-111) ([0094a57](https://github.com/c-iot-systems/esphome-sdk/commit/0094a57cf404de662f0cbd2fce0af8a026b1804a))
* **sdk:** document the release process, the bump mapping and the gate index (AIOT-111) ([7dd8fdb](https://github.com/c-iot-systems/esphome-sdk/commit/7dd8fdb16604975fd457777b704c7d7d702640a0))
* **sdk:** scrub internal references from the public repo and document slot/esp-idf/SW1 (AIOT-103) ([48bcef3](https://github.com/c-iot-systems/esphome-sdk/commit/48bcef3db7bcc6fb3ab64ba93b3a1b46f1152b11))
* **sdk:** scrub residual predecessor narration and CA-injection disclosure (AIOT-103) ([47cb8a1](https://github.com/c-iot-systems/esphome-sdk/commit/47cb8a1c6d5d5f128232dfb419f086aac79a0209))
* **sdk:** trim oversized YAML comments ([7ee7be8](https://github.com/c-iot-systems/esphome-sdk/commit/7ee7be8236506a31fb4c241a58e35d6e12532238))
* **tests:** restore fixture intent comments and pin-validation rationale ([0568aeb](https://github.com/c-iot-systems/esphome-sdk/commit/0568aeba4d690c647c34758fa4e4a791e9289a9a))


### Chores

* **release:** publish the first tag as v0.1.0 (AIOT-111) ([45e0160](https://github.com/c-iot-systems/esphome-sdk/commit/45e0160afa1b8ccafeda04fad34206f78463542e))
