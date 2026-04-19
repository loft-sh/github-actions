---
name: review-e2e-test
description: Review e2e test code changed locally or in a PR against the team's quality
  checklist. Outputs a structured violation report. When run in CI via GitHub Actions,
  the workflow posts the violations as inline PR comments and requests changes if any
  blocking violations are found.
---

# E2E Test Quality Review

## Overview

You are reviewing e2e test code against the loft-sh e2e quality checklist.
Your job is to find violations in **added or changed lines only** and output a
structured violation report.

Do not flag pre-existing code that was not changed.
Do not post praise or style commentary — only actionable violations.

## Step 1 — Identify changed e2e test files

```bash
git diff $(git merge-base HEAD main)..HEAD --name-only
```

From the list of changed files, identify e2e test files — files whose path contains `e2e-next/`.

If **no** e2e test files changed, print `E2E quality review: no e2e test files changed. Skipping.` and stop.

---

## Step 2 — Read the diff for each test file

```bash
git diff $(git merge-base HEAD main)..HEAD -- <file>
```

Collect only **added lines** (lines starting with `+`, excluding the `+++` header line).
Note the line numbers so violations can be anchored correctly.

---

## Step 3 — Check against the quality checklist

For every added or modified block of code, evaluate each checklist item below.
Items marked **BLOCKING** are hard failures. Items marked **WARN** are suggestions only.

> See also: `plugins/e2e-tdd-workflow/references/` for the full conventions and
> quality checklist that these items are derived from.

---

### C1 — DeferCleanup registered immediately after creation [BLOCKING]

`DeferCleanup` must be the very next non-blank statement after a successful `Create`
call and its error assertion. Any assertion between creation and `DeferCleanup`
registration means the resource leaks if that assertion fails.

> See also: `references/e2e-quality-checklist-core.md` item 2, `references/e2e-test-structure-core.md`

**FAIL pattern:**
```go
_, err := client.Create(ctx, obj, metav1.CreateOptions{})
Expect(err).To(Succeed())
Expect(obj.Name).To(Equal("something"))  // assertion before DeferCleanup → resource leaks
DeferCleanup(...)
```

**PASS pattern:**
```go
_, err := client.Create(ctx, obj, metav1.CreateOptions{})
Expect(err).To(Succeed())
DeferCleanup(func(ctx context.Context) { ... })  // immediately after
Expect(obj.Name).To(Equal("something"))
```

---

### C2 — Cleanup tolerates NotFound [BLOCKING]

`DeferCleanup` must wrap the delete error in `clientpkg.IgnoreNotFound` (or equivalent).
Hard-failing on delete in cleanup breaks the suite if the resource was cascade-deleted.

> See also: `references/e2e-quality-checklist-core.md` item 1, `references/e2e-error-handling.md`

**FAIL pattern:**
```go
DeferCleanup(func(ctx context.Context) {
    Expect(client.Delete(ctx, name, metav1.DeleteOptions{})).To(Succeed())
})
```

**PASS pattern:**
```go
DeferCleanup(func(ctx context.Context) {
    err := client.Delete(ctx, name, metav1.DeleteOptions{})
    Expect(clientpkg.IgnoreNotFound(err)).To(Succeed())
})
```

**Exception:** Do NOT use `IgnoreNotFound` for resources the test just created in the
same `It` block and expects to still exist at cleanup time. In that case a strict
assertion is correct — `NotFound` signals a test bug.

---

### C3 — By() uses a closure [BLOCKING]

`By()` must always be called with a `func() { }` closure argument. The bare form
without a closure prevents Ginkgo from attributing failures to the step and from
reporting step duration.

> See also: `references/e2e-quality-checklist-core.md` item 8, `references/e2e-test-structure-core.md`

**FAIL pattern:**
```go
By("creating the virtual cluster")
foo = doSomething()
```

**PASS pattern:**
```go
By("creating the virtual cluster", func() {
    foo = doSomething()
})
```

