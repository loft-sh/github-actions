// Proves that the --focus expression produced by resolve-rerun-focus.sh selects the
// right specs once Ginkgo applies it. Ginkgo skips a spec when the focus regex does
// not match "<SuiteDescription> <container texts...> <It text>", compiled with Go's
// regexp package - see ginkgo/v2/internal/focus.go ApplyFocusToSpecs. Asserting on the
// regex text alone would not catch an escaping or anchoring mistake, so these tests
// replay the fixture through the real matcher.
package focus_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

type specReport struct {
	State                   string
	LeafNodeType            string
	LeafNodeText            string
	ContainerHierarchyTexts []string
}

type suiteReport struct {
	SuiteDescription string
	SpecReports      []specReport
}

// fullText mirrors internal.Spec.Text(): non-empty node texts joined by a space.
func (s specReport) fullText() string {
	texts := make([]string, 0, len(s.ContainerHierarchyTexts)+1)
	for _, t := range s.ContainerHierarchyTexts {
		if t != "" {
			texts = append(texts, t)
		}
	}
	if s.LeafNodeText != "" {
		texts = append(texts, s.LeafNodeText)
	}
	return strings.Join(texts, " ")
}

func (s specReport) didNotPass() bool {
	return !slices.Contains([]string{"passed", "skipped", "pending"}, s.State)
}

