PREFIX ?= $(HOME)/.local

.PHONY: all build test check lint fmt install install-shell clean

all: build

build:
	zig build
	+$(MAKE) -C shell

test:
	zig build test

check: test
	+$(MAKE) -C shell check

lint:
	+$(MAKE) -C shell lint

fmt:
	zig build format
	+$(MAKE) -C shell fmt

install:
	zig build --prefix "$(PREFIX)"

install-shell:
	+$(MAKE) -C shell install PREFIX="$(PREFIX)"

clean:
	rm -rf .zig-cache zig-out
	+$(MAKE) -C shell clean
