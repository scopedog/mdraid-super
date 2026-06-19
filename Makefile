# mdraid-super — top-level build for The Lustre Collective's mdraid stack.
#
# This repo is an *assembly* repo: it carries no source of its own, only
# four submodules and this Makefile.  Clone it recursively and `make` to
# build everything needed to create and manage a raidkm (level-71) array:
#
#   kernel/   -> TheLustreCollective/mdraid   (md fork: isal_lib.ko, raid456.ko, raid_isal.ko)
#   md-kmec/  -> TheLustreCollective/md-kmec   (the raidkm personality: raidkm.ko)
#   mdadm/    -> TheLustreCollective/mdadm      (raidkm-aware mdadm)
#   lvm2/     -> TheLustreCollective/lvm2       (raidkm-aware LVM2; opt-in, see below)
#
# See README.md.  Build order matters: md-kmec links against the kernel
# fork's md headers and isa-l symbols, so `kernel` builds first.
#
# lvm2/ is NOT part of `all` — it runs lvm2's ./configure and needs
# libaio-devel + libblkid-devel; it is only used for the LVM management path.
# Build it with `make lvm2`.

TOP    := $(CURDIR)
KERNEL := $(TOP)/kernel
MDKMEC := $(TOP)/md-kmec
MDADM  := $(TOP)/mdadm
LVM2   := $(TOP)/lvm2

# Target kernel for the out-of-tree module builds (override for cross-builds).
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# Build target.  RHEL kernels carry ".el" in the release and ship a forked,
# builtin md core, so we build the whole kernel/ fork.  Everything else
# (Debian / Ubuntu / mainline) uses the distro's OWN md_mod — there we build
# ONLY isa-l from the fork (for isal_lib.ko + the EC symbols raidkm links
# against); raidkm then builds against its vendored vanilla md headers
# (md-kmec auto-detects the same way).  Override with TARGET=rhel10|vanilla.
TARGET ?= $(if $(findstring .el,$(KVER)),rhel10,vanilla)
ifeq ($(TARGET),vanilla)
KMOD           := isa-l
INSTALL_KERNEL := install-isa-l
LVM2_KMOD      := dm-raid-ko
else
KMOD           := kernel
INSTALL_KERNEL := install-kernel
LVM2_KMOD      :=
endif

.PHONY: all kernel isa-l dm-raid-ko md-kmec mdadm lvm2 modules tools install \
        install-kernel install-isa-l install-dm-raid uninstall-dm-raid clean

all: md-kmec mdadm

# Kernel md fork — produces isal_lib.ko, raid456.ko, raid_isal.ko and the
# Module.symvers that md-kmec links its EC calls against.
#
# NB: we `cd` into each submodule rather than `$(MAKE) -C`. The kernel/ and
# md-kmec/ Makefiles locate their own sources via $(PWD) (not $(CURDIR)), and
# `-C` updates make's CURDIR but not the PWD env var — so `-C` would point the
# kbuild M= at this umbrella root and silently build nothing. `cd` sets the
# real PWD, matching a standalone `cd kernel && make`.
kernel:
	cd $(KERNEL) && $(MAKE) KVER=$(KVER)

# Debian / mainline: build ONLY isa-l from the fork (isal_lib.ko +
# Module.symvers). The cp exposes the EC symbols to md-kmec's
# KBUILD_EXTRA_SYMBOLS lookup ($(MDRAID_BUILD)/Module.symvers).
isa-l:
	cd $(KERNEL)/isa-l && $(MAKE) -C $(KDIR) M=$(KERNEL)/isa-l modules
	cp -f $(KERNEL)/isa-l/Module.symvers $(KERNEL)/Module.symvers

# raidkm personality — needs isa-l/ + Module.symvers (and, on RHEL, the fork's
# md/ headers), so it depends on the target-selected kernel build ($(KMOD) =
# `kernel` on RHEL, `isa-l` on Debian/mainline). MDRAID_BUILD must be absolute
# (its default ../mdraid doesn't exist in this layout — the fork is kernel/).
md-kmec: $(KMOD)
	cd $(MDKMEC) && $(MAKE) KVER=$(KVER) MDRAID_BUILD=$(KERNEL)

# raidkm-aware mdadm — userspace, independent of the kernel build.
# -DNO_LIBUDEV keeps the build self-contained (no libudev dependency).
mdadm:
	cd $(MDADM) && $(MAKE) CXFLAGS=-DNO_LIBUDEV

# raidkm-aware LVM2 — userspace, opt-in (not in `all`).  Runs autoconf
# ./configure once (needs libaio-devel) then builds the tools.  Produces the
# from-tree lvm2/tools/lvm; do NOT `make install` it over a system whose root
# is on LVM — run it against a scratch VG with an isolated --config.
#
# On Debian/mainline the LVM path also needs the raidkm-aware dm-raid.ko (the
# distro's stock dm-raid has no "raidkm" raid_type), so $(LVM2_KMOD) = dm-raid-ko
# there; on RHEL that support is already in the kernel/ fork, so it is empty.
lvm2: $(LVM2_KMOD)
	cd $(LVM2) && test -f make.tmpl || ./configure \
	    --disable-dmeventd --disable-readline --disable-selinux \
	    --with-thin=none --with-cache=none --with-vdo=none \
	    --with-writecache=none --with-integrity=none
	cd $(LVM2) && $(MAKE)

