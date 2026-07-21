# Claude Code CI session caps

Unattended Claude Code runs in CI have no human watching the token meter. A
prompt that goes sideways can spawn hundreds of subagents or loop on web
searches and burn the budget before anyone notices. Claude Code 2.1.212 added
two session-wide caps to bound that blast radius. This runbook records the
values we set, where they are set, and how to verify them.

## The two caps

| Environment variable | CLI default | Our CI value |
| --- | --- | --- |
| `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` | 200 | 20 |
| `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` | 200 | 50 |

The CLI default of 200 each is far too high to catch a runaway before it costs
real money in an unattended run. 20 subagents and 50 web searches are generous
for the legitimate CI jobs we run today (single-shot generation and PR review)
while still tripping early on a genuine loop. Raise them if a legitimate job
starts hitting a cap; that is the signal, not silent overspend.

## Behavior when a cap is exceeded

The caps are a graceful guardrail, not a hard abort. When a session reaches a
cap, Claude Code does not exit non-zero and does not stop the run. It refuses
the over-cap tool call, returns an explicit notice in that tool result, and the
session continues with the information it already has.

The exact notices the CLI emits (2.1.216):

Web searches:

```
Web search was not performed: this session has used its web search budget
(<n> of <cap> WebSearch calls). Continue with the information already gathered
instead of issuing more searches. If more searches are genuinely needed, ask
the user to raise CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION.
```

Subagents:

```
... agents spawned). Complete the remaining work directly with your tools
instead of spawning more agents. If more agents are genuinely needed, ask the
user to raise CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION.
```

`/clear` resets the subagent budget within an interactive session; CI runs are
single-shot so that does not apply there.

## Where the caps are set

Every CI job that runs Claude Code carries both caps. Two mechanisms are in
play because the invocation paths differ.

| Repo | File | Job | Mechanism |
| --- | --- | --- | --- |
| vcluster-pro | `.github/workflows/k8s-ai-conformance.yaml` | headless `claude -p` generate step | step `env:` |
| github-actions | `.github/workflows/claude.yaml` | reusable `@claude` responder | action `settings` env |
| github-actions | `.github/workflows/claude-code-review.yaml` | reusable PR review | action `settings` env |
| github-actions | `.github/workflows/claude.yml` | this repo's own `@claude` bot | action `settings` env |

Setting the caps in the two reusable workflows (`claude.yaml`,
`claude-code-review.yaml`) means every repo that calls them inherits the caps
with no per-caller change.

### Why two mechanisms

A direct `claude -p` invocation reads its configuration from the process
environment, so a step-level `env:` block is enough and is the simplest place
to set the caps.

`anthropics/claude-code-action` does not forward step-level `env:` to the
`claude` CLI it spawns. The supported way to pass environment to that CLI is
the action's `settings` input, whose `env` object is applied to the session:

```yaml
- uses: anthropics/claude-code-action@<pinned-sha> # v1
  with:
    settings: |
      {
        "env": {
          "CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION": "20",
          "CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION": "50"
        }
      }
```

## How to verify

`vcluster-pro/.github/workflows/claude-code-caps-verify.yaml` is a manual
(`workflow_dispatch`) check. It makes a small paid Claude call, so it never runs
on push or PR. It sets a tiny web-search cap, forces more searches than the cap
allows, and asserts the cap-reached notice lands in the run log. The assertion
logic is in `vcluster-pro/.github/scripts/claude-caps-verify.sh`.

Run it from the vcluster-pro Actions tab (Verify Claude Code Session Caps) or
with the gh CLI:

```bash
gh workflow run claude-code-caps-verify.yaml --repo loft-sh/vcluster-pro
```

A green run confirms the caps are honored and the notice text still matches. A
failure means either the cap did not fire or the CLI changed its message, both
of which warrant a look before trusting the caps.

## Open item

The PR review workflow checks out PR head content. A follow-up should confirm
whether an attacker-supplied `.claude/settings.json` in a PR could raise these
caps, or whether the action's explicit `settings` input takes precedence. That
is a prompt-injection hardening question tracked separately from setting the
default caps here.
