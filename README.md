# mdraid-super

**Build/assembly repo for the scopedog mdraid stack — clone THIS to
get everything.** It contains no source of its own, only four submodules and a
top-level `Makefile` that builds them in the right order.

> Note: the `kernel/` submodule is the md kernel fork (the `mdraid` repo). It is
> *not* this repo — `mdraid-super` is the umbrella that assembles `mdraid` +
> `md-kmec` + `mdadm` + `lvm2` into one buildable tree.

## Layout

| Path        | Submodule repo                       | Role |
|-------------|--------------------------------------|------|
| `kernel/`   | `scopedog/mdraid`         | md kernel fork — builds `isal_lib.ko`, `raid456.ko`, `raid_isal.ko` (and the `Module.symvers` md-kmec links against) |
| `md-kmec/`  | `scopedog/md-kmec`        | the **raidkm** erasure-coding personality (md level 71 — k+m Reed-Solomon, m-failure durability, native per-4K checksums with checksum-driven self-healing, **declustered parity** with distributed-spare fast rebuild) — builds `raidkm.ko` |
| `mdadm/`    | `scopedog/mdadm` (`raidkm-level71`) | raidkm-aware `mdadm` for creating/managing arrays |
| `lvm2/`     | `scopedog/lvm2` (`raidkm`)          | raidkm-aware LVM2 — `lvcreate --type raidkm`, repair, dmeventd monitoring (the dm-raid/LVM management path) |

## Quick start

```sh
git clone --recurse-submodules git@github.com:scopedog/mdraid-super.git
cd mdraid-super
make
sudo make install      # installs .ko's + /sbin/mdadm, loads raidkm now, enables autoload on boot
```

`make install` loads `raidkm` immediately (best-effort, when installing for the
running kernel — pulling in `isal_lib` via depmod) and drops
`/etc/modules-load.d/raidkm.conf` so it autoloads on boot. It does **not**
install the LVM-path `dm-raid.ko` — that shadows a distro module, so it's gated
behind an explicit `sudo make install-dm-raid` (see *Via LVM* below).

If you cloned without `--recurse-submodules`, run `./bootstrap.sh` (it inits the
submodules and builds). `./bootstrap.sh install` builds and installs.

The same `make` works on **both RHEL and Debian/Ubuntu** — it auto-detects the
target from the running kernel (see *OS auto-detection* below).

### Prerequisites

**RHEL / CentOS Stream 10** (builds the full `kernel/` md fork):

```sh
sudo dnf install kernel-devel-$(uname -r) gcc make elfutils-libelf-devel openssl dwarves
```