---

### C4 — Assert specific error messages, not just error presence [BLOCKING]

When a test asserts that an operation should fail (e.g., forbidden, conflict,
not found), it must assert the specific error — not just that some error occurred.
`Expect(err).To(HaveOccurred())` passes on connectivity failures and RBAC errors.

> See also: `references/e2e-error-handling.md`

**FAIL pattern:**
```go
err := client.Create(ctx, obj, metav1.CreateOptions{})
Expect(err).To(HaveOccurred())
```

**PASS pattern:**
```go
err := client.Create(ctx, obj, metav1.CreateOptions{})
Expect(err).To(MatchError(ContainSubstring("already exists")))
// or
Expect(kerrors.IsAlreadyExists(err)).To(BeTrue())
```

**Note:** `Expect(err).To(Succeed())` and `Expect(err).NotTo(HaveOccurred())` on
success paths are fine — this rule only applies when asserting that an error *should*
occur.

---

### C5 — No error swallowing [BLOCKING]

Do not use `_, _ =` to discard errors. Do not use bare `if err != nil { return }`
in cleanup without `IgnoreNotFound`. Silent failures mask regressions and leak resources.

> See also: `references/e2e-error-handling.md`

**FAIL patterns:**
```go
_, _ = client.Delete(ctx, name, metav1.DeleteOptions{})

if err != nil {
    return  // swallows connectivity failures, RBAC errors, etc.
}
```

**PASS pattern:**
```go
err := client.Delete(ctx, name, metav1.DeleteOptions{})
Expect(clientpkg.IgnoreNotFound(err)).To(Succeed())
```

---

### C6 — labels.PR not duplicated on every It [BLOCKING]

If `labels.PR` appears on the enclosing `Describe` or `Context`, do not add it again
to individual `It` blocks. Ginkgo inherits labels from parent containers — duplicates
are redundant noise and can cause unexpected label matching behaviour.

> See also: `references/e2e-conventions-core.md` item 4

**FAIL pattern:**
```go
var _ = Describe("Feature", labels.PR, func() {
    It("does A", labels.PR, func(ctx context.Context) { ... })  // duplicate
})
```

**PASS pattern:**
```go
var _ = Describe("Feature", labels.PR, func() {
    It("does A", func(ctx context.Context) { ... })  // inherits from Describe
})
```

---

### C7 — Include failure context in Eventually assertions [BLOCKING]

Assertions inside `Eventually` must include contextual information (e.g.,
`Status.Reason`, `Status.Message`) in the failure message so that timeouts
produce useful diagnostics, not just "timed out waiting for condition".

> See also: `references/e2e-test-structure-core.md`

**FAIL pattern:**
```go
Eventually(func(g Gomega) {
    g.Expect(obj.Status.Phase).To(Equal(storagev1.InstanceReady))
})
```

**PASS pattern:**
```go
Eventually(func(g Gomega) {
    g.Expect(obj.Status.Phase).To(Equal(storagev1.InstanceReady),
        "reason: %v, message: %v", obj.Status.Reason, obj.Status.Message)
})
```

---

### C8 — A function must not delete what it did not create [BLOCKING]

If a helper function is passed a resource it did not create, it must not call
`Delete` on that resource. Cleanup responsibility belongs to the function (or test)
that called `Create`. Violating this makes teardown unpredictable and causes
failures that are hard to trace.

**FAIL pattern:**
```go
func runWorkflow(ctx context.Context, cluster *Cluster) {
    // ... uses cluster ...
    client.Delete(ctx, cluster.Name, metav1.DeleteOptions{})  // didn't create it
}
```

**PASS pattern:**
```go
func runWorkflow(ctx context.Context, cluster *Cluster) {
    // ... uses cluster, does not delete it ...
}
// deletion is in the test that created the cluster
```

---

### C9 — No Gomega assertions inside helper functions that don't call GinkgoHelper() [BLOCKING]

