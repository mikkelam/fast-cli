#
#  Makefile
#
#  The kickoff point for all project management commands.
#

GOCC := go

# binary metadata
VERSION ?= $(shell git describe --always --tags)
COMMIT ?= $(shell git rev-parse HEAD)
DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_COMMIT=$(shell git rev-parse HEAD)

# Check if there are uncommited changes
GIT_DIRTY=$(shell test -n "`git status --porcelain`" && echo "+CHANGES" || true)


# Binary name
BIN_NAME=fast-cli
OWNER=mikkelam
PROJECT_NAME=fast-cli
REPO_HOST_URL=github.com

default: test build

.PHONY: help
help:
	@echo 'Management commands for ${PROJECT_NAME}:'
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	 awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo

.PHONY: lint
lint: ## Run golangci-lint
	@echo "Running golangci-lint"
	@golangci-lint run

format: ## Run go fmt
	@echo "Running go fmt"
	@go fmt ./...

.PHONY: build
build: ## Compile the project
	@echo "Building ${OWNER} ${BIN_NAME} ${VERSION}"
	@echo "GOPATH=${GOPATH}"
	${GOCC} build -a -ldflags "-w -s -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.date=${DATE} -X main.commit=${COMMIT}" -o ${BIN_NAME}



.PHONY: clean
clean: ## Clean the directory tree of artifacts
	${GOCC} clean
	rm -f ./${BIN_NAME}.test
	rm -f ./${BIN_NAME}
	rm -rf ./dist
