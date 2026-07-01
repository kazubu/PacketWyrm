# PacketWyrm host-side build.
#
# - libpacketwyrm: static + shared library
# - packetwyrmd:   daemon (per-card host-plane workers + JSON-RPC control socket)
# - pktwyrm:       command-line client
# - tests:         unit tests linking the static library
#
# External dependencies (detected via pkg-config):
#   yaml-0.1   (libyaml; YAML parsing)
#
# Future phases will add: libpci, libnl-route-3, libjson-c.

PKG_CONFIG ?= pkg-config

CC      ?= cc
CSTD    ?= -std=c11
WARN    ?= -Wall -Wextra -Wno-unused-parameter -Wmissing-prototypes -Wshadow
OPT     ?= -O2
DEBUG   ?= -g
CFLAGS  ?= $(CSTD) $(WARN) $(OPT) $(DEBUG) -fPIC -D_GNU_SOURCE
LDFLAGS ?=

YAML_CFLAGS := $(shell $(PKG_CONFIG) --cflags yaml-0.1)
YAML_LIBS   := $(shell $(PKG_CONFIG) --libs yaml-0.1)
JSON_CFLAGS := $(shell $(PKG_CONFIG) --cflags json-c)
JSON_LIBS   := $(shell $(PKG_CONFIG) --libs json-c)
SSL_CFLAGS  := $(shell $(PKG_CONFIG) --cflags openssl)
SSL_LIBS    := $(shell $(PKG_CONFIG) --libs openssl)

EXTRA_CFLAGS := $(YAML_CFLAGS) $(JSON_CFLAGS)
EXTRA_LIBS   := $(YAML_LIBS) $(JSON_LIBS) -lpthread