# Debian/mainline only: build the raidkm-aware dm-raid.ko from the fork's
# dm-raid.c against the distro kernel, using md-kmec's vendored vanilla md
# headers + compat shim (the same dual-target mechanism raidkm uses).  Built in
# build/dm-raid-vanilla/ to avoid colliding with the fork's own md/ Kbuild.
# Load it in place of the stock module (see README) — it is NOT auto-installed.
DMRAID_KO_DIR := $(TOP)/build/dm-raid-vanilla
dm-raid-ko:
	@mkdir -p $(DMRAID_KO_DIR)
	cp -f $(KERNEL)/md/dm-raid.c $(DMRAID_KO_DIR)/dm-raid.c
	printf 'obj-m += dm-raid.o\nccflags-y += -I$(MDKMEC)/md-vanilla\n' > $(DMRAID_KO_DIR)/Kbuild
	$(MAKE) -C $(KDIR) M=$(DMRAID_KO_DIR) \
	    EXTRA_CFLAGS="-include $(MDKMEC)/compat/compat-vanilla.h" modules
	@echo "Built raidkm-aware dm-raid.ko -> $(DMRAID_KO_DIR)/dm-raid.ko"

# Convenience aliases.
modules: md-kmec
tools:   mdadm

# Install everything.  Needs root (modules_install + depmod, /sbin/mdadm).
#   sudo make install
# Also ENABLES the raidkm personality to autoload on boot via
# /etc/modules-load.d/raidkm.conf (depmod pulls in isal_lib through the recorded
# dependency, so just "raidkm" is enough), and loads it NOW (best-effort) so the
# install is usable without a reboot.  This does NOT install the LVM-path
# dm-raid.ko — that shadows a distro module, so it is gated behind the explicit
# `install-dm-raid` target below.
install: $(INSTALL_KERNEL)
	cd $(MDKMEC) && $(MAKE) KVER=$(KVER) MDRAID_BUILD=$(KERNEL) install
	cd $(MDADM)  && $(MAKE) install-bin
	install -d /etc/modules-load.d
	printf 'raidkm\n' > /etc/modules-load.d/raidkm.conf
	@echo "enabled: raidkm autoloads on boot (/etc/modules-load.d/raidkm.conf)"
	@if [ "$(KVER)" = "$$(uname -r)" ]; then \
	    modprobe raidkm && echo "loaded: raidkm is live now (pulled in isal_lib)" \
	      || echo "note: 'modprobe raidkm' failed — load it manually"; \
	else \
	    echo "note: installed for $(KVER), not the running $$(uname -r) — modprobe on that kernel"; \
	fi

install-kernel:
	cd $(KERNEL) && $(MAKE) KVER=$(KVER) install

install-isa-l:
	cd $(KERNEL)/isa-l && $(MAKE) -C $(KDIR) M=$(KERNEL)/isa-l modules_install
	depmod -a

# GATED (Debian/mainline only): install the raidkm-aware dm-raid.ko so the
# LVM/dm-raid path works after a plain `modprobe dm-raid`.  Run explicitly
# (`sudo make install-dm-raid`); it is deliberately NOT part of `make install`
# because it SHADOWS the distro's dm-raid module.  Installed into updates/,
# which depmod/modprobe prefer over the stock kernel/ module.  On RHEL this
# support is already in the kernel/ fork, so the target refuses to run there.
# Revert with `make uninstall-dm-raid`.  A reload (rmmod dm_raid; modprobe
# dm-raid) or reboot is needed to switch the live module.
DMRAID_UPDATES := /lib/modules/$(KVER)/updates
install-dm-raid: dm-raid-ko
	@test "$(TARGET)" = vanilla || { echo "install-dm-raid: vanilla/Debian only (RHEL ships raidkm dm-raid in the kernel/ fork)"; exit 1; }
	install -d $(DMRAID_UPDATES)
	install -m644 $(DMRAID_KO_DIR)/dm-raid.ko $(DMRAID_UPDATES)/dm-raid.ko
	depmod -a $(KVER)
	@echo "installed raidkm-aware dm-raid.ko -> $(DMRAID_UPDATES)/ (shadows the distro module)"
	@echo "  switch the live module: sudo rmmod dm_raid; sudo modprobe dm-raid"
	@echo "  revert:                 sudo make uninstall-dm-raid"

uninstall-dm-raid:
	rm -f $(DMRAID_UPDATES)/dm-raid.ko
	depmod -a $(KVER)
	@echo "removed raidkm-aware dm-raid.ko; the distro module is active again (reload or reboot)"

clean:
	-cd $(MDKMEC) && $(MAKE) clean
	-cd $(KERNEL) && $(MAKE) clean
	-cd $(MDADM)  && $(MAKE) clean
