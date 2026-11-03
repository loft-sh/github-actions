package main

import (
	"fmt"
	"regexp"
	"strings"
)

var fullSHARe = regexp.MustCompile(`^[0-9a-f]{40}$`)

func verdict(pass bool) string {
	if pass {
		return "PASS"
	}
	return "FAIL"
}

// renderText is the plain report for logs and local runs.
func renderText(rc receipt) string {
	var b strings.Builder
	fmt.Fprintf(&b, "fork review check %s: %s (%d forks)\n", rc.CLIVersion, verdict(rc.Pass), len(rc.Forks))
	for _, f := range rc.Failures {
		fmt.Fprintf(&b, "  FAIL %s\n", f)
	}
	for _, f := range rc.Forks {
		fmt.Fprintf(&b, "\n%s %s @ %s: %s\n", f.Repo, f.Ref, short(f.Commit), verdict(f.Pass))
		fmt.Fprintf(&b, "  fork-upstream: %s (%s)\n", orNone(f.ForkUpstream), f.ForkUpstreamSource)
		if f.Base != nil {
			fmt.Fprintf(&b, "  base: %s %s (%s), %d fork commits\n", f.Base.Rule, f.Base.Ref, short(f.Base.Commit), len(f.Commits))
		}
		if f.ReviewedTree != nil && f.ReviewedTree.Pass {
			fmt.Fprintf(&b, "  reviewed tree: #%d (%s)\n", f.ReviewedTree.Pull.Number, f.ReviewedTree.Via)
		}
		for _, msg := range f.Failures {
			fmt.Fprintf(&b, "  FAIL %s\n", msg)
		}
		for _, c := range f.Commits {
			fmt.Fprintf(&b, "  %s %s %s %q\n", verdict(c.Pass), short(c.SHA), orNone(c.Author), c.Subject)
			if c.Pass {
				fmt.Fprintf(&b, "       #%d approved by %s (%s) at %s\n", c.Pull.Number, c.Approval.Approver, c.Approval.Permission, c.Approval.SubmittedAt.Format("2006-01-02T15:04:05Z"))
			}
			for _, msg := range c.Failures {
				fmt.Fprintf(&b, "       %s\n", msg)
			}
		}
	}
	return b.String()
}

// renderMarkdown is the job summary: one table per fork.
func renderMarkdown(rc receipt) string {
	var b strings.Builder
	fmt.Fprintf(&b, "## Fork review check: %s\n\n", verdict(rc.Pass))
	for _, f := range rc.Failures {
		fmt.Fprintf(&b, "- %s\n", f)
	}
	for _, f := range rc.Forks {
		fmt.Fprintf(&b, "\n### %s `%s` (%s): %s\n\n", f.Repo, f.Ref, short(f.Commit), verdict(f.Pass))
		fmt.Fprintf(&b, "fork-upstream: `%s` (%s)", orNone(f.ForkUpstream), f.ForkUpstreamSource)
		if f.Base != nil {
			fmt.Fprintf(&b, "; base %s `%s`", f.Base.Rule, f.Base.Ref)
		}
		b.WriteString("\n\n")
		for _, msg := range f.Failures {
			fmt.Fprintf(&b, "- %s\n", msg)
		}
		if len(f.Commits) == 0 {
			continue
		}
		b.WriteString("\n| Commit | Author | PR | Approver | Permission | Result |\n| --- | --- | --- | --- | --- | --- |\n")
		for _, c := range f.Commits {
			pr, approver, perm := "", "", ""
			if c.Pull != nil {
				pr = fmt.Sprintf("[#%d](%s)", c.Pull.Number, c.Pull.URL)
			}
			if c.Approval != nil {
				approver, perm = c.Approval.Approver, c.Approval.Permission
			}
			result := verdict(c.Pass)
			if !c.Pass {
				result += ": " + strings.ReplaceAll(strings.Join(c.Failures, "; "), "|", "\\|")
			}
			fmt.Fprintf(&b, "| `%s` | %s | %s | %s | %s | %s |\n", short(c.SHA), orNone(c.Author), pr, approver, perm, result)
		}
	}
	return b.String()
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}
