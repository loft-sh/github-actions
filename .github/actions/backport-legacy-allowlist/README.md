# backport-legacy-allowlist

Gate `backport-to-*` labels down to the **in-support, pre-monorepo (`<= v0.36`)**
release lines, and emit them as a JSON array for a matrix.

This is the allow-list guard for the legacy backport flow. It lives at the
shared-CI layer (invoked from the reusable `backport.yaml`) so the same gate
protects both the monorepo's split flow and the OSS side's external-contributor
PR flow. It pairs with [`backport-legacy-split`](../backport-legacy-split), which
does the per-target re-root: this action decides *which* targets are eligible;
that action decides *how* each one is applied.

## What it allows

A `backport-to-v0.<minor>` label qualifies when `<minor> <= max-minor`
(default `36`; `>= v0.37` is the monorepo era, handled by the plain cherry-pick
path) **and** the line passes its own lifecycle check:

- **listed** in the lifecycle doc → allowed iff `status != "eol"` **and** its
  `eolDate` is in the future;
- **not listed**, and above the highest listed `0.x` minor → allowed as a
  **freshly cut line** not yet in the doc (e.g. `v0.36`);
- otherwise → dropped with a warning (end-of-life, or an unknown/gap line — the
  gate **fails closed**).

Each line is judged on its own `eolDate` rather than a `[min, max]` range, so a
**non-contiguous** lifecycle (an EOL line sitting between two supported ones)
can't let the EOL line slip through — a safety gate must fail closed in the
direction it exists to block.

Labels that are not `backport-to-v0.x` (other labels, or `v1+` monorepo-era
lines) are ignored.

## Lifecycle source & fallback

Support is read from `lifecycle-url` (default
`https://www.vcluster.com/docs/api/lifecycle/vcluster.json`, shape
`{versions:[{version,status,eolDate}]}`) so the gate self-prunes as lines reach
EOL. On any fetch/parse failure the action falls back to a **contiguous**
`[fallback-min-minor, max-minor]` window (default lower bound `31`) — the best
it can do without the doc — and logs a warning, so a doc outage never silently
widens or empties the allow-list.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |                            DEFAULT                            |                                                                                                              DESCRIPTION                                                                                                              |
|--------------------|--------|----------|---------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| fallback-min-minor | string |  false   |                            `"31"`                             |                                            Lowest in-support 0.x minor to assume <br>when the lifecycle doc cannot be <br>read. Points at v0.31 per the <br>lifecycle doc as of 2026-07.                                              |
|    label-prefix    | string |  false   |                       `"backport-to-"`                        |                                                                                                  Prefix that marks a backport label.                                                                                                  |
|       labels       | string |   true   |                                                               |                              JSON array of label names on <br>the source PR, e.g. toJSON(github.event.pull_request.labels.*.name). Only <br>labels matching '<label-prefix>v0.<minor>' are considered.                                |
|   lifecycle-url    | string |  false   | `"https://www.vcluster.com/docs/api/lifecycle/vcluster.json"` |                                            vCluster lifecycle JSON used to prune <br>end-of-life lines. On fetch/parse failure the <br>action falls back to a hardcoded <br>lower bound.                                              |
|     max-minor      | string |  false   |                            `"36"`                             | Highest 0.x minor that is still <br>pre-monorepo (old layout). Lines above this are <br>the monorepo era and are handled <br>by the cherry-pick path, not here. <br>The era boundary is v0.37, so <br>the last legacy line is v0.36.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT    |  TYPE  |                                                  DESCRIPTION                                                  |
|-------------|--------|---------------------------------------------------------------------------------------------------------------|
| has-targets | string |                     "true" when at least one legacy <br>target qualified, else "false".                       |
|   targets   | string | JSON array of allowed legacy target <br>branches, e.g. ["v0.35","v0.34"]. Empty array when <br>none qualify.  |

<!-- AUTO-DOC-OUTPUT:END -->

Feed `targets` into a matrix (`fromJSON`) and gate the job on `has-targets`.

## Tests

`bats` against a local `file://` lifecycle fixture with a pinned `TODAY`, so the
EOL math is hermetic and deterministic:

```bash
bats .github/actions/backport-legacy-allowlist/test
```