`Expect`, `Eventually`, and `Consistently` must not appear in helper functions
unless the function explicitly calls `GinkgoHelper()` at the top. Helper functions
that don't call `GinkgoHelper()` should return errors; the test decides how to
assert them.

**FAIL pattern:**
```go
// in setup/project/project.go
func Create(ctx context.Context) context.Context {
    _, err := client.Create(ctx, obj, metav1.CreateOptions{})
    Expect(err).To(Succeed())  // assertion inside helper
    return ctx
}
```

**PASS pattern:**
```go
// in setup/project/project.go
func Create(ctx context.Context) (context.Context, error) {
    _, err := client.Create(ctx, obj, metav1.CreateOptions{})
    return ctx, err
}

// in the test:
ctx, err = project.Create(ctx)
Expect(err).To(Succeed())
```

---

### C10 — Prefer Succeed() over NotTo(HaveOccurred()) [WARN]

`Expect(err).To(Succeed())` is the preferred form for asserting no error occurred.
`Expect(err).NotTo(HaveOccurred())` is not incorrect but is non-idiomatic.

> See also: `references/e2e-conventions-core.md` item 7

**Suggest:**
```go
// preferred
Expect(err).To(Succeed())

// acceptable but suggest changing
Expect(err).NotTo(HaveOccurred())
```

This is a warning only — do not block on this alone.

---

### C11 — No hardcoded timeouts [BLOCKING]

Do not use raw `time.Duration` literals in `WithTimeout` or `WithPolling`. Use the
predefined constants from the `constants` package.

> See also: `references/e2e-quality-checklist-core.md` item 3, `references/e2e-conventions-core.md` item 3

**FAIL pattern:**
```go
Eventually(func(g Gomega) { ... }).WithTimeout(5 * time.Minute)
```

**PASS pattern:**
```go
Eventually(func(g Gomega) { ... }).WithTimeout(constants.PollingTimeoutVeryLong)
```

---

### C12 — Ordered requires a dependency comment [BLOCKING]

Any `Describe` or `Context` using `Ordered` must have a comment naming which spec
depends on which prior spec's side effect. If no such dependency exists, `Ordered`
should be removed.

> See also: `references/e2e-conventions-core.md` item 5, `references/e2e-quality-checklist-core.md` item 5

**FAIL pattern:**
```go
var _ = Describe("Feature", Ordered, func() { ... })
```

**PASS pattern:**
```go
// Spec "verifies sync" depends on the object created by "creates resource".
var _ = Describe("Feature", Ordered, func() { ... })
```

---

### C13 — Test-scoped constants stay in the test package [BLOCKING]

Constants, helper functions, and option builders used by only one `test_*` package
must live in that package. Do not add them to the shared `constants` or `setup`
packages. Only promote to a shared package when a second consumer appears.

> See also: `references/e2e-conventions-core.md` — Scoping Constants and Helpers

**FAIL pattern:**
```go
// in e2e-next/constants/vault.go — only used by test_vault
const VaultNamespace = "vault-test"
```

**PASS pattern:**
```go
// in e2e-next/test_vault/constants.go
const vaultNamespace = "vault-test"
```

---

### C14 — No hardcoded or singleton resource names [BLOCKING]

Resource names must never be hardcoded constants. Any name that could collide across
parallel runs must be generated with `objectmeta.GenerateName` or `random.RandomString(6)`.
This applies to all identifiers that could conflict — Kubernetes object names, Helm
release names, database names, etc.

> See also: `references/e2e-quality-checklist-core.md` item 4, `references/e2e-conventions-core.md` item 1

**FAIL pattern:**
```go
nsName := "vault-test-namespace"  // hardcoded — collides in parallel runs
```

**PASS pattern:**
```go
nsName := "vault-test-" + random.RandomString(6)
```

---

### C15 — Single shared suffix per test container [BLOCKING]

