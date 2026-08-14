<!--
This repository is PUBLIC and everything it publishes is permanent. Write for someone outside the
company reading this in a year: no internal issue keys, no tracker links, no internal service names.
Traceability runs the other way — link the PR from the ticket, not the ticket from the PR.

The title must be a Conventional Commits subject, because release-please parses it:
    feat(mqtt): add a thing          fix(ota): stop doing a thing
    feat(mqtt)!: a breaking change   docs(readme): explain a thing
CI (public-naming) enforces both rules on the title, body, branch name and commit subjects.
-->

## What changes

<!-- One paragraph: what this does, for a reader who has not seen the code. -->

## Why

<!-- The problem this solves. What was wrong, or impossible, before. -->

## Substitution contract

<!--
Delete if unchanged. Otherwise: which substitutions were added, removed or changed, and whether the
change is BREAKING (a consumer must edit its config to re-pin). Pre-1.0, breaking = minor bump.
Breaking changes need a `!` in the commit subject or a BREAKING CHANGE: footer, and a migration
snippet here.
-->

## Verification

<!--
What you ran and what it said — not "tests pass". Gate output, `esphome config` results, hardware
tried. State anything you could NOT verify and why.
-->

## Notes for the reviewer

<!-- Delete if none. Risks, deliberate omissions, follow-ups you chose not to bundle. -->
