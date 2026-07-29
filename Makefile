PREFIX ?= $(HOME)/.local

.PHONY: all build build-zig build-shell test test-zig test-shell check \
	lint lint-shell fmt fmt-zig fmt-shell install install-zig install-shell \
	clean clean-zig clean-shell

all: build

build: build-zig build-shell

build-zig:
	zig build

build-shell:
	+$(MAKE) -C src/shell

test: test-zig test-shell

test-zig:
	zig build test

test-shell:
	+$(MAKE) -C src/shell check

check: test lint

lint: lint-shell

lint-shell:
	+$(MAKE) -C src/shell lint

fmt: fmt-zig fmt-shell

fmt-zig:
	zig build format

fmt-shell:
	+$(MAKE) -C src/shell fmt

install: install-zig install-shell

install-zig:
	zig build --prefix "$(PREFIX)"

install-shell:
	+$(MAKE) -C src/shell install PREFIX="$(PREFIX)"

clean: clean-zig clean-shell

clean-zig:
	rm -rf .zig-cache zig-out

clean-shell:
	+$(MAKE) -C src/shell clean