Within a single `It` block or `Ordered` container, generate one suffix with
`random.RandomString(6)` and reuse it for all resource names. Do not generate a
separate suffix per resource — resources from the same test must be traceable together.

> See also: `references/e2e-quality-checklist-core.md` item 5.1, `references/e2e-conventions-core.md` item 1

**FAIL pattern:**
```go
BeforeAll(func(ctx context.Context) context.Context {
    nsName = "test-sync-" + random.RandomString(6)   // different suffix per resource
    svcName = "test-svc-" + random.RandomString(6)
})
```

**PASS pattern:**
```go
BeforeAll(func(ctx context.Context) context.Context {
    suffix := random.RandomString(6)
    nsName = "test-sync-" + suffix   // same suffix — all resources traceable together
    svcName = "test-svc-" + suffix
})
```

---

### C16 — Use scoped Gomega inside Eventually, not global assertions [BLOCKING]

When asserting inside `Eventually`, pass a `g Gomega` argument to the callback and
use `g.Expect(...)` instead of the global `Expect(...)`. A global assertion fails the
entire spec immediately on the first poll — retries never happen.

**FAIL pattern:**
```go
Eventually(func() {
    err := someOperation()
    Expect(err).NotTo(HaveOccurred())  // global — fails spec immediately, no retry
}).Should(Succeed())
```

**PASS pattern:**
```go
Eventually(func(g Gomega) {
    err := someOperation()
    g.Expect(err).NotTo(HaveOccurred())  // scoped — retries on failure
}).Should(Succeed())
```

---

## Step 4 — Output violation report

Print a structured report of all violations found. Use this format:

```
E2E Quality Review — <N> violation(s) found

BLOCKING:
  [C1] <file>:<line> — <one sentence describing the violation>
  [C3] <file>:<line> — <one sentence describing the violation>

WARN:
  [C10] <file>:<line> — <one sentence describing the violation>

---
Fix suggestions:
  [C1] <file>:<line>
    <minimal corrected code snippet>
```

If no violations:
```
E2E Quality Review — All checklist items passed.
```

---

## Step 5 — Post to GitHub (CI only)

Skip this step if running locally — the violation report from Step 4 is sufficient.

If `PR_NUMBER` and `REPO` are set, post the violations to GitHub.

For each violation, post an inline comment anchored to the specific line:

```bash
gh api repos/$REPO/pulls/$PR_NUMBER/comments \
  --method POST \
  --field body="**E2E Quality Violation — C{N}: {short name}**

{One sentence describing exactly what is wrong on this line.}

**Fix:**
{Minimal corrected code snippet.}" \
  --field commit_id="$(gh pr view $PR_NUMBER --repo $REPO --json headRefOid -q .headRefOid)" \
  --field path="<file>" \
  --field line=<line_number> \
  --field side="RIGHT"
```

Group violations by file. Post all inline comments before posting the summary review.

Then post a single summary review:

**If any BLOCKING violations were found:**
```bash
gh pr review "$PR_NUMBER" --repo "$REPO" --request-changes \
  --body "E2E quality review found N violation(s): C1×2, C3×1, ...

See inline comments for details. All blocking items must be resolved before merge."
```

**If only WARN violations (C10 only):**
```bash
gh pr review "$PR_NUMBER" --repo "$REPO" --comment \
  --body "E2E quality review passed. N style suggestion(s) left inline (non-blocking)."
```

**If no violations:**
```bash
gh pr review "$PR_NUMBER" --repo "$REPO" --comment \
  --body "E2E quality review passed. All checklist items satisfied."
```

---

## Guardrails

- **Only flag added/changed lines** — do not report violations on unchanged code
- **One violation per line** — do not report the same line twice
- **C10 is never BLOCKING** — warn only
- **Be precise** — cite the exact pattern, not a general description
- **Do not rubber-stamp** — for each checklist item, explicitly confirm it passes or explain why it is N/A before moving on
- **Do not post praise** — only actionable violations
