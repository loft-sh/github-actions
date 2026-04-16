# Detect Changes

Detects whether specified file paths have changed in a pull request.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

| INPUT |  TYPE  | REQUIRED | DEFAULT |                               DESCRIPTION                                |
|-------|--------|----------|---------|--------------------------------------------------------------------------|
| paths | string |   true   |         | Glob pattern(s) to check for changes <br>(comma-separated or YAML list)  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT    |                    VALUE                    |                     DESCRIPTION                      |
|-------------|---------------------------------------------|------------------------------------------------------|
| has_changed | `"${{ jobs.changes.outputs.has_changed }}"` | Whether the specified directories/files have changed |

<!-- AUTO-DOC-OUTPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->
No secrets.
<!-- AUTO-DOC-SECRETS:END -->
