SHELL := /bin/bash
TARGETS := claude-switch

.PHONY: all
all: $(TARGETS)

%: %.go
	go build -o $@ $^

.PHONY: clean
clean:
	rm -f $(TARGETS)
