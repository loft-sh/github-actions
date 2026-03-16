.PHONY: test test-semver-validation test-linear-pr-commenter lint help

ACTIONS_DIR := .github/actions

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-30s %s\n", $$1, $$2}'

test: test-semver-validation test-linear-pr-commenter ## run all action tests

test-semver-validation: ## run semver-validation unit tests
	cd $(ACTIONS_DIR)/semver-validation && npm ci --silent && NODE_OPTIONS=--experimental-vm-modules npx jest --ci --coverage --watchAll=false

test-linear-pr-commenter: ## run linear-pr-commenter unit tests
	cd $(ACTIONS_DIR)/linear-pr-commenter/src && go test -v ./...

lint: ## run actionlint and zizmor on workflows
	actionlint .github/workflows/*.yaml
	zizmor .github/
