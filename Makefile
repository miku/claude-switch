SHELL := /bin/bash

cps: cps.go
	go build -o cps cps.go

.PHONY: clean
clean:
	rm -f cps
