# esphome-sdk — agent and contributor instructions

This repo is public, and every tag it publishes is permanent. A device config pins an exact SDK
tag, so a released version is not a package that can be yanked and re-cut — it is a revision that
firmware in the field will keep fetching. Everything below follows from that.

## Commit convention

**Strict [Conventional Commits](https://www.conventionalcommits.org/), with the Jira key at the
END of the subject:**

```
feat(wifi): three optional station slots and a provisioning-only mode (AIOT-107)
fix(ota): gate enable_ota_rollback on ${ota_rollback} (AIOT-98)
feat(mqtt)!: make mqtt_port a required substitution with no default (AIOT-87)
```

This DIVERGES from the `site` repo's `AGENTS.md` §15, which puts the key first as
`[AIOT-107] feat(wifi): …`. Do not carry that form here. release-please parses commits with a
spec-strict parser: a leading `[AIOT-107] ` makes the whole subject unparseable, the commit is
ignored for versioning, and a release silently omits the change. The key still appears in every
subject, so branch ↔ ticket ↔ commit traceability is unchanged.

- Branches keep the `site` convention: `feat/AIOT-111`, `fix/AIOT-100`, `chore/AIOT-111`.
- A breaking change is marked `type(scope)!:`, a `BREAKING CHANGE:` footer, or both. Bodies and
  footers are allowed here (the `site` single-line rule does not apply).
- `feat` / `fix` / `perf` / `refactor` / `docs` appear in the changelog; `test` / `build` / `ci` /
  `chore` / `style` are parsed but hidden.

## Versioning

Pre-1.0, configured so the number answers the only question a consumer re-pinning a ref has:

| bump  | means                                                              |
|-------|--------------------------------------------------------------------|
| minor | **migration required** — a breaking change to the substitution contract |
| patch | **safe to re-pin** — features and fixes                            |

(`bump-minor-pre-major` maps breaking → minor and `bump-patch-for-minor-pre-major` maps feat →
patch, both in `release-please-config.json`.)

## How a release happens

1. You merge ordinary PRs into `main` with conventional subjects.
2. `release-please.yml` keeps a release PR open, holding the computed version and the CHANGELOG
   entry. It is refreshed on every push to `main`.
3. You read that PR — the version and the changelog are the reviewable artifact — and merge it.
4. release-please creates the tag and the GitHub Release.

To force a specific version (the first release, or a deliberate jump), put a `Release-As: 0.1.0`
footer on a commit that lands in the release.

### Why the release PR has no CI

release-please opens it with `GITHUB_TOKEN`, and events raised by `GITHUB_TOKEN` do not start
workflow runs. Nothing is lost: a release PR only edits `CHANGELOG.md` and `version.txt`, so the
YAML it proposes to tag is exactly the `main` that `release-gate.yml` already compiled. The
verification lives one step earlier, on `main`, which is also the last point where a failure can
still prevent a permanent tag.

The same rule means an automated tag does not trigger `release.yml`. Run it on demand with
`workflow_dispatch` (input: the tag) when a tag-time re-verification is wanted.

## Gates

Every gate is a script under `scripts/`, each with a `--self-test` that proves its own FAIL paths.
CI runs `--self-test` before the real check, so a gate that has been silently defanged fails loudly.

| script | invariant |
|---|---|
| `check-automation-syntax.sh` | `on_*` automations use list syntax, so package merging cannot collapse them |
| `check-sdk-ref.sh` | `vars.sdk_ref` equals the package `ref`; no module hard-codes a ref |
| `check-offline-survival.sh` | `reboot_timeout` defaults are `0s` — a device never reboots through an outage |
| `check-rollback-timing.sh` | `safe_mode` confirms after the OTA rollback watchdog |
| `check-negative.sh` | every required substitution actually fails validation when omitted |
| `check-contract-diff.sh` | a breaking substitution-contract change must be committed as breaking |
| `materialize-sdk-ref.sh` | `__SDK_REF__` resolves totally, to the revision under test |

`check-contract-diff.sh` is what makes the version number mean something. It derives the
substitution contract from `modules/` and `hardware/` — required (`${ x if x is defined else 1/0 }`
or a plain `${x}` with no default) versus optional (a key under `substitutions:`, with its
default) — diffs it across the PR, and fails when the change is breaking but no commit says so.
It also enforces parity between the required set and `tests/negative/omit_<name>.yaml`, so a new
required substitution cannot arrive without the fixture that proves it.

## Workflows

| workflow | trigger | does |
|---|---|---|
| `validate.yml` | pull request | all gates + `esphome config` over `tests/validate/` |
| `release-gate.yml` | push to `main` | the real `esphome compile` over `tests/validate/` |
| `release-please.yml` | push to `main` | maintains the release PR; tags and releases on merge |
| `release.yml` | tag push / manual | belt-and-braces compile against a published tag |

## House style

- Keep gate scripts self-testing, and explain the invariant in the file header — why it exists and
  what breaks without it, not just what the code does.
- Never hard-code a ref in `modules/` or `hardware/`; thread `${sdk_ref}`.
- No secrets, ever. Every credential arrives as a substitution. A value committed here is public
  and permanent.