// resolveFocus runs the action's script against a fixture directory and returns the
// focus step output it emitted.
func resolveFocus(t *testing.T, fixture string) string {
	t.Helper()

	tmp := t.TempDir()
	outFile := filepath.Join(tmp, "github_output")
	if err := os.WriteFile(outFile, nil, 0o600); err != nil {
		t.Fatalf("create %s: %v", outFile, err)
	}

	script, err := filepath.Abs(filepath.Join("..", "..", "src", "resolve-rerun-focus.sh"))
	if err != nil {
		t.Fatalf("resolve script path: %v", err)
	}
	reportsDir, err := filepath.Abs(filepath.Join("..", "fixtures", "rerun", fixture))
	if err != nil {
		t.Fatalf("resolve fixture path: %v", err)
	}

	cmd := exec.Command("bash", script)
	cmd.Env = append(os.Environ(),
		"RERUN_FAILED_ONLY=true",
		"GITHUB_RUN_ATTEMPT=2",
		"RERUN_REPORTS_DIR="+reportsDir,
		"GITHUB_OUTPUT="+outFile,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("resolve-rerun-focus.sh failed: %v\n%s", err, out)
	}

	contents, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("read GITHUB_OUTPUT: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(contents), "\n"), "\n")
	for i, line := range lines {
		if line == "focus<<GINKGO_FOCUS_EOF" && i+1 < len(lines) {
			return lines[i+1]
		}
	}
	t.Fatalf("no focus output:\n%s", contents)
	return ""
}

func loadReport(t *testing.T, fixture, file string) []suiteReport {
	t.Helper()

	raw, err := os.ReadFile(filepath.Join("..", "fixtures", "rerun", fixture, file))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var suites []suiteReport
	if err := json.Unmarshal(raw, &suites); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return suites
}

// selectSpecs returns the It specs the focus expression would run, keyed by full text.
func selectSpecs(t *testing.T, focus string, suites []suiteReport) []string {
	t.Helper()

	re, err := regexp.Compile(focus)
	if err != nil {
		t.Fatalf("focus is not a valid Go regexp (Ginkgo would panic): %v\nfocus: %s", err, focus)
	}

	var selected []string
	for _, suite := range suites {
		for _, spec := range suite.SpecReports {
			if spec.LeafNodeType != "It" {
				continue
			}
			if re.MatchString(suite.SuiteDescription + " " + spec.fullText()) {
				selected = append(selected, spec.fullText())
			}
		}
	}
	slices.Sort(selected)
	return selected
}

func TestFocusRerunsEveryFailedSpec(t *testing.T) {
	suites := loadReport(t, "selection", "report.json")
	selected := selectSpecs(t, resolveFocus(t, "selection"), suites)

	for _, suite := range suites {
		for _, spec := range suite.SpecReports {
			if spec.LeafNodeType != "It" || !spec.didNotPass() {
				continue
			}
			if !slices.Contains(selected, spec.fullText()) {
				t.Errorf("failed spec would not be rerun: %q", spec.fullText())
			}
		}
	}
}

func TestFocusSelectsExactlyTheFailedTopLevelContainers(t *testing.T) {
	suites := loadReport(t, "selection", "report.json")
	selected := selectSpecs(t, resolveFocus(t, "selection"), suites)

	// Every spec under a container that had a failure, and nothing else. The whole
	// container runs because an Ordered spec cannot be rerun without its siblings.
	want := []string{
		"ArgoCD v2 Integration connector management creates the connector",
		"ArgoCD v2 Integration connector management deletes the connector",
		"ArgoCD v2 Integration template management parameter rendering renders parameters",
		"Auto Nodes Extended scales back up",
		"Auto Nodes Extended scales to zero",
		"Auto Snapshots on Azure Blob",
		"Auto Snapshots runs on schedule",
		"Metacharacters escapes [ ] { } ^ $ \\ * + ? every metacharacter",
		"Sleep Mode (a|b) when configured honours the annotation",
		"Sleep Mode (a|b) when configured ignores user agents",
		"Terraform destroys the module",
		"Terraform imports existing state",
		"Terraform installs the module",
		"virtualclusterinstances.management.loft.sh/v1 gets an instance",
		"virtualclusterinstances.management.loft.sh/v1 lists instances",
	}
	slices.Sort(want)

	if !slices.Equal(selected, want) {
		t.Errorf("selected specs mismatch\n got: %v\nwant: %v", selected, want)
	}
}

func TestFocusDoesNotLeakIntoNeighbouringContainers(t *testing.T) {
	suites := loadReport(t, "selection", "report.json")
	selected := selectSpecs(t, resolveFocus(t, "selection"), suites)

	// "Auto Nodes" and "Sleep Mode (a|b)" are prefixes of containers that did fail, and
	// "Sleep Mode (a|b)" also carries regex metacharacters. "Auto Snapshots on Azure Blob"
	// is a container whose name equals the full text of a spec that IS rerun, so it only
	// stays out while each alternative is anchored at both ends.
	for _, unwanted := range []string{
		"Auto Nodes boots a node",
		"Auto Nodes drains a node",
		"Sleep Mode (a|b) Extra wakes on traffic",
		"Node Profiles is untouched",
		"Node Profiles is not implemented",
		"Auto Snapshots on Azure Blob uploads the snapshot",
		// Differs from the dotted container only where the dots are, so an unescaped "."
		// in esc's character class shows up as over-selection.
		"virtualclusterinstancesXmanagementXloftXsh/v1 lists instances",
	} {
		if slices.Contains(selected, unwanted) {
			t.Errorf("spec from a passing container would be rerun: %q", unwanted)
		}
	}
}

func TestFocusDistinguishesSameNamedContainersAcrossSuites(t *testing.T) {
	suites := loadReport(t, "suite-collision", "report.json")
	selected := selectSpecs(t, resolveFocus(t, "suite-collision"), suites)

	// Both suites have a "Lifecycle" container with identically named specs; only the
	// one in Suite B failed. Grouping by container name alone would rerun Suite A's too,
	// and the two suites' specs are told apart only by the suite description prefix.
	want := []string{"Lifecycle creates a resource", "Lifecycle deletes a resource"}
	if !slices.Equal(selected, want) {
		t.Errorf("selected specs mismatch\n got: %v\nwant: %v", selected, want)
	}

	re := regexp.MustCompile(resolveFocus(t, "suite-collision"))
	if re.MatchString("Suite A Lifecycle creates a resource") {
		t.Error("focus matched the passing suite's identically named spec")
	}
	if !re.MatchString("Suite B Lifecycle creates a resource") {
		t.Error("focus did not match the failing suite's spec")
	}
}

func TestFocusIsScopedToItsOwnSuite(t *testing.T) {
	suites := loadReport(t, "multi-suite", "suite-b.json")
	focus := resolveFocus(t, "multi-suite")

	re := regexp.MustCompile(focus)
	// With -r the focus is applied to every discovered suite, so it has to pin the suite
	// description too: an identically named spec in another suite must not match, not even
	// when that suite's description ends with the focused one.
	for _, other := range []string{"Suite C Alpha fails here", "Extra Suite A Alpha fails here"} {
		if re.MatchString(other) {
			t.Errorf("focus matched a spec in an unrelated suite: %q\nfocus: %s", other, focus)
		}
	}
	if !re.MatchString("Suite B Beta hangs") {
		t.Errorf("focus did not match its own suite's spec\nfocus: %s", focus)
	}
	if len(suites) == 0 {
		t.Fatal("fixture suite-b.json is empty")
	}
}
