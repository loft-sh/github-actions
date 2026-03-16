.PHONY: test test-semver-validation test-linear-pr-commenter test-release-notification lint help

ACTIONS_DIR := .github/actions

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-30s %s\n", $$1, $$2}'

test: test-semver-validation test-linear-pr-commenter test-release-notification ## run all action tests

test-semver-validation: ## run semver-validation unit tests
	cd $(ACTIONS_DIR)/semver-validation && npm ci --silent && NODE_OPTIONS=--experimental-vm-modules npx jest --ci --coverage --watchAll=false

test-linear-pr-commenter: ## run linear-pr-commenter unit tests
	cd $(ACTIONS_DIR)/linear-pr-commenter/src && go test -v ./...

test-release-notification: ## run release-notification detect-branch tests
	bats $(ACTIONS_DIR)/release-notification/test/detect-branch.bats

lint: ## run actionlint and zizmor on workflows
	actionlint .github/workflows/*.yaml
	zizmor .github/

# Reusable workflow tests (test-*.yaml for workflow_call workflows) run in CI only.
# They require GitHub event context and cannot be executed locally.
