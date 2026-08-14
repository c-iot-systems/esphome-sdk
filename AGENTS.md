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
2. `release-gate.yml` runs on that push: job `compile` builds every validate fixture and job
   `gates` re-runs every invariant script, including the contract gate against the last published
   tag. Only then does release-please refresh the release PR holding the computed version and
   CHANGELOG entry.
3. You read that PR — the version and the changelog are the reviewable artifact — and merge it.
4. That merge is another push to `main`, so `release-gate.yml` runs again on the exact commit about
   to be tagged. The `release` job needs both `compile` and `gates`, so **if that tree does not
   build, or violates an invariant, or its contract change is not labelled honestly, no tag is ever
   created.** When both pass, release-please creates the tag and the GitHub Release — but only if
   this run's commit is still `main`'s head, since release-please acts on the branch as it is now,
   not on the SHA the run verified.

## Merge strategy: never squash

**Squash merging is disabled on this repo, and must stay disabled.** A squash collapses a PR into
one commit whose subject is the PR title and whose body holds the original subjects. A
`feat(wifi)!:` marker written on an inner commit therefore becomes ordinary body text, and
release-please — which parses the subject that lands on `main` — would compute a patch bump for a
breaking change. The PR-time contract gate would have seen the marker and passed, so the two would
silently disagree.

Merge commits and rebase both preserve subjects verbatim; use those. The `contract` job in
`release-gate.yml` is the backstop that catches it anyway, but it catches it at release time, which
is later and more annoying than not creating the problem.

To force a specific version (the first release, or a deliberate jump), put a `Release-As: 0.1.0`
footer on a commit that lands in the release.

### Why the contract gate runs twice

On a pull request it compares the **merge base** with the PR head — early, where the author can
still fix the label. On `main` it compares the **last published tag** with `HEAD`, reading the
commits release-please will actually parse. The published tag is resolved from the tags that exist,
never from the manifest: on the release PR's own merge the manifest already names the version being
released, whose tag does not exist yet, and trusting it would skip the gate on exactly that commit. Neither subsumes the other: the PR pass never sees a
direct push to `main`, and it inspects commits that a squash merge could rewrite.

### Why compile and release live in one workflow

Because ordering is the only thing that makes the compile a *gate* rather than a report. A tag is
permanent, public and pinned by devices in the field, so the compile has to run while the version
is still a proposal. Split across two workflows, release-please would create the tag on the release
PR's merge whether or not the compile of that same commit had passed — or even finished. Joined by
`needs: compile`, the release job is unreachable without a green build of the tree being tagged.

This is also why `release-gate.yml` has no `paths:` filter: a release PR edits only `CHANGELOG.md`
and `version.txt`, so a filter would skip the compile on precisely the push that publishes the tag.

The release PR itself shows no checks, because release-please opens it with `GITHUB_TOKEN` and
`GITHUB_TOKEN` events do not start workflow runs. That costs nothing here — the commit that matters
is the merge commit, and that one is gated. The same rule means an automated tag does not trigger
`release.yml`; run it on demand with `workflow_dispatch` (input: the tag) for a tag-time
re-verification.

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
required substitution cannot arrive without the fixture that proves it, and it treats every module
and board **path** as contract — a consumer imports `modules/controls.yaml` by URL, so deleting or
renaming it is breaking even though that file declares no substitutions at all.

Scopes mirror how a config is assembled. `modules/core.yaml` is the base, and every other module
and board is a scope layered on it (`core ∪ <file>`). Modules are opt-in and composed selectively —
`tests/validate/phone.yaml` imports no core at all — so treating `modules/` as one namespace would
let a default in one module mask a required reference in an unrelated one. Boards need the same
layering in the other direction: `framework_variant` is referenced by every board but defaulted in
core, and is correctly not required.

## Workflows

| workflow | trigger | does |
|---|---|---|
| `validate.yml` | pull request | all gates + `esphome config` over `tests/validate/` |
| `release-gate.yml` | push to `main` | jobs `compile` (real `esphome compile`) and `gates` (every invariant script + contract gate vs the last published tag), then job `release` (release-please) which **needs** both |
| `release.yml` | tag push / manual | belt-and-braces compile against an already-published tag |

## House style

- Keep gate scripts self-testing, and explain the invariant in the file header — why it exists and
  what breaks without it, not just what the code does.
- Never hard-code a ref in `modules/` or `hardware/`; thread `${sdk_ref}`.
- No secrets, ever. Every credential arrives as a substitution. A value committed here is public
  and permanent.
