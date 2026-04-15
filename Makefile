.PHONY: test test-semver-validation test-linear-pr-commenter test-release-notification test-linear-release-sync test-cleanup-head-charts test-ci-test-notify test-auto-approve-bot-prs test-publish-helm-chart build-linear-release-sync lint help

ACTIONS_DIR := .github/actions
SCRIPTS_DIR := .github/scripts

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-30s %s\n", $$1, $$2}'

test: test-semver-validation test-linear-pr-commenter test-release-notification test-linear-release-sync test-cleanup-head-charts test-auto-approve-bot-prs test-ci-test-notify test-publish-helm-chart ## run all action tests

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
	bats $(SCRIPTS_DIR)/publish-helm-chart/test/run.bats

build-linear-release-sync: ## build linear-release-sync binary (linux/amd64)
	cd $(ACTIONS_DIR)/linear-release-sync/src && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o ../linear-release-sync-linux-amd64 .

lint: ## run actionlint and zizmor on workflows
	actionlint .github/workflows/*.yaml
	zizmor .github/

# Reusable workflow tests (test-*.yaml for workflow_call workflows) run in CI only.
# They require GitHub event context and cannot be executed locally.
