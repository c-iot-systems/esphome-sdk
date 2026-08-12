# Validate fixtures

Minimal ESPHome configs that exercise the SDK modules through the same `packages:` mechanism a real
device uses. CI runs them two ways:

- **On pull request** (`validate.yml`) — `esphome config` over every `*.yaml` here. Seconds, no
  toolchain. Catches what a package system actually breaks: duplicate ids when two modules define
  the same one, a module referencing a substitution nobody supplies, broken `github://` imports,
  post-merge schema violations.
- **On release tag** (`release.yml`) — a real `esphome compile` over every `*.yaml` here.
  `esphome config` validates a component's Python and schema but never compiles its C++, so a
  component that does not build only surfaces here.

Each task in the SDK plan owns its own fixture file(s); no task edits another task's fixture.

## The placeholder ref — `__SDK_REF__`

A fixture must **not** pin a published tag. A fixture pinning `@v0.1.0` would make PR CI fetch the
last release instead of the branch under review, and before the first tag exists nothing would
resolve at all. Instead, every fixture carries the literal placeholder **`__SDK_REF__`** in both the
package `ref` and every `vars.sdk_ref`, and CI materializes it:

- pull_request → the PR **head SHA**
- tag → **`GITHUB_REF_NAME`**

so the fixtures always resolve the exact revision under test. `check-sdk-ref.sh` asserts the two
values are equal (the placeholder equals itself before materialization, the same SHA/tag after), and
CI fails if any fixture resolves a revision other than the intended one.

A fixture therefore looks like:

```yaml
substitutions:
  device_name: test-device
  firmware_version: "0.0.0-test"
  # ...the other substitutions the imported modules require, with test values...

packages:
  criotive:
    url: https://github.com/c-iot-systems/esphome-sdk
    ref: __SDK_REF__
    files:
      - path: modules/core.yaml
        vars: {sdk_ref: __SDK_REF__}
      # ...one entry per module the fixture imports...
```

Fixtures are self-contained: they supply literal test values for every required substitution, so no
`secrets.yaml` is needed. No fixture value is a real credential — this repository is public.
