# Release flow and MarmotKit channels

MDK publishes MarmotKit on two channels:

- **Release Candidates** (`marmotkit-vX.Y.Z-rc.N`), one a day at most, each written to
  `rc-meta:rc/latest.json` only after Canary, simulator-nightly, convergence-hardening and every
  artifact build pass. They are GitHub pre-releases and **upstream deletes them after 30 days**.
- **Stable** (`marmotkit-vX.Y.Z`), promoted by hand from one verified RC (MDK's
  `promote-release.yml`): built from a release commit whose parent is that RC's source commit and
  which changes only release metadata. Stable releases are permanent.

White Noise for macOS keeps each one on its own branch.

| Branch | Pins | Builds |
| --- | --- | --- |
| `develop` | the latest RC, bumped daily | `White Noise Dev`, `White Noise Staging` for testers |
| `master` | Stable only (CI enforces it) | production (App Store) |

## Day to day: `develop`

- Feature branches start from `develop` and merge back into it.
- The **MarmotKit RC bump** workflow (`.github/workflows/marmotkit-rc-bump.yml`) runs
  `just sync-rc` daily. When `rc/latest.json` names a new RC it opens, or refreshes, one PR into
  `develop` (`automation/marmotkit-rc`), with the impact, the breaking UniFFI changes, the storage
  migrations and a link to MDK's integration notes. A rerun with no new RC changes nothing.
- A `patch` RC with no breaking UniFFI changes should merge as is once CI is green. A `minor` RC
  may not compile: check out the bump branch, read
  [rc/integration-notes.md](https://github.com/marmot-protocol/mdk/blob/rc-meta/rc/integration-notes.md),
  fix the call sites on that branch, then merge.
- `just sync-rc` locally does the same thing by hand. It refuses to run on `master`.

## Staging builds

Cut staging builds from `develop` and tag each one you hand out, for example
`staging/1.4.0-3`. The tag records the exact RC pinned (`Vendored/MarmotKit/MARMOT_VERSION`).

A staging tag can only be rebuilt while its RC exists (30 days). Keep the built artifact; don't
plan on rebuilding an old tag.

## Shipping to production: `master`

1. Choose the staging tag to ship, and note its RC (say `0.20.0-rc.4`).
2. Ask MDK to promote **that** RC to Stable, or confirm they already have. If MDK promoted a
   different RC, the Stable binary isn't the one testers ran: pin that RC on `develop`, cut and
   test a new staging build, and start again.
3. Branch from the staging tag (`release/1.4.0`), run `just promote-stable`, and open a PR into
   `master`. `promote-stable` pins Stable `X.Y.Z`, and refuses it unless its source is the RC's
   source or the release commit on top of it. It prints how many generated Swift lines changed;
   expect version strings at most. The PR's diff over the staging tag is the pin alone.
4. CI (`MarmotKit release channel`) fails any PR into `master` that pins anything but Stable.
5. Merge, tag `v1.4.0` on `master`, and build the App Store release from that tag.
6. Merge `master` back into `develop`. The next RC bump moves `develop` back onto RCs, and is
   never older than the Stable it replaces: `sync-rc` refuses a downgrade.

A production hotfix branches from the `v` tag on `master`, keeps the Stable pin, merges into
`master`, then merges back into `develop`.

## Data

The flavors keep separate data. The development app and the staging app (`White Noise Staging`)
each have their own root and keychain service, so an RC's one-way schema migration never touches
production data. Production only ever opens a database with a Stable release.

## Repository setup

Done once, by a repository admin:

- Make `develop` the default branch. Pull requests then target it by default, and GitHub runs
  the scheduled RC bump only from the default branch's copy of the workflow.
- Protect `develop` like `master`: require pull requests and the "PR Checks" status.
- Add the `MARMOTKIT_BUMP_TOKEN` secret (a fine-grained token with contents and pull-requests
  write on this repository). A pull request opened with the default `GITHUB_TOKEN` starts no
  other workflows, so without it the bump pull request gets no CI.

CI's coverage gate compares every pull request, including those into `develop`, with `master`'s
last green run.
