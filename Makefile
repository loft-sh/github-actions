.PHONY: test test-semver-validation test-linear-pr-commenter test-release-notification test-linear-release-sync test-cleanup-head-charts test-ci-test-notify test-auto-approve-bot-prs test-publish-helm-chart test-govulncheck test-go-licenses build-linear-release-sync lint install-auto-doc generate-docs check-docs help

ACTIONS_DIR := .github/actions
WORKFLOWS_DIR := .github/workflows
SCRIPTS_DIR := .github/scripts

# --- auto-doc -----------------------------------------------------------
AUTO_DOC_VERSION := 3.6.0

# Detect OS and arch for binary download
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S),Darwin)
  AUTO_DOC_OS := Darwin
else
  AUTO_DOC_OS := Linux
endif
ifeq ($(UNAME_M),arm64)
  AUTO_DOC_ARCH := arm64
else ifeq ($(UNAME_M),aarch64)
  AUTO_DOC_ARCH := arm64
else
  AUTO_DOC_ARCH := x86_64
endif

AUTO_DOC_BIN := .bin/auto-doc

$(AUTO_DOC_BIN):
	@mkdir -p .bin
	curl -sSfL "https://github.com/tj-actions/auto-doc/releases/download/v$(AUTO_DOC_VERSION)/auto-doc_$(AUTO_DOC_VERSION)_$(AUTO_DOC_OS)_$(AUTO_DOC_ARCH).tar.gz" \
	  | tar xz -C .bin auto-doc

install-auto-doc: $(AUTO_DOC_BIN) ## install auto-doc CLI

generate-docs: $(AUTO_DOC_BIN) ## regenerate docs from action.yml / workflow YAML
	@# Composite actions
	@for action_yml in $(ACTIONS_DIR)/*/action.yml; do \
	  dir=$$(dirname "$$action_yml"); \
	  readme="$$dir/README.md"; \
	  if [ -f "$$readme" ]; then \
	    $(AUTO_DOC_BIN) -f "$$action_yml" -o "$$readme" && \
	    echo "  updated $$readme"; \
	  fi; \
	done
	@# Reusable workflows
	@for doc in docs/workflows/*.md; do \
	  name=$$(basename "$$doc" .md); \
	  wf="$(WORKFLOWS_DIR)/$$name.yaml"; \
	  if [ -f "$$wf" ]; then \
	    $(AUTO_DOC_BIN) -f "$$wf" -r -o "$$doc" && \
	    echo "  updated $$doc"; \
	  fi; \
	done

check-docs: generate-docs ## verify docs are up to date (fails if drift detected)
	@# Check that every action has a README with auto-doc markers
	@fail=0; \
	for action_yml in $(ACTIONS_DIR)/*/action.yml; do \
	  dir=$$(dirname "$$action_yml"); \
	  name=$$(basename "$$dir"); \
	  readme="$$dir/README.md"; \
	  if [ ! -f "$$readme" ]; then \
	    echo "ERROR: $$dir has action.yml but no README.md"; \
	    fail=1; \
	  elif ! grep -q 'AUTO-DOC-INPUT:START' "$$readme"; then \
	    echo "ERROR: $$readme is missing AUTO-DOC-INPUT markers"; \
	    fail=1; \
	  fi; \
	done; \
	for wf in $(WORKFLOWS_DIR)/*.yaml; do \
	  if grep -q 'workflow_call' "$$wf"; then \
	    name=$$(basename "$$wf" .yaml); \
	    doc="docs/workflows/$$name.md"; \
	    if [ ! -f "$$doc" ]; then \
	      echo "ERROR: reusable workflow $$wf has no doc at $$doc"; \
	      fail=1; \
	    fi; \
	  fi; \
	done; \
	if [ "$$fail" -eq 1 ]; then exit 1; fi
	@# Check that generated content matches committed content
	@if ! git diff --quiet -- '*.md'; then \
	  echo ""; \
	  echo "ERROR: Generated docs are out of date. Run 'make generate-docs' and commit the changes."; \
	  echo ""; \
	  git diff --stat -- '*.md'; \
	  exit 1; \
	fi
	@echo "Docs are up to date."

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-30s %s\n", $$1, $$2}'

test: test-semver-validation test-linear-pr-commenter test-release-notification test-linear-release-sync test-cleanup-head-charts test-auto-approve-bot-prs test-ci-test-notify test-go-licenses test-publish-helm-chart test-govulncheck ## run all action tests

test-semver-validation: ## run semver-validation unit tests
	cd $(ACTIONS_DIR)/semver-validation && npm ci --silent && NODE_OPTIONS=--experimental-vm-modules npx jest --ci --coverage --watchAll=false

test-linear-pr-commenter: ## run linear-pr-commenter unit tests
	cd $(ACTIONS_DIR)/linear-pr-commenter/src && go test -v ./...

test-release-notification: ## run release-notification detect-branch tests
	bats $(ACTIONS_DIR)/release-notification/test/detect-branch.bats

test-linear-release-sync: ## run linear-release-sync unit tests
	cd $(ACTIONS_DIR)/linear-release-sync/src && go test -v ./...

test-cleanup-head-charts: ## run cleanup-head-charts bats tests
	bats $(SCRIPTS_DIR)/cleanup-head-charts/test/cleanup-head-charts.bats

test-auto-approve-bot-prs: ## run auto-approve-bot-prs bats tests
	bats $(ACTIONS_DIR)/auto-approve-bot-prs/test/*.bats

test-ci-test-notify: ## run ci-test-notify bats tests
	bats $(ACTIONS_DIR)/ci-test-notify/test/build-payload.bats

test-publish-helm-chart: ## run publish-helm-chart bats tests (requires mikefarah/yq on PATH)
	bats $(ACTIONS_DIR)/publish-helm-chart/test/run.bats

test-govulncheck: ## run govulncheck bats tests
	bats $(ACTIONS_DIR)/govulncheck/test/run.bats

test-go-licenses: ## run go-licenses bats tests
	bats $(ACTIONS_DIR)/go-licenses/test/run.bats

build-linear-release-sync: ## build linear-release-sync binary (linux/amd64)
	cd $(ACTIONS_DIR)/linear-release-sync/src && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o ../linear-release-sync-linux-amd64 .

lint: ## run actionlint and zizmor on workflows
	actionlint .github/workflows/*.yaml
	zizmor .github/

# Reusable workflow tests (test-*.yaml for workflow_call workflows) run in CI only.
# They require GitHub event context and cannot be executed locally.
