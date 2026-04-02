SHELL := /bin/bash
TARGETS := claude-switch

.PHONY: all
all: $(TARGETS)

%: %.go
	go build -o $@ $^

.PHONY: test
test:
	go test -v ./...
	bash tests.sh

.PHONY: lint
lint:
	go vet -v ./...
	@command -v shellcheck >/dev/null 2>&1 || { echo "error: shellcheck not installed (https://github.com/koalaman/shellcheck#installing)" >&2; exit 1; }
	shellcheck claude-switch.sh tests.sh

.PHONY: clean
clean:
	rm -f $(TARGETS)
