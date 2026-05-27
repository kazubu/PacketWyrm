# PacketWyrm host-side build.
#
# - libpacketwyrm: static + shared library
# - packetwyrmd:   daemon (Phase 0 dry-run skeleton)
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

EXTRA_CFLAGS := $(YAML_CFLAGS) $(JSON_CFLAGS)
EXTRA_LIBS   := $(YAML_LIBS) $(JSON_LIBS)

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

TEST_SRC := tests/unit/test_main.c
TEST_BIN := $(BUILD_DIR)/test_unit

INCLUDES := -I$(LIB_INC) $(EXTRA_CFLAGS)

.PHONY: all clean test daemon cli lib
all: lib daemon cli

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

%.o: %.c
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<

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
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(CLI_SRC) $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

test: $(TEST_BIN)
	$(TEST_BIN)

$(TEST_BIN): $(TEST_SRC) $(LIBA) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(TEST_SRC) $(LIBA) $(EXTRA_LIBS) $(LDFLAGS)

clean:
	rm -f $(LIB_OBJ)
	rm -rf $(BUILD_DIR)
