# mdraid-super — top-level build for the scopedog mdraid stack.
#
# This repo is an *assembly* repo: it carries no source of its own, only
# four submodules and this Makefile.  Clone it recursively and `make` to
# build everything needed to create and manage a raidkm (level-71) array:
#
#   kernel/   -> scopedog/mdraid   (md fork: isal_lib.ko, raid456.ko, raid_isal.ko)
#   md-kmec/  -> scopedog/md-kmec   (the raidkm personality: raidkm.ko)
#   mdadm/    -> scopedog/mdadm      (raidkm-aware mdadm)
#   lvm2/     -> scopedog/lvm2       (raidkm-aware LVM2; opt-in, see below)
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

# Build target.  RHEL 10 kernels carry ".el10" and ship a forked, builtin md
# core, so there we build the whole kernel/ fork.  RHEL 9 (".el9"), Ubuntu
# 26.04 (kernel 7.0) and everything else (Debian / mainline) use the distro's
# OWN md core — there we build ONLY isa-l from the fork (for isal_lib.ko + the
# EC symbols raidkm links against), and raidkm compiles against its vendored
# md headers for that kernel (md-rhel9/, md-rhel98/, md-ubuntu2604/ or
# md-vanilla/) plus the matching compat shim.
#
# The release -> TARGET map is md-kmec's tools/detect-target.sh, shared with
# md-kmec's own Makefile and ABI check, and TARGET is passed down, so the two
# cannot disagree.  Override with TARGET=rhel10|rhel9|rhel98|ubuntu2604|vanilla
# — useful when KDIR points at a kernel whose release string lacks the distro
# suffix (e.g. a locally built debug kernel).
ifeq ($(origin TARGET),undefined)
TARGET := $(shell $(MDKMEC)/tools/detect-target.sh $(KVER))
endif
# Refuse, except for `make clean`, `make uninstall-dm-raid` and the userspace
# `make mdadm` / `make tools` (none needs a TARGET; the revert must work on a
# kernel we refuse, and mdadm builds everywhere): an empty TARGET (detection failed:
# md-kmec/ not checked out, or the script not executable), `unsupported`, or an
# override this file does not know.  Empty must not fall through to vanilla:
# TARGET= passed down would override md-kmec's own map.
ifneq ($(filter-out clean uninstall-dm-raid mdadm tools,$(or $(MAKECMDGOALS),all)),)
ifeq ($(TARGET),)
$(error target detection failed for kernel $(KVER): is md-kmec/ checked out and md-kmec/tools/detect-target.sh executable?  Run ./bootstrap.sh, or pass TARGET= explicitly)
endif
ifeq ($(filter rhel10 rhel9 rhel98 ubuntu2604 vanilla,$(TARGET)),)
$(error kernel $(KVER) is not supported: TARGET=$(TARGET) (md-kmec/tools/detect-target.sh).  If this kernel matches a supported one, pass TARGET= explicitly)
endif
endif
ifeq ($(TARGET),rhel10)
KMOD           := kernel
INSTALL_KERNEL := install-kernel
LVM2_KMOD      :=
else ifneq ($(filter rhel9 rhel98 ubuntu2604,$(TARGET)),)
# Distro md core, as on vanilla — only the md-kmec side differs: md-rhel9/ +
# compat-rhel9.h, md-rhel98/ + compat-rhel98.h on 9.8, or md-ubuntu2604/ +
# compat-ubuntu2604.h on Ubuntu 7.0 (md-kmec picks them from the TARGET and
# KVER we pass down).  The dm-raid/LVM path is NOT wired up here: dm-raid-ko
# builds against md-vanilla/ + compat-vanilla.h, which is wrong for these
# kernels.  Hence LVM2_KMOD is empty and dm-raid-ko refuses to run (see below).
KMOD           := isa-l
INSTALL_KERNEL := install-isa-l
LVM2_KMOD      :=
else
KMOD           := isa-l
INSTALL_KERNEL := install-isa-l
LVM2_KMOD      := dm-raid-ko
endif

.PHONY: all kernel isa-l dm-raid-ko md-kmec mdadm lvm2 modules tools install \
        install-kernel install-isa-l install-dm-raid uninstall-dm-raid clean

all: md-kmec mdadm

# Kernel md fork — produces isal_lib.ko (whose exports are prefixed isal_lib_
# so they cannot collide with another module vendoring the same ISA-L API),
# raid456.ko, raid_isal.ko and the
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
	cd $(MDKMEC) && $(MAKE) KVER=$(KVER) TARGET=$(TARGET) MDRAID_BUILD=$(KERNEL)

# raidkm-aware mdadm — userspace, independent of the kernel build.
# -DNO_LIBUDEV keeps the build self-contained (no libudev dependency).
# gcc 15 (Ubuntu 26.04) adds -Wunterminated-string-initialization, which
# mdadm's fixed-size signature arrays trip under its -Werror; older gcc
# rejects the option outright, so pass it only where the compiler knows it.
# Recursive (=), so the probe runs only when the mdadm recipe expands it.
MDADM_WERROR_PROBE = $(shell echo 'int x;' | $(CC) -Werror \
	-Wno-error=unterminated-string-initialization -x c -c -o /dev/null - \
	>/dev/null 2>&1 && echo -Wno-error=unterminated-string-initialization)
MDADM_CXFLAGS = -DNO_LIBUDEV $(MDADM_WERROR_PROBE)
mdadm:
	cd $(MDADM) && $(MAKE) CXFLAGS="$(MDADM_CXFLAGS)"

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
	@test "$(TARGET)" = vanilla || { echo "dm-raid-ko: vanilla/mainline only — it builds against md-vanilla/ + compat-vanilla.h. RHEL 10 already has raidkm dm-raid in the kernel/ fork; RHEL 9 and Ubuntu 7.0 are not wired up (would need md-rhel9/, md-rhel98/ or md-ubuntu2604/ + its compat shim)."; exit 1; }
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
	cd $(MDKMEC) && $(MAKE) KVER=$(KVER) TARGET=$(TARGET) MDRAID_BUILD=$(KERNEL) install
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
	@test "$(TARGET)" = vanilla || { echo "install-dm-raid: vanilla/mainline only (RHEL 10 ships raidkm dm-raid in the kernel/ fork; RHEL 9 and Ubuntu 7.0 are not wired up)"; exit 1; }
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