**Debian 13 "trixie" / Ubuntu** (kernel 6.12; uses the distro's own md core):

```sh
sudo apt-get install build-essential linux-headers-$(uname -r) dwarves
```

(`mdadm` builds with `-DNO_LIBUDEV`, so no `libudev-dev` is needed. `dwarves`
provides `pahole` for the build-time `struct mddev` ABI check; if absent, the
check is skipped with a warning and the build continues.)

## Build details

- **OS auto-detection (RHEL & Debian/mainline).** `make` picks the target from
  the kernel release (override with `make TARGET=rhel10|vanilla`):
  - **RHEL** (`.el` in `uname -r`): builds the full `kernel/` md fork
    (`isal_lib.ko`, `raid456.ko`, …) then `md-kmec` against it.
  - **Debian / Ubuntu / mainline**: the distro's own `md_mod` provides md, so
    only `kernel/isa-l` is built (for `isal_lib.ko` + the `ec_encode_data*`
    symbols); `md-kmec` then compiles against its vendored vanilla `md.h`.
  `mdadm/` is independent userspace and builds either way.
- **Target kernel.** Module builds default to the running kernel
  (`uname -r`). Override with `make KVER=<version> KDIR=<path>`. You need the
  matching kernel headers (`kernel-devel` on RHEL, `linux-headers-$(uname -r)`
  on Debian).
- **ABI safety.** raidkm's `struct mddev` layout is verified against the target
  kernel's BTF at build time (`md-kmec/tools/check-mddev-abi.sh` — vmlinux BTF
  when md is builtin/RHEL, `md_mod` BTF when it's a module/Debian), so a
  mismatched header set fails the build loudly rather than corrupting at runtime.
  (For build-against-any-installed-kernel, a DKMS package would be the next
  step — not provided here.)
- **lvm2 is opt-in.** The `lvm2/` submodule is *not* part of the default `make`
  (it runs lvm2's `./configure`, and is only needed for the LVM management path,
  not for plain `mdadm` arrays). It needs extra dev packages beyond the core
  build:
  - Debian/Ubuntu: `sudo apt-get install libaio-dev libblkid-dev pkg-config`
  - RHEL: `sudo dnf install libaio-devel libblkid-devel pkgconf-pkg-config`

  Build it with `make lvm2`. **Never `make install` it over a system whose root is on LVM** —
  run the from-tree `lvm2/tools/lvm` against a scratch VG with an isolated
  `--config` instead.

## Loading and using

```sh
sudo modprobe raidkm           # pulls in isal_lib via depmod
sudo /sbin/mdadm --create /dev/md0 --level=raidkm --parity-count=2 \
     --raid-devices=6 /dev/sd[b-g]
```

`--parity-count=N` sets the number of parity disks (m). Layout defaults to
`rotating`; use `--layout=parity-last` for the non-rotating placement, or
`--layout=declustered --group-width=<k+m> [--spare-columns=<s>]` for a wide pool
whose stripe is narrower than the disk count, with a **distributed spare** that
rebuilds a failed member in parallel across the whole pool (see *Declustered
parity* below and
[`md-kmec/README.md`](../md-kmec/README.md#declustered-parity)).

### Via LVM (dm-raid path)

The `lvm2/` fork manages raidkm as an LVM segtype. After `make lvm2` (see build
notes above), the from-tree `lvm2/tools/lvm` can provision, repair and monitor
level-71 LVs:

```sh
sudo lvm2/tools/lvm lvcreate --type raidkm --paritycount 2 -i 3 -L <size> <vg>
```

`--type raidkm` is the rotating layout, `--type raidkm_n` is parity-last;
`--paritycount N` is m (2..8). `lvconvert --repair` rebuilds a failed leg onto a
spare, and `lvchange --monitor y` + dmeventd auto-repairs. Note: raidkm reshape
(growing data disks) is **not** supported through the dm/LVM path — use `mdadm`
for that.

**On Debian/mainline**, the dm-raid path needs a raidkm-aware `dm-raid.ko` — the
distro's stock `dm-raid` has no `raidkm` raid_type. Install it persistently:

```sh
sudo make install-dm-raid               # builds + installs to updates/ (shadows the stock module)
sudo rmmod dm_raid; sudo modprobe dm-raid   # switch the live module (or reboot)
```

This is **gated** (not part of `make install`) because it shadows a distro
module; revert with `sudo make uninstall-dm-raid`. For a one-off without
installing, `make lvm2` also builds it at `build/dm-raid-vanilla/dm-raid.ko` to
`insmod` directly. (On RHEL this support is built into the `kernel/` fork, so no
extra step.)

## Performance

raidkm (md level 71) is **faster than stock RAID6 on every workload**.  Measured
at m=2 (two parity disks — the RAID6-equivalent) with
`tools/raidkm-standard-benchmark.sh --runs=3`, a 6-workload OLTP/IOPS suite (page
cache dropped before each test, both arrays created `--assume-clean`), on 6 brd
ramdisks, k=4 m=2, 512 KiB chunk, **RHEL 10.2** (`6.12.0-211.22.1.el10_2`).
Re-measured 2026-06-15 across the SIMD spectrum (IOPS, mean of 3 runs;
integrity-checked, `mismatch_cnt=0` everywhere):

| Test | base / no-GFNI<br>(Ryzen 5800X) | AVX2-GFNI<br>(i5-1340P) | AVX-512-GFNI<br>(Xeon 8481C, 8 vCPU) |
|---|---|---|---|
| 1 Random 4K Write         | 239,211 vs 124,327 (**1.92×**) | 107,728 vs 46,615 (**2.31×**) | 305,853 vs 72,767 (**4.20×**) |
| 2 DB Mixed 8K (75/25)     | 420,982 vs 275,658 (**1.53×**) | 182,964 vs 96,838 (**1.89×**) | 504,563 vs 157,899 (**3.20×**) |
| 3 High Concurrency 4K rw  | 555,725 vs 410,337 (**1.35×**) | 219,223 vs 135,716 (**1.62×**) | 818,197 vs 220,291 (**3.71×**) |
| 4 OLTP 16K rw             | 222,370 vs 124,760 (**1.78×**) | 88,546 vs 42,677 (**2.07×**) | 266,346 vs 73,455 (**3.63×**) |
| 5 Partial Stripe Write 8K | 179,735 vs 73,994 (**2.43×**) | 59,135 vs 24,053 (**2.46×**) | 159,960 vs 43,837 (**3.65×**) |

(Each cell is *raidkm vs stock raid6* IOPS and the speedup.)  The win is
**structural** — the forked `raid5.c` carries worker-group auto-default, a
`STRIPE_ON_INACTIVE_LIST` lock-skip, and a faster write/RMW/partial-stripe path.

### Native checksums: verified integrity at ~no cost

raidkm's built-in per-4K CRC-32C (`mdadm --create … --checksum=crc32c`, alias `--integrity`)
verifies every read inline in the bio completion.  On real hardware (8 × local
NVMe SSD, m=2, fio direct iodepth=32; percentages vs the same array with
checksums off):

| Workload | no checksum | **native checksum** | dm-integrity journal | dm-integrity bitmap |
|---|---|---|---|---|
| Seq write (MB/s)  | 2245 | **2264 (101%)** | 1088 (48%) | 2230 (99%) |
| Rand write (K IOPS) | 97.2 | **93.2 (96%)** | 40.8 (42%) | 78.5 (81%) |
| Seq read (MB/s)   | 5626 | **5599 (99.5%)** | 5624 (100%) | 5014 (89%) |
| Rand read (K IOPS) | 1236.2 | **1235.9 (100.0%)** | 978.0 (79%) | 934.4 (76%) |

Ahead of dm-integrity bitmap on all four workloads, ahead of journal on writes
and random read, tying it on sequential read — with zero false mismatches.
(Journal is crash-atomic, a stronger guarantee than native/bitmap, which
recompute checksums after an unclean shutdown.)  Full setup + design:
`md-kmec/README.md` and `md-kmec/notes/native-checksum-read-redesign-2026-07-14.md`.

**Real-NVMe re-gated (2026-07-15)** on 4K-logical local-SSD NVMe under a KASAN +
lockdep kernel — functional 12/12, csum-thrash, self-heal 60/60, randrw churn
0 WARNs, 0 splats. The re-gate found and fixed a `skip_copy` × native-checksum
read/write invariant `WARN_ON` (a read overlapping a draining zero-copy write is
now deferred in `need_this_block`), plus two 4K-logical-device harness bugs.

> The ratio **scales with core count**; it is not a fixed per-machine constant.
> raidkm's worker groups parallelize stripe handling (total threads auto-default
> to `nproc/2`) while stock RAID6's RMW path is largely serial.  At m=2 parity is
> the `raid6_call` P+Q fast path, so **GFNI does not change the m=2 numbers** — the
> three columns differ as much by vCPU count as by SIMD tier; GFNI's encode
> advantage shows at **m ≥ 3**.  brd is RAM-backed, so these isolate the CPU-side
> win; real disks narrow the gap on device-bound workloads.

### Rebuild / resync

raidkm rebuilds a failed disk **substantially faster** because its resync path
fans multiple stripes per `sync_request` instead of walking one stripe-window at
a time.  Single-disk recovery, 6 × brd, k=4 m=2, 3 GiB/disk, GCP `c3-standard-8`
(8 vCPU, Xeon 8481C), resync governor unthrottled:

| `group_thread_cnt` | stock raid6 | raidkm m=2 |
|---|---|---|
| 0 (stock default) | ~200 MB/s | **1178 MB/s** (5.9×) |
| 4 (matched)       | ~585 MB/s | **1178 MB/s** (2.0×) |

raidkm's rebuild rate is **independent of `group_thread_cnt`** (the parallelism
is in the sync path itself): ~2× apples-to-apples at matched `gtc=4`, ~6× out of
the box (stock ships worker groups off).  *(brd is compute-bound; on real disks
the rebuild is capped by write bandwidth, so the gap narrows.)*

Full detail — per-core scaling, `worker_thread_cnt` tuning, and the reproduction
recipe — is in
[`md-kmec/README.md`](../md-kmec/README.md#benchmark--raidkm-vs-stock-raid6).

### Declustered rebuild (wide pools)

For **wide** pools, the bigger rebuild win comes from `--layout=declustered`: a
narrow `k+m` stripe is scattered over the whole disk pool with a **distributed
spare**, so a failed member is reconstructed across *every* survivor at once
instead of funnelling through one replacement. On real NVMe, rebuilding a failed
16 GB member on an **80-disk pool (g=13, i.e. 11+2)** took **44.9 s** vs
**785.1 s** for a classic 78+2 array — **17.5×** — and the array is never fully
degraded during it. Adding the replacement later migrates the data back by a
parallel **copy-from-spare** (no decode, no degraded window). **Native checksums
compose** with declustering — the CRC region stacks after the on-disk geometry
block, CRCs are keyed by physical disk (so spare-redirected reads still verify),
and the copy-from-spare rebalance migrates each block's CRC with the bytes. Full
mechanism, create syntax, and `rk_dcl_populate` / auto-rebuild usage:
[`md-kmec/README.md`](../md-kmec/README.md#declustered-parity).

## Tools & tests

`tools/` (a symlink to `md-kmec/tools/`) collects the raidkm helper and test
scripts. After a build + `sudo make install` (or with the modules loaded), run
them as `sudo bash tools/<script>` — set `MDADM=$(pwd)/mdadm/mdadm` to use the
from-tree mdadm:

| Script | What it does |
|--------|--------------|
| `raidkm-test-functional.sh` | mdadm create / write / read-back / scrub smoke (12 cases) |
| `raidkm-test-dm-rebuild.sh`, `raidkm-test-dm-reshape.sh` | the dm-raid / LVM path (rebuild, reshape) |
| `raidkm-test-degraded.sh`, `raidkm-test-replace.sh` | degraded reads, failed-leg replace |
| `raidkm-test-selfheal.sh` | checksum-driven self-healing — reconstruct silent corruption from parity, to m=8 (`NATIVE=1` = built-in checksums; default stacks `dm-integrity`, needs `integritysetup`) |
| `raidkm-test-csum-thrash.sh` | native-checksum region-cache eviction round-trip (no false mismatch / no lost CRC under cache pressure; `NATIVE=1`) |
| `raidkm-test-declustered-*.sh` | declustered parity — map/create, populate (rebuild into distributed spare), rebalance (copy-from-spare), sequential multi-assignment, auto-arm, native-checksum composition (`-csum`, incl. copy CRC migration), dm-flakey crash matrices |
| `raidkm-test-grow*.sh`, `raidkm-test-reshape-*.sh` | grow/reshape (data + parity) |
| `raidkm-test-soak.sh`, `raidkm-test-crash.sh` | soak and crash-consistency |
| `raidkm-standard-benchmark.sh` | throughput benchmark |
| `raidkm-create.sh`, `raidkm-convert.sh` | create / convert helpers |
| `check-mddev-abi.sh` | build-time `struct mddev` / `bitmap_ops` ABI guard |

## Updating pinned versions

Submodules are pinned to specific commits for reproducible builds. To advance
them to their tracked branch tips:

```sh
git submodule update --remote
git add kernel md-kmec mdadm lvm2
git commit -m "bump submodules"
```

Tracked branches: `kernel`→`master`, `md-kmec`→`master`,
`mdadm`→`raidkm-level71`, `lvm2`→`raidkm`.
