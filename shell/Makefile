KEYWORK ?= keywork
EMMYLUA_CHECK ?= emmylua_check
LUAFMT ?= luafmt
CC ?= cc
PKG_CONFIG ?= pkg-config
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/keywork-shell
SYSTEMD_USER_DIR ?= $(HOME)/.config/systemd/user
PAMDIR ?= /etc/pam.d

SCRIPT := lua/init.lua
LOCK := lua/lock.lua
BACKGROUND := lua/background.lua
STORYBOOK := lua/storybook.lua
MODULES := \
	lua/shell/ipc.lua \
	lua/shell/audio.lua \
	lua/shell/clock.lua \
	lua/shell/idle.lua \
	lua/shell/lock.lua \
	lua/shell/bar/init.lua \
	lua/shell/bar/colors.lua \
	lua/shell/bar/network.lua \
	lua/shell/bar/status.lua \
	lua/shell/bar/workspaces.lua \
	lua/shell/bar/tray.lua \
	lua/shell/bar/util.lua \
	lua/shell/notifications.lua \
	lua/shell/osd.lua \
	lua/shell/session.lua \
	lua/shell/launcher/init.lua \
	lua/shell/launcher/history.lua \
	lua/shell/launcher/match.lua \
	lua/shell/launcher/providers/init.lua \
	lua/shell/launcher/providers/apps.lua \
	lua/shell/launcher/providers/power.lua
BIN := keywork-shell
SERVICE := keywork-shell.service
AUTH_SOURCE := native/auth.c
AUTH_MODULE := .build/lua/shell/auth.so
WAYLAND_SOURCE := native/wayland.c
WAYLAND_MODULE := .build/lua/shell/wayland.so
WAYLAND_PROTOCOL_DIR := .build/wayland-protocols
IDLE_PROTOCOL_XML := $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)/staging/ext-idle-notify/ext-idle-notify-v1.xml
IDLE_PROTOCOL_HEADER := $(WAYLAND_PROTOCOL_DIR)/ext-idle-notify-v1-client-protocol.h
IDLE_PROTOCOL_CODE := $(WAYLAND_PROTOCOL_DIR)/ext-idle-notify-v1-protocol.c
WORKSPACE_PROTOCOL_XML := $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)/staging/ext-workspace/ext-workspace-v1.xml
WORKSPACE_PROTOCOL_HEADER := $(WAYLAND_PROTOCOL_DIR)/ext-workspace-v1-client-protocol.h
WORKSPACE_PROTOCOL_CODE := $(WAYLAND_PROTOCOL_DIR)/ext-workspace-v1-protocol.c
OUTPUT_POWER_PROTOCOL_XML := protocols/wlr-output-power-management-unstable-v1.xml
OUTPUT_POWER_PROTOCOL_HEADER := $(WAYLAND_PROTOCOL_DIR)/wlr-output-power-management-unstable-v1-client-protocol.h
OUTPUT_POWER_PROTOCOL_CODE := $(WAYLAND_PROTOCOL_DIR)/wlr-output-power-management-unstable-v1-protocol.c
PAM_SERVICE := pam/keywork-shell

.PHONY: all check lint fmt run install install-app install-service install-pam reload-service clean

all: check

check: $(AUTH_MODULE) $(WAYLAND_MODULE) $(SCRIPT) $(LOCK) $(BACKGROUND) $(STORYBOOK) $(MODULES)
	for file in $(SCRIPT) $(LOCK) $(BACKGROUND) $(STORYBOOK) $(MODULES); do luajit -b $$file /tmp/keywork-shell-check.luac || exit 1; done
	rm -f /tmp/keywork-shell-check.luac

lint:
	$(EMMYLUA_CHECK) lua --config .emmyrc.json --warnings-as-errors

fmt:
	$(LUAFMT) lua types --write

$(AUTH_MODULE): $(AUTH_SOURCE)
	mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wall -Wextra -Werror -fPIC -shared \
		$$($(PKG_CONFIG) --cflags luajit) -o $@ $< $(LDFLAGS) \
		$$($(PKG_CONFIG) --libs pam)

$(IDLE_PROTOCOL_HEADER): $(IDLE_PROTOCOL_XML)
	mkdir -p $(@D)
	wayland-scanner client-header $< $@

$(IDLE_PROTOCOL_CODE): $(IDLE_PROTOCOL_XML)
	mkdir -p $(@D)
	wayland-scanner private-code $< $@

$(WORKSPACE_PROTOCOL_HEADER): $(WORKSPACE_PROTOCOL_XML)
	mkdir -p $(@D)
	wayland-scanner client-header $< $@

$(WORKSPACE_PROTOCOL_CODE): $(WORKSPACE_PROTOCOL_XML)
	mkdir -p $(@D)
	wayland-scanner private-code $< $@

$(OUTPUT_POWER_PROTOCOL_HEADER): $(OUTPUT_POWER_PROTOCOL_XML)
	mkdir -p $(@D)
	wayland-scanner client-header $< $@

$(OUTPUT_POWER_PROTOCOL_CODE): $(OUTPUT_POWER_PROTOCOL_XML)
	mkdir -p $(@D)
	wayland-scanner private-code $< $@

$(WAYLAND_MODULE): $(WAYLAND_SOURCE) $(IDLE_PROTOCOL_HEADER) $(IDLE_PROTOCOL_CODE) $(WORKSPACE_PROTOCOL_HEADER) $(WORKSPACE_PROTOCOL_CODE) $(OUTPUT_POWER_PROTOCOL_HEADER) $(OUTPUT_POWER_PROTOCOL_CODE)
	mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wall -Wextra -Werror -fPIC -shared \
		-I$(WAYLAND_PROTOCOL_DIR) $$($(PKG_CONFIG) --cflags luajit wayland-client) \
		-o $@ $(WAYLAND_SOURCE) $(IDLE_PROTOCOL_CODE) $(WORKSPACE_PROTOCOL_CODE) $(OUTPUT_POWER_PROTOCOL_CODE) $(LDFLAGS) \
		$$($(PKG_CONFIG) --libs wayland-client)

run: check
	$(KEYWORK) --script=$(SCRIPT)

install: install-app install-service

install-app: check
	install -d $(DATADIR)/lua/shell/bar $(DATADIR)/lua/shell/launcher/providers $(BINDIR)
	install -m 0644 $(SCRIPT) $(LOCK) $(BACKGROUND) $(DATADIR)/lua/
	for file in $(MODULES); do install -m 0644 $$file $(DATADIR)/$$file; done
	install -m 0755 $(AUTH_MODULE) $(DATADIR)/lua/shell/auth.so
	install -m 0755 $(WAYLAND_MODULE) $(DATADIR)/lua/shell/wayland.so
	install -m 0755 bin/$(BIN) $(BINDIR)/$(BIN)

install-service:
	mkdir -p $(SYSTEMD_USER_DIR)
	cp $(SERVICE) $(SYSTEMD_USER_DIR)/$(SERVICE)
	systemctl --user daemon-reload

# Host/package installation only: this intentionally stays out of the
# unprivileged `install` target. Run `sudo make install-pam` on a live system.
install-pam:
	install -d $(DESTDIR)$(PAMDIR)
	install -m 0644 $(PAM_SERVICE) $(DESTDIR)$(PAMDIR)/keywork-shell

reload-service: install
	systemctl --user restart $(SERVICE)

clean:
	rm -rf .build
