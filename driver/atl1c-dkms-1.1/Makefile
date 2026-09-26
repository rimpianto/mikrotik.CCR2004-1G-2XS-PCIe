# SPDX-License-Identifier: GPL-2.0-only
obj-m += atl1c.o
atl1c-objs := atl1c_main.o atl1c_hw.o atl1c_ethtool.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
