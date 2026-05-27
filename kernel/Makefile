# Out-of-tree build for the PacketWyrm kernel skeleton.
# Requires linux-headers for the running kernel:
#   sudo apt install linux-headers-$(uname -r) build-essential
#
# Build:    make
# Clean:    make clean
# Install:  sudo make modules_install   (puts it in /lib/modules/...)

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

.PHONY: all clean modules_install

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

modules_install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