LIB_DIR     := libpacketwyrm
LIB_INC     := $(LIB_DIR)/include
LIB_SRC_DIR := $(LIB_DIR)/src
LIB_SRC     := $(wildcard $(LIB_SRC_DIR)/*.c)
LIB_OBJ     := $(LIB_SRC:.c=.o)

BUILD_DIR ?= build

LIBA      := $(BUILD_DIR)/libpacketwyrm.a
LIBSO     := $(BUILD_DIR)/libpacketwyrm.so

DAEMON_SRC := packetwyrmd/src/main.c
DAEMON_BIN := $(BUILD_DIR)/packetwyrmd

CLI_SRC := pktwyrm/src/main.c
CLI_BIN := $(BUILD_DIR)/pktwyrm

PROXYD_SRC   := packetwyrm-proxyd/src/main.c
PROXYD_BIN   := $(BUILD_DIR)/packetwyrm-proxyd
PROXYD_ASSET := packetwyrm-proxyd/assets/index.html
PROXYD_ASSET_H := $(BUILD_DIR)/proxyd_assets.h

TEST_SRC := tests/unit/test_main.c
TEST_BIN := $(BUILD_DIR)/test_unit

INCLUDES := -I$(LIB_INC) $(EXTRA_CFLAGS)

.PHONY: all clean test daemon cli lib proxyd
all: lib daemon cli proxyd

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

%.o: %.c
	$(CC) $(CFLAGS) $(INCLUDES) -MMD -MP -c -o $@ $<

# Header dependency tracking: rebuild objects when an included header changes
# (e.g. a struct in config.h). Without this, editing a header left stale .o
# with a mismatched struct layout -> crashes. -MMD emits these .d files.
-include $(LIB_OBJ:.o=.d)

lib: $(LIBA) $(LIBSO)

$(LIBA): $(LIB_OBJ) | $(BUILD_DIR)
	ar rcs $@ $(LIB_OBJ)

$(LIBSO): $(LIB_OBJ) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@ $(LIB_OBJ) $(EXTRA_LIBS) $(LDFLAGS)

daemon: $(DAEMON_BIN)
$(DAEMON_BIN): $(DAEMON_SRC) $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(DAEMON_SRC) $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

cli: $(CLI_BIN)
$(CLI_BIN): $(CLI_SRC) $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(CLI_SRC) $(LIBA) $(EXTRA_LIBS) $(LDFLAGS) -lm

# packetwyrm-proxyd: HTTPS gateway for the Web GUI + remote CLI.
# The GUI page is embedded via `xxd -i` (run inside the assets dir so the
# generated symbols are the clean `index_html` / `index_html_len`).
$(PROXYD_ASSET_H): $(PROXYD_ASSET) | $(BUILD_DIR)
	cd $(dir $<) && xxd -i $(notdir $<) > $(CURDIR)/$@

proxyd: $(PROXYD_BIN)
$(PROXYD_BIN): $(PROXYD_SRC) $(PROXYD_ASSET_H) $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -I$(BUILD_DIR) -o $@ $(PROXYD_SRC) $(LIBA) \
	    $(EXTRA_LIBS) $(SSL_LIBS) $(LDFLAGS)

test: $(TEST_BIN)
	$(TEST_BIN)

$(TEST_BIN): $(TEST_SRC) $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(TEST_SRC) $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

gen_bar_vectors: $(BUILD_DIR)/gen_bar_vectors
$(BUILD_DIR)/gen_bar_vectors: tests/gen_bar_vectors.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/gen_bar_vectors.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_sfp_test: $(BUILD_DIR)/pw_sfp_test
$(BUILD_DIR)/pw_sfp_test: tests/pw_sfp_test.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_sfp_test.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_card_probe: $(BUILD_DIR)/pw_card_probe
$(BUILD_DIR)/pw_card_probe: tests/pw_card_probe.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_card_probe.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_phase3_loopback: $(BUILD_DIR)/pw_phase3_loopback
$(BUILD_DIR)/pw_phase3_loopback: tests/pw_phase3_loopback.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_phase3_loopback.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_phase3_forward: $(BUILD_DIR)/pw_phase3_forward
$(BUILD_DIR)/pw_phase3_forward: tests/pw_phase3_forward.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_phase3_forward.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_phase3_punt: $(BUILD_DIR)/pw_phase3_punt
$(BUILD_DIR)/pw_phase3_punt: tests/pw_phase3_punt.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_phase3_punt.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_rfc2544: $(BUILD_DIR)/pw_rfc2544
$(BUILD_DIR)/pw_rfc2544: tests/pw_rfc2544.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_rfc2544.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_tcp_syn: $(BUILD_DIR)/pw_tcp_syn
$(BUILD_DIR)/pw_tcp_syn: tests/pw_tcp_syn.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_tcp_syn.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_phase3_modgen: $(BUILD_DIR)/pw_phase3_modgen pw_phase3_ipv6gen
$(BUILD_DIR)/pw_phase3_modgen: tests/pw_phase3_modgen.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_phase3_modgen.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_phase3_ipv6gen: $(BUILD_DIR)/pw_phase3_ipv6gen
$(BUILD_DIR)/pw_phase3_ipv6gen: tests/pw_phase3_ipv6gen.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_phase3_ipv6gen.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_phase3_inject: $(BUILD_DIR)/pw_phase3_inject
$(BUILD_DIR)/pw_phase3_inject: tests/pw_phase3_inject.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_phase3_inject.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_flash: $(BUILD_DIR)/pw_flash
$(BUILD_DIR)/pw_flash: tests/pw_flash.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_flash.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_reboot: $(BUILD_DIR)/pw_reboot
$(BUILD_DIR)/pw_reboot: tests/pw_reboot.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_reboot.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_dp_reset_recover: $(BUILD_DIR)/pw_dp_reset_recover
$(BUILD_DIR)/pw_dp_reset_recover: tests/pw_dp_reset_recover.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_dp_reset_recover.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_soak: $(BUILD_DIR)/pw_soak
$(BUILD_DIR)/pw_soak: tests/pw_soak.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_soak.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_gpio_sync: $(BUILD_DIR)/pw_gpio_sync
$(BUILD_DIR)/pw_gpio_sync: tests/pw_gpio_sync.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_gpio_sync.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_gpio_offset: $(BUILD_DIR)/pw_gpio_offset
$(BUILD_DIR)/pw_gpio_offset: tests/pw_gpio_offset.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_gpio_offset.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_sfp: $(BUILD_DIR)/pw_sfp
$(BUILD_DIR)/pw_sfp: tests/pw_sfp.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_sfp.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS) -lm

pw_xcard_latency: $(BUILD_DIR)/pw_xcard_latency
$(BUILD_DIR)/pw_xcard_latency: tests/pw_xcard_latency.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_xcard_latency.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

pw_port_latency: $(BUILD_DIR)/pw_port_latency
$(BUILD_DIR)/pw_port_latency: tests/pw_port_latency.c $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ tests/pw_port_latency.c $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

.PHONY: e2e gen_bar_vectors pw_card_probe pw_sfp_test pw_phase3_loopback pw_phase3_forward pw_phase3_punt pw_phase3_inject pw_phase3_modgen pw_phase3_ipv6gen pw_dp_reset_recover pw_soak pw_gpio_sync pw_gpio_offset pw_xcard_latency pw_port_latency pw_sfp
e2e: $(DAEMON_BIN) $(CLI_BIN) $(PROXYD_BIN)
	tests/integration/e2e_smoke.sh
	tests/integration/e2e_proxyd.sh

clean:
	rm -f $(LIB_OBJ)
	rm -rf $(BUILD_DIR)

# --- install / uninstall ---------------------------------------------------

DESTDIR    ?=
PREFIX     ?= /usr/local
SBINDIR    ?= $(PREFIX)/sbin
BINDIR     ?= $(PREFIX)/bin
LIBDIR     ?= $(PREFIX)/lib
INCDIR     ?= $(PREFIX)/include
SYSCONFDIR ?= /etc
UNITDIR    ?= /lib/systemd/system
SYSUSERDIR ?= /usr/lib/sysusers.d
TMPFILESDIR ?= /usr/lib/tmpfiles.d
UDEVDIR    ?= /etc/udev/rules.d
PKGROOT    ?= ..

INSTALL ?= install
INST_MK = $(INSTALL) -d
INST    = $(INSTALL) -m

.PHONY: install uninstall
install: all
	$(INST_MK) $(DESTDIR)$(SBINDIR)
	$(INST) 0755 $(BUILD_DIR)/packetwyrmd $(DESTDIR)$(SBINDIR)/packetwyrmd
	$(INST_MK) $(DESTDIR)$(BINDIR)
	$(INST) 0755 $(BUILD_DIR)/pktwyrm     $(DESTDIR)$(BINDIR)/pktwyrm
	$(INST_MK) $(DESTDIR)$(LIBDIR)
	$(INST) 0644 $(BUILD_DIR)/libpacketwyrm.a  $(DESTDIR)$(LIBDIR)/libpacketwyrm.a
	$(INST) 0755 $(BUILD_DIR)/libpacketwyrm.so $(DESTDIR)$(LIBDIR)/libpacketwyrm.so
	$(INST_MK) $(DESTDIR)$(INCDIR)/packetwyrm
	$(INST) 0644 $(LIB_INC)/packetwyrm/*.h $(DESTDIR)$(INCDIR)/packetwyrm/
	$(INST_MK) $(DESTDIR)$(SYSCONFDIR)/packetwyrm
	$(INST) 0644 $(PKGROOT)/configs/examples/single-card.yaml \
	    $(DESTDIR)$(SYSCONFDIR)/packetwyrm/single-card.yaml.example
	$(INST) 0644 $(PKGROOT)/configs/examples/multi-card.yaml \
	    $(DESTDIR)$(SYSCONFDIR)/packetwyrm/multi-card.yaml.example
	$(INST_MK) $(DESTDIR)$(UNITDIR)
	$(INST) 0644 $(PKGROOT)/packaging/packetwyrmd.service \
	    $(DESTDIR)$(UNITDIR)/packetwyrmd.service
	$(INST_MK) $(DESTDIR)$(SYSUSERDIR)
	$(INST) 0644 $(PKGROOT)/packaging/packetwyrm.sysusers \
	    $(DESTDIR)$(SYSUSERDIR)/packetwyrm.conf
	$(INST_MK) $(DESTDIR)$(TMPFILESDIR)
	$(INST) 0644 $(PKGROOT)/packaging/packetwyrm.tmpfiles \
	    $(DESTDIR)$(TMPFILESDIR)/packetwyrm.conf
	$(INST_MK) $(DESTDIR)$(UDEVDIR)
	$(INST) 0644 $(PKGROOT)/scripts/99-packetwyrm.rules \
	    $(DESTDIR)$(UDEVDIR)/99-packetwyrm.rules
	@echo "Installed under $(DESTDIR)$(PREFIX). Don't forget:"
	@echo "  systemd-sysusers && systemd-tmpfiles --create && systemctl daemon-reload"
	@echo "  udevadm control --reload && udevadm trigger"

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/packetwyrmd
	rm -f $(DESTDIR)$(BINDIR)/pktwyrm
	rm -f $(DESTDIR)$(LIBDIR)/libpacketwyrm.a
	rm -f $(DESTDIR)$(LIBDIR)/libpacketwyrm.so
	rm -rf $(DESTDIR)$(INCDIR)/packetwyrm
	rm -f $(DESTDIR)$(UNITDIR)/packetwyrmd.service
	rm -f $(DESTDIR)$(SYSUSERDIR)/packetwyrm.conf
	rm -f $(DESTDIR)$(TMPFILESDIR)/packetwyrm.conf
	rm -f $(DESTDIR)$(UDEVDIR)/99-packetwyrm.rules
	@echo "Note: $(DESTDIR)$(SYSCONFDIR)/packetwyrm/ left in place."
