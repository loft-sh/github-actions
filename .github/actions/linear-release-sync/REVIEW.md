# Code Review: linear-release-sync

## Blocking

- [x] **#1 Supply-chain risk: no checksum verification for downloaded binary** (`action.yml:58-62`)
  The binary download URL is hardcoded. If someone compromises the release asset, every consumer gets the malicious binary. Consider adding a `.sha256` checksum verification step.

- [x] **#4 `os.Kill` cannot be caught** (`main.go:88`)
  `signal.Notify` for `SIGKILL` is a no-op on Linux. Replace with `syscall.SIGTERM`:
  ```go
  ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
  ```

- [x] **#7 Nil-error wrapping in mutations** (`linear.go:316, 337`)
  `updateIssueState` and `createComment` return `fmt.Errorf("mutation failed: %w", err)` when either `err != nil` OR `!Success`. If `err == nil` and `Success == false`, the message is `"mutation failed: <nil>"`. Split into two checks:
  ```go
  if err != nil {
      return fmt.Errorf("mutation failed: %w", err)
  }
  if !mutation.IssueUpdate.Success {
      return fmt.Errorf("mutation failed: issue update returned success=false")
  }
  ```

## Warn

- [x] **#2 Token in env var** (`action.yml:53`)
  Already follows convention: "Secrets via `env:` preferred over `with:`" (CONVENTIONS.md). GHA auto-masks secrets in logs. No change needed.

- [x] **#3 Linear auth header scheme** (`linear.go:41`)
  Linear API docs recommend bare `Authorization: <token>` (no `Bearer` prefix). Current code is correct.

- [x] **#5 Logger via context.WithValue is fragile** (`main.go:91-92, linear.go:249`)
  Moved logger to a field on `LinearClient`. Removed `LoggerKey` and context injection.

- [x] **#6 Unused `PageSize` constant** (`pr.go:14`)
  `PageSize = 100` is defined in `pr.go` but unused there (also defined in `changelog/pull-requests/pr.go`).

- [x] **#9 No tests for changelog packages** (`changelog/pull-requests/`, `changelog/releases/`)
  Added tests using httptest mock GraphQL server. Covers pagination, deduplication, unmerged PR filtering, time-based filtering, semver range matching, and edge cases.

## Nit

- [x] **#10 Misleading test file name** (`integration_test.go`)
  Renamed to `flow_test.go`.

- [x] **#12 Inconsistent Go cache setting** (`release-linear-release-sync.yaml:28` vs `test-linear-release-sync.yaml:24`)
  Removed `cache: false` from release workflow — no reason to disable it.

- [x] **#13 Old Go version** (`go.mod`)
  Bumped from 1.22.5 to 1.26.
