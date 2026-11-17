# mdraid-super

**Build/assembly repo for the scopedog mdraid stack — clone THIS to
get everything.** It contains no source of its own, only four submodules and a
top-level `Makefile` that builds them in the right order.

> Note: the `kernel/` submodule is the md kernel fork (the `mdraid` repo). It is
> *not* this repo — `mdraid-super` is the umbrella that assembles `mdraid` +
> `md-kmec` + `mdadm` + `lvm2` into one buildable tree.

## Layout

| Path        | Submodule repo / target              | Role |
|-------------|--------------------------------------|------|
| `kernel/`   | `scopedog/mdraid`         | md kernel fork — builds `isal_lib.ko`, `raid456.ko`, `raid_isal.ko` (and the `Module.symvers` md-kmec links against). `isal_lib.ko`'s exports carry an `isal_lib_` prefix so it cannot collide with another module vendoring the same ISA-L API |
| `md-kmec/`  | `scopedog/md-kmec`        | the **raidkm** erasure-coding personality (md level 71 — k+m Reed-Solomon, m-failure durability, native per-4K checksums with checksum-driven self-healing, **declustered parity** with distributed-spare fast rebuild) — builds `raidkm.ko` |
| `mdadm/`    | `scopedog/mdadm` (`raidkm-level71`) | raidkm-aware `mdadm` for creating/managing arrays |
| `lvm2/`     | `scopedog/lvm2` (`raidkm`)          | raidkm-aware LVM2 — `lvcreate --type raidkm`, repair, dmeventd monitoring (the dm-raid/LVM management path) |
| `docs/`     | symlink → `md-kmec/docs/`            | the raidkm **field manual** — feature catalogue, layout maps, and a task-ordered command reference ([`docs/raidkm-field-manual.md`](docs/raidkm-field-manual.md)) |
| `tools/`    | symlink → `md-kmec/tools/`           | raidkm helper and test scripts (see *Tools & tests* below) |

## What md-kmec (raidkm) gives you

`raidkm` is the md personality this stack exists to ship: **md level 71**, a fork
of our optimized `raid5.c` plus our ISA-L fork's erasure-coding primitives.  All
of the below is implemented and gated by the test suite in `tools/`; measured
numbers are in *Performance* further down, and the full design/validation detail
for each item is in [`md-kmec/README.md`](../md-kmec/README.md#status).

### Erasure coding: arbitrary *k* + *m*

- **Any parity count m, not just 2.** `--parity-count=N` gives an array that
  survives **N simultaneous disk losses** (m = 2…16; mdadm's help documents the
  common 2–8 range).  m=2 is the RAID6-equivalent case; m≥3 is something stock
  md cannot do at all.  Array width is bounded by the GF(2⁸) field, `k+m ≤ 255`,
  and is validated in practice out to **80-disk** arrays.
- **One code for every m.** Parity is ISA-L's Reed-Solomon code (Vandermonde,
  `gf_gen_rs_matrix`, to m=3; Cauchy above), so the m=2 image is a valid
  *prefix* of the m=3 encoding — that is what makes adding a third parity an
  incremental operation rather than a rewrite.  Above m=3 the Cauchy rows share
  no prefix (not even an all-ones P), and a change of m re-encodes the parity.
- **m=2 is byte-identical to RAID6.** At m=2 the code's first two rows are
  exactly RAID6's P and Q, so raidkm encodes m=2 with raid6's tuned SIMD
  (`raid6_call`) for full speed while writing bytes a stock RAID6 would write
  (the exception is a declustered group of width 3: with k=1 a stripe has
  fewer disks than md's async P+Q helpers accept, so ISA-L encodes, updates
  and scrubs it, writing the same bytes).
  That also makes **offline raid6 ↔ raidkm conversion** possible in place
  (`tools/raidkm-convert.sh`, `mdadm --raidkm-convert` — rotating layout, m=2:
  it rewrites the superblock, not the data).
- **GFNI-accelerated, PSHUFB-free decode.** Every degraded read, rebuild and
  degraded write goes through one unified decode (build the survivor matrix,
  `gf_invert_matrix`, apply the decode row), using AVX-512/AVX2 **GFNI** when
  the CPU has it, else ISA-L's scalar table-lookup code — except for the common
  single-failure rows, which need no table: a row of 0/1 coefficients (a data
  block from the other data and P, or P itself) runs as a plain `xor_blocks`
  XOR, and a lost Q at m=2 (k≥2) through raid6's `gen_syndrome`
  (`fast_decode` module parameter, default on only without GFNI).  More than
  one lost block, a lost Q or R at m=3 and every row at m≥4 (a Cauchy
  generator, with no all-ones P row) still use the table.  Decode deliberately
  avoids raid6's `*_recov` and ISA-L's PSHUFB kernels, keeping clear of the
  StreamScale patent surface.

### Parity placement: three layouts

- **`--layout=rotating` (default)** — generalized left-symmetric: the m-block
  parity slot rotates one disk per stripe, so parity and read traffic spread
  across every member (stock RAID6's own default shape).
- **`--layout=parity-last`** — dedicated parity on the tail m disks; data lives
  on a fixed prefix and never moves, which keeps the cheap offline add-a-parity
  grow available.
- **`--layout=declustered`** — a narrow `k+m` group scattered over a much wider
  pool by a seeded balanced permutation, with **distributed spare** columns
  instead of a dedicated hot spare.  Capacity balance is exact by construction,
  rebuild load is rotation-symmetric, and the geometry (`--group-width`,
  `--spare-columns`, seed) persists in a per-member `rkdcl` metadata block.
  Clean-room combinatorics — dRAID *lineage*, no OpenZFS/CDDL code.

### Fast rebuild

- **Row rebuild.** A classic rebuild onto a spare reads each chunk from the
  survivors, decodes it once and writes it to the spare as one chunk-sized
  write, 16 rows at a time, instead of 4 KiB stripes.  On an idle array it
  rebuilds at 1.04× stock md tuned to the same knobs on 0.7× its cores; under a
  foreground read it serves 2.7× tuned stock's read while rebuilding at 0.74×
  its rate (see *Performance*).  How the rebuild shares a busy array is a
  choice: `rk_row_rebuild_workers` sets how many rows rebuild at once (16 by
  default; more rows buy rebuild rate with foreground IOPS where the drives have
  headroom), and `rk_row_rebuild_pace` caps the rebuild in KB/s while foreground
  I/O is present — which md's own `sync_speed_min` cannot do on this path,
  because it throttles by waiting for outstanding sync I/O that a finished band
  no longer has.  The engine also runs a look-ahead window ahead of md's cursor
  (`rk_row_rebuild_window`, 64 chunks by default; 0 restores the synchronous
  bands) instead of idling for every round trip through md's sync loop.
- **Declustered rebuild.** With a distributed spare, a failed member is
  reconstructed across *every* survivor at once instead of funnelling into one
  replacement disk, and the array is never fully degraded while it happens.  At
  the same usable capacity as stock 8+2 on 10 of the 12 disks, a 12-disk
  declustered pool rebuilds 1.65× faster than tuned stock when idle, and 1.03×
  faster under a foreground read while serving 2.2× tuned stock's read.
  Population is a raidkm-owned sync action (`rk_dcl_populate`, or automatic via
  `rk_dcl_auto=1`) with a crash-safe journaled progress mark, and supports
  **sequential multi-assignment** (up to `s` failed disks, resolved through
  chained redirects).  It runs on the row-rebuild workers (`rk_dcl_row_rebuild`,
  on by default), so each row's spare column is written whole in chunk-sized
  writes instead of 4 KiB stripes.
- **Foreground writes are not left parked by the preread throttle.**  md parks a
  stripe that needs prereads on `delayed_list` until no preread is active
  anywhere, which a saturating O_DIRECT load prevents for as long as it lasts —
  so a write that lands on a stripe whose preread token an earlier write already
  spent can wait for the load to end, and anything overlapping it waits too.
  Two guards, both on by default: a stripe carrying a pending `REQ_SYNC` write
  takes the token instead of being parked (`sync_write_nodelay`), and anything
  else parked is activated after `delayed_max_age_ms` (100 ms) even while
  prereads are active — a backstop rather than a deadline.
- **Rebalance by copy, not decode.** Adding a replacement disk migrates the data
  back with a 16-worker parallel **copy-from-spare** — no GF decode, no degraded
  window — falling back to the decode leg on any persistent copy fault.

### Integrity: native checksums and self-healing

- **Native per-4K CRC-32C** (`mdadm --create … --checksum=crc32c`) — raidkm
  computes, stores and verifies a checksum for every 4 KiB block itself, with no
  dm-integrity stacking.  CRCs live in a reserved region at each member's tail
  (~0.1% of capacity) in self-checking pages, served through a bounded
  demand-paged cache; reads verify **inline in the bio completion**, including a
  verified chunk-aligned read bypass.  In the 2026-11-13 run, turning them on
  cost each layout at most 5% of its own throughput and rebuild rate, and the
  declustered layout *with* checksums still clears tuned stock, which verifies
  nothing, on every item (see *Performance*).
- **Checksum-driven self-healing.** An integrity-flagged read becomes an
  *erasure*: the block is reconstructed from parity and rewritten, on both the
  read path and the m-way scrub, with mixed data+parity corruption healed in one
  pass.  Validated healing **8 silent corruptions in a single stripe** (m=8) —
  beyond RAID-Z3's three.  A `healed_blocks` sysfs counter reports repairs.  The
  detection signal can be native checksums, a stacked `dm-integrity`, or (next)
  T10-PI passthrough.
- **Composes with declustering** — CRCs are keyed by *physical* pool disk, so a
  spare-redirected read still verifies, and the copy-from-spare rebalance migrates
  each block's CRC along with its bytes.

### Online reshape — grow *and* shrink, crash-safe, no backup file

All of these run with the array **readable and writable**, and a power loss is
recovered by a plain `mdadm --assemble` replaying the in-kernel journal
([details](../md-kmec/README.md#grow)):

| Command | Effect |
|---|---|
| `--grow --add-data <disks>` | add data disk(s) — more capacity, m fixed (both classic layouts) |
| `--grow --raid-devices=<N-1>` | remove a data disk — shrink capacity, m fixed (clamp `--array-size` first; mdadm prints the value) |
| `--grow --add-parity <disks>` | raise m, k fixed — online COW reshape on rotating; cheap offline recreate on parity-last |
| `--grow --remove-parity` | lower m (≥2 remain), k and capacity fixed — online COW re-encode |
| `--grow --raid-devices=N'` (declustered) | grow **or** shrink the pool by whole groups, distributed spare intact |
| `--grow --add-parity` / `--add-data` / `--spare-columns=s'` (declustered) | change the per-group geometry online, serving the un-migrated region with old-geometry stripes |

The engine is a journaled **copy-on-write** reshape: each band is staged
out-of-place and STAGE→COMMIT→DONE journaled before its home is overwritten, so
no live block is ever overwritten before its replacement is durable.  Shrinks
walk the same engine **backwards**.  Native-checksum arrays reshape too (CRCs are
re-keyed with the data).  Freed members drop out as spares.

### Native snapshots and the row state map

- **Row state map** (`mdadm --create … --row-map`, a create option) — raidkm
  keeps a 2-bit state per row (unwritten / needs sync / written) in a small
  reserve at each member's tail, so a new array needs no initial resync, and
  rebuild, resync and check skip the rows that hold no data.  On a live array,
  `/sys/block/mdX/md/rk_rowmap` shows the row counts per state and what the
  passes skipped.
- **Native read-only snapshots** (`mdadm --create … --snapshots=<reserve %>`,
  implies `--row-map`) — the array exports (100 − reserve)% of its rows, and the
  first write to a row a snapshot still shares is redirected, whole, to a reserve
  row: a full-row write goes there as it is, a partial one is merged into a copy
  of the old row.  No thin-pool layer and no second metadata device.  Snapshots
  form a linear chain, each a read-only block device `/dev/mdXs<id>`; a create
  freezes a mounted filesystem for its consistent point.
- **Crash safe** — every change goes to a journal on each member before the
  write that needed a copy is acknowledged; checkpoints, and a replay at
  assemble, bring the snapshots back after a stop, crash or power cut
  (power-cut tested: every snapshot's content survives every cut, degraded
  too).  When the reserve is full, a write that needs a copy fails with ENOSPC
  and the snapshots stay intact.  Opt-in: an array created without
  `--snapshots` is unchanged.  Declustered pools included (the copy unit is a
  whole declustered row, every group's data), and so are native checksums
  (`--checksum`: mdadm zeroes the CRC region at create and `--add`, and the
  CRCs of trimmed rows come off it before the members get a discard).  Not
  yet with a reshape.  `/sys/block/mdX/md/rk_snap` shows the origin and reserve rows,
  the copy and journal counters and the snapshots; each snapshot disk has its
  own `/sys/block/mdXs<id>/rk_snap/`.

| Command | Effect |
|---|---|
| `mdadm --snapshot <array> --create <name> [--attr k=v]...` | take a snapshot, with attributes |
| `mdadm --snapshot <array> --destroy <name>` | remove it; its rows go back to the reserve (and unwritten in the row map) |
| `mdadm --snapshot <array> --rename <old> <new>`, `--set <name> k=v...` | rename it, set attributes |
| `mdadm --snapshot <array> --list [<name>] [--export]`, `--exists <name>` | list (name, id, ctime, device, rows held, attributes); test |
| `mdadm --snapshot <array> --checkpoint` | write a checkpoint now |

On a RAM-backed 8+2 array with 128 KiB chunks, against dm-thin over a plain
raidkm array on the same members (thin block = one row), the first write pass
after a snapshot is faster than dm-thin's — ~10% more IOPS on 4 KiB random
writes, ~35% more throughput on 1 MiB sequential writes — with the same member
bytes; later passes run as without a snapshot.  States, limits, the on-disk
layout and space are in
[`md-kmec/README.md`](../md-kmec/README.md#row-state-map-and-native-snapshots).

### Degraded operation and repair

Degraded reads, degraded **writes**, and degraded scrub all work up to m
failures; hot-replace rebuilds a failed member onto a spare (data by decode,
parity by re-encode), including rebuild-while-still-degraded.  A **write-intent
bitmap** works out of the box (a `--re-add` after an unclean shutdown resyncs
only the dirty region — seconds instead of minutes); it is the default
consistency policy and the only one supported at every m and layout.  It
narrows the write hole to that resync but does not close it: a crash followed
by a lost member before the resync finishes can corrupt untouched blocks of
the stripes being written, and md refuses to start such a dirty degraded array
unless forced.  The md write journal (`--write-journal`) closes the hole at
m=2 on a rotating or parity-last array; it is refused at m>2 and on a
declustered pool.  **PPL** (partial parity log) is refused on raidkm
(2026-11-16): the m-parity extension lost acknowledged writes in power-cut
testing.  An array created with PPL by an earlier module assembles with
`mdadm --assemble --update=no-ppl`.

### Performance defaults you get for free

Worker groups are **auto-enabled** (total threads default to `nproc/2`, spread
one group per NUMA node) and zero-copy full-stripe writes (`skip_copy`) default
**on** — stock md ships both off.  On a healthy array, stock md with the same
knobs set by hand keeps up with raidkm rotating.  raidkm's own gains are
degraded reads, the foreground throughput it keeps while rebuilding, and —
declustered — the rebuild rate (1.65× idle) and, from working the two drives
the others leave idle, a healthy-array lead of up to 1.17× (see *Performance*).
Tunables: `worker_thread_cnt` / `group_thread_cnt`, `stripe_cache_size`, and the
`raidkm_csum_cache_pages` module parameter; the deployment checklist (pick `k`
so `k × chunk` is a power of two, keep the filesystem journal off the array,
align the partition to a row) is in
[`md-kmec/README.md`](../md-kmec/README.md#tuning).

### Management paths

`mdadm` (create / assemble / grow / shrink / convert), raw **device-mapper**
(`dmsetup create … raid raidkm …`, no new dm target), and **LVM**
(`lvcreate --type raidkm` / `raidkm_n`, `lvconvert --repair`, dmeventd monitoring
and auto-repair).  Reshape is mdadm-only — the dm/LVM path is gated off for it.

### Portability and assurance

One source tree builds against **RHEL 10** (forked builtin md core), **RHEL 9**
(distro `md_mod`, vendored 5.14 headers) and **mainline/Debian**, selected
automatically, with a build-time `struct mddev` BTF/ABI guard so a mismatched
header set fails loudly instead of corrupting at runtime.  The stack is gated on
real NVMe under **KASAN + lockdep** (zero splats) as well as on ramdisks, with
dedicated power-loss and torn-write crash matrices (dm-flakey plus a fault-inject
build) for every reshape, population and rebalance path.

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

The same `make` works on **RHEL 9, RHEL 10, Ubuntu and Debian** — it auto-detects the
target from the running kernel (see *OS auto-detection* below).

### Prerequisites

**RHEL / CentOS Stream 10** (builds the full `kernel/` md fork):

```sh
sudo dnf install kernel-devel-$(uname -r) gcc make elfutils-libelf-devel openssl dwarves
```

**RHEL 9** (kernel 5.14; uses the distro's own md core):

```sh
sudo dnf install kernel-devel-$(uname -r) gcc make elfutils-libelf-devel openssl dwarves
```

**Ubuntu 26.04** (kernel 7.0; the flavours listed below) and **Debian 13
"trixie"** (kernel 6.12); both use the distro's own md core:

```sh
sudo apt-get install build-essential linux-headers-$(uname -r) dwarves
```

(`mdadm` builds with `-DNO_LIBUDEV`, so no `libudev-dev` is needed. `dwarves`
provides `pahole` for the build-time `struct mddev` ABI check; if absent, the
check is skipped with a warning and the build continues.)

## Build details

- **OS auto-detection.** `make` picks the target from the kernel release and
  passes it down to `md-kmec`, so the two cannot disagree (both use
  `md-kmec/tools/detect-target.sh`).  Override with
  `make TARGET=rhel10|rhel9|rhel98|ubuntu2604|vanilla` — useful when `KDIR` points at a
  kernel whose release string lacks the distro suffix (a locally built debug
  kernel, say).
  - **RHEL 10** (`.el10`): ships a forked, builtin md core, so the full
    `kernel/` md fork is built (`isal_lib.ko`, `raid456.ko`, …) and `md-kmec`
    compiles against it.
  - **RHEL 9** (`.el9`): the distro's own `md_mod` provides md, so only
    `kernel/isa-l` is built; `md-kmec` compiles against its vendored headers
    for the release — `md-rhel9/` + `compat-rhel9.h` on 9.7, `md-rhel98/` +
    `compat-rhel98.h` on 9.8 (9.8 moved `struct mddev`), picked by `md-kmec`
    from the kernel release (`.el9_8`) within `TARGET=rhel9`; a 9.8-based
    kernel without that suffix (CentOS Stream 9 `5.14.0-687.el9`, a local
    build) takes `TARGET=rhel98`.  The ABI check below verifies whichever set
    was picked.  Validated under KASAN + lockdep.
  - **Ubuntu 26.04** (`7.0.0-<abi>-<flavour>`: generic, aws, azure,
    azure-fde, gcp, gke, ibm, oracle, vmware, oem, nvidia, nvidia-bos): same
    shape as RHEL 9 — md core is builtin and stock, so only `kernel/isa-l` is
    built and `md-kmec` compiles against its vendored stock 7.0 headers
    (`md-ubuntu2604/`).  Any other 7.x kernel, the `realtime` (PREEMPT_RT)
    flavour included, is refused.
  - **Debian / Ubuntu before 26.04 / mainline**: same shape as RHEL 9 — distro `md_mod`,
    only `kernel/isa-l` built, `md-kmec` against its vendored vanilla `md.h`.

  `mdadm/` is independent userspace and builds on all of them (on gcc 15 the
  Makefile adds `-Wno-error=unterminated-string-initialization` for it).  The dm-raid/LVM
  path is wired up for RHEL 10 (in the `kernel/` fork) and mainline
  (`dm-raid-ko`), but **not** for RHEL 9 or Ubuntu 26.04 — `dm-raid-ko` builds
  against `md-vanilla/`, which is wrong there, so it refuses to run rather
  than produce a mismatched module.
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

### If `modprobe raidkm` fails with a duplicate symbol

Other out-of-tree modules vendor the same ISA-L erasure-coding port that
`isal_lib.ko` carries, and export it under the upstream ISA-L names.  Because
the kernel matches exported symbols by bare name, whichever module loads second
is rejected outright:

```
[  138.102767] isal_lib: exports duplicate symbol ec_encode_data_avx2_gfni (owned by ec)
insmod: ERROR: could not insert module isal_lib.ko: Invalid module format
```

`isal_lib.ko`'s 33 exports now all carry an `isal_lib_` prefix, so it coexists
with such a module and the two load in any order.  If you still see the error
above, the `kernel/` (mdraid) submodule predates the prefix — update the
submodule rather than blacklisting the other module.  Verify with:

```sh
lsmod | grep isal_lib
```

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

### Current release vs tuned stock (2026-11-13)

Stock md tuned by hand to raidkm's knobs (`group_thread_cnt=8`,
`stripe_cache_size=1024`, `skip_copy=1`) against raidkm in both layouts, on the
same 12 disks at **the same usable capacity**: stock 8+2 on 10 members with the
other two left idle (the capacity a pair of hot spares would hold), raidkm
rotating 8+2 likewise, and raidkm declustered 8+2 over all 12 with two
distributed spare columns (so declustering works 12 drives where the others work
10 — the point of a distributed spare).  The rebuild items fail the last member;
the 10-member arms then wipe it and add it back, a full recovery onto a blank
disk as onto a spare, and the declustered arm populates its spare columns.  GCP
`n2-standard-32`, 12 × 16 GiB of local NVMe, Rocky 10 kernel `6.12.0-211.74.1`,
md-kmec `8c9a6d3` at its shipping defaults, no `--checksum` (declustered
population on the row engine and both preread guards were already on by default
there; on the no-checksum data path the md-kmec pinned here adds fast
decode, which on CPUs without GFNI speeds raidkm's degraded reads and
declustered population and cuts its rotating rebuild CPU, and an ISA-L path for
declustered groups of width 3 at m=2, which this 8+2 run does not use; this
instance was a Cascade Lake without GFNI, so the pinned release should do
better on the degraded-read items, use fewer rebuild cores and may rebuild
declustered arrays faster), preconditioned to steady state, a discarded warm-up
pass, 2 ABBA rounds, `tools/raidkm-ab-benchmark.sh
--arms=raid6@10+tuned,raidkm2@10,dcl2 --degraded --rebuild
--rebuild-load=seqread`.

| | tuned stock | raidkm rotating | raidkm declustered | best vs tuned stock |
|---|---|---|---|---|
| Random 4K write, IOPS | 118,190 | 121,449 | 127,276 | **1.08×** |
| 70/30 4K, 16 jobs, IOPS | 263,820 | 260,341 | 280,075 | **1.06×** |
| OLTP 70/30 16K, IOPS | 79,736 | 79,257 | 93,044 | **1.17×** |
| Sequential 1 MiB write, MiB/s | 2,721 | 2,758 | 2,917 | **1.07×** |
| Sequential 1 MiB read, MiB/s | 5,329 | 5,458 | 5,815 | **1.09×** |
| Degraded sequential 1 MiB read, MiB/s | 4,561 | 4,981 | 5,591 | **1.23×** |
| Degraded random 4K read, IOPS | 176,087 | 254,272 | 289,080 | **1.64×** |
| Rebuild, idle array, MiB/s | 370 | 384 | 610 | **1.65×** |
| Rebuild under a sequential read, MiB/s | 324 | 239 | 335 | **1.03×** |
| … and the foreground read, MiB/s | 1,247 | 3,400 | 2,740 | |

- **Every item:** the better layout is at least tuned stock on all of them,
  both rebuild items included.
- **Rotating** matches tuned stock on a healthy array (0.99–1.03×), leads it
  1.09–1.44× degraded, and rebuilds an idle array at 1.04× on 0.7× the cores;
  under a foreground read it serves 2.7× tuned stock's read and rebuilds at
  0.74× its rate.
- **Declustered** leads on every item, 1.03–1.65×.

**With `--checksum=crc32c`**, raidkm verifies every block it reads and tuned
stock verifies none.  This is a separate run of five arms — tuned stock, both
layouts without checksums and both with them — on a second instance of the same
type, with md-kmec `8c9a6d3` plus its first two checksum CPU fixes (row CRCs
computed outside the CRC cache's lock; raidkm's own `crc32c` transform, since
RHEL's built-in libcrc32c stays on the generic CRC), so as above, declustered
population ran on the row engine and both preread guards were on by default.
The md-kmec pinned here carries one more checksum fix since (row CRC
lookups first, so only blocks with a stored CRC are CRC'd), which these
numbers predate and which only removes work, plus fixes to the benchmark
tool's error handling for `-csum` arms (a member it cannot size, an mdadm
without `--checksum`) that landed after this run and do not change how
the arms are built, fast decode, which on CPUs without GFNI speeds raidkm's
degraded reads and declustered population and cuts its rotating rebuild CPU
(this instance was a Cascade Lake without GFNI too, so the same holds as
above), and an ISA-L path for declustered groups of width 3 at m=2, which this
run does not use either.  Every ratio below is against *this* run's tuned
stock, so compare its columns with each other, not with the table above: an
instance of the same type is not the same machine.  Same capacity-equalised
arms, members and options as above: `tools/raidkm-ab-benchmark.sh
--arms=raid6@10+tuned,raidkm2@10,raidkm2-csum@10,dcl2,dcl2-csum --degraded
--rebuild --rebuild-load=seqread`.

| | rotating | rotating + csum | declustered | declustered + csum |
|---|---|---|---|---|
| Random 4K write | 0.99× | 0.96× | **1.06×** | **1.01×** |
| 70/30 4K, 16 jobs | **1.00×** | 0.97× | **1.06×** | **1.02×** |
| OLTP 70/30 16K | 0.97× | 0.97× | **1.13×** | **1.14×** |
| Sequential 1 MiB write | **1.00×** | **1.00×** | **1.00×** | **1.00×** |
| Sequential 1 MiB read | 0.98× | **1.00×** | **1.09×** | **1.08×** |
| Degraded sequential read | **1.09×** | **1.10×** | **1.21×** | **1.23×** |
| Degraded random 4K read | **1.45×** | **1.45×** | **1.66×** | **1.65×** |
| Rebuild, idle array | **1.04×** | **1.04×** | **1.75×** | **1.74×** |
| Rebuild under a read | 0.78× at 2.57× the read | 0.78× at 2.59× | **1.12×** at 2.14× | **1.07×** at 2.27× |

Within this run, checksums cost at most 5% of each layout's throughput and
rebuild rate — several items land inside noise either way — on up to one core
more; with them on, declustered still clears tuned stock on every item.
Every workload, p99 latency, busy cores and the per-round runs, in
`md-kmec/README.md`: [without checksums](../md-kmec/README.md#current-release-vs-tuned-stock-both-layouts-2026-11-13),
[with them](../md-kmec/README.md#with---checksum-against-tuned-stock-2026-11-13).

### Declustered rebuild (wide pools)

The rebuild win comes from `--layout=declustered`, and its I/O spread grows with
the pool: a narrow `k+m` stripe is scattered over the whole disk pool with a
**distributed spare**, so a failed member is reconstructed across *every*
survivor at once instead of funnelling through one replacement, and the array
is never fully degraded during it.  In the 2026-11-13 run above, a 12-disk
declustered pool rebuilt 1.65× faster than tuned stock when idle; no wider pool
has been timed against the current release.  The gain follows from *where the
rebuild I/O lands*: a classic rebuild funnels every reconstructed byte onto the
one spare, while declustered spreads it across the pool.  Per-disk I/O counters
(`md-kmec/tools/raidkm-bench-declustered-rebuild-load.sh`, device-count-
independent) show the busiest disk's rebuild write drop by **14×/42×/85×** at
N=14/42/80 (≈ pool width), and copy-from-spare reads **5×/9×/13×** fewer survivor
bytes than a decode rebuild (≈ group width − 1). Adding the replacement later
migrates the data back by that parallel **copy-from-spare** (no decode, no
degraded window). **Native checksums compose** with declustering — the CRC
region stacks after the on-disk geometry block, CRCs are keyed by physical disk
(so spare-redirected reads still verify), and the copy-from-spare rebalance
migrates each block's CRC with the bytes. Full mechanism, the counter table,
create syntax, and `rk_dcl_populate` / auto-rebuild usage:
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
| `raidkm-test-ci.sh` | CI entry point — `--tier=smoke` (functional/degraded; the row layer: degraded read, native checksum, rebuild under load, replace, wide rows, full-row writes, resync/check/repair through `rk_row_sync`; declustered population and degraded; scrub with bad blocks, trust-disk, the tunables; the row state map and native snapshots: `rowmap`, `snap`, `snap-persist`; the fast decode paths, `fast-decode`; the md write journal's power-cut replay and its m>2 refusal, `journal`; the PPL refusal, `ppl-refused`; 21 suites — the journal's and PPL's declustered refusal is in `declustered-create`, which runs in `full`; the whole CI job took ~24 min, setup included, at 19 suites, and the two added on 2026-11-16 take ~33 s together on brd), `quick` (adds the stripe-path rebuild), `full` (`--allow-stop-all`, disposable hosts only), `nightly` (quick + the three independent-tool suites below; debug kernel, `--allow-stop-all`); a suite whose kernel or host lacks what it needs — or whose device count the rig cannot meet — reports `skip` with the reason, and a single check whose premise the hardware denies (a sub-block read on a 4 KiB-logical member) is counted as skipped rather than failed, with the count in the suite's note; a tier in which *every* suite skipped fails, so a mis-specified rig cannot pass by testing nothing; one exit status, `summary.txt`, JUnit `results.xml`, per suite `<suite>.log`, `<suite>.dmesg` (its whole kernel log) and `<suite>.tail.dmesg` (what the suite did not clear itself, the log the verdict scans), and each real member's size and block sizes in `env.txt`; refuses a host with other active md arrays. |
| `raidkm-test-fast-decode.sh` | fast decode (`fast_decode=1`, so it runs on GFNI hosts too) — which path each degraded read, rebuild and declustered population took (XOR, `gen_syndrome` or GF table), asserted from the `decode_xor` / `decode_syndrome` / `decode_gf` counters, with the data and a clean scrub checked; m=2 to m=4, rotating, parity-last and declustered, including a declustered group of width 3 (k=1, m=2) |
| `raidkm-test-journal.sh` | md write journal (`--write-journal`) — every member and the journal on dm-linear, a power cut (all switched to dm-flakey `drop_writes` at once) after acknowledged partial-stripe writes, then reassembly replays the journal: m=2 rotating (write-through and write-back) and parity-last (write-through), data identical and mismatch_cnt 0; m=3 and m=4 refused. The declustered refusal is checked by `raidkm-test-declustered-create.sh` (cases 6-7, `full` tier) |
| `raidkm-test-ppl-refused.sh` | PPL (`--consistency-policy=ppl`) refused on raidkm: create and plain assemble refused, `mdadm --assemble --update=no-ppl` brings the members back with data intact and a bitmap can be added, a runtime `consistency_policy` switch to ppl fails |
| `raidkm-test-faultinject.sh`, `raidkm-test-xfstests.sh`, `raidkm-test-mdadm-suite.sh` | nightly tier — the kernel's own fault injection (member I/O errors, allocation failures, I/O timeouts) under fsx/fsstress on ext4; xfstests on ext4 over raidkm healthy and degraded (`XFSTESTS_DIR`); mdadm's own raid6 tests adapted to raidkm (stops every array and detaches every loop device) |
| `raidkm-test-row-dread-wide.sh`, `raidkm-test-row-csum.sh` | row layer — a degraded span read once per row (unaligned spans, two failures, races, declustered), and native checksum verified and published through the row paths (poisoned survivors must be refused) |
| `raidkm-test-declustered-*.sh` | declustered parity — map/create, populate (rebuild into distributed spare), rebalance (copy-from-spare), sequential multi-assignment, auto-arm, the write journal and PPL refused on a pool (`-create` cases 6-7), native-checksum composition (`-csum`, incl. copy CRC migration), dm-flakey crash matrices, and the row layer across spare-assignment transitions (off while POPULATING/COPYING, live while steady and degraded, data intact across a rebalance) |
| `raidkm-test-grow*.sh`, `raidkm-test-reshape-*.sh` | grow/reshape (data + parity) |
| `raidkm-test-rowmap.sh` | the row state map — rows unwritten / needs sync / written, persistence, rebuild and resync skipping, the bitmap coming clean, a dirty degraded start refused |
| `raidkm-test-snap.sh`, `raidkm-test-snap-persist.sh` | native snapshots — content across a chain and destroys, a snapshot of a mounted ext4 under load, the copy paths' corner cases, a listing past one page; persistence across stop, journal replay, ring wraps, degraded and rebuilt members, damaged metadata copies, a full reserve |
| `raidkm-test-soak.sh`, `raidkm-test-crash.sh` | soak and crash-consistency |
| `raidkm-standard-benchmark.sh` | throughput benchmark (8 workloads incl. 1 MiB sequential and 4 KiB random read), with the request size reaching the member devices and host busy cores per workload; optional degraded phase (`--degraded-victim`), rebuild wall-clock (`--rebuild-victim`) and rebuild under a foreground load (`--rebuild-load`) |
| `raidkm-bench-iosize.sh` | request size and merge share at the members per I/O state (healthy, degraded, rebuild, declustered populate / copy-back) on a `null_blk` rig or real devices (`--devs`), optionally with native checksum (`--checksum`) — the check for flash with a large indirection unit |
| `raidkm-member-stats.sh` | sourced helper: resolves an array to the devices carrying its member requests (NVMe multipath paths included) |
| `raidkm-ab-benchmark.sh` | A/B benchmark against stock md on the same disks — raw member, `raid6`, the distro's in-tree `raid6-intree`, `raidkm<M>`, declustered `dcl<M>`, the same with native checksums (`raidkm<M>-csum`, `dcl<M>-csum`), `<arm>+tuned` (stock with raidkm's default knobs, for stock / tuned stock / raidkm in one run), and `<arm>@<n>` (the arm on only the first n of `--devs`, for equal usable capacity across layouts; the suffixes compose as `<arm>[-csum][@<n>][+<profile>]`, as in `raidkm2-csum@10` and `raid6@10+tuned`); `--degraded`, `--rebuild`, `--rebuild-load`; ABBA order with a discarded warm-up pass (the first run on fresh flash reads high) and optional steady-state preconditioning, ratio tables plus every run in execution order, headed by the host it ran on (CPU model, online CPUs, NUMA nodes) with hypervisor steal recorded per workload — the same machine type is not the same machine, and one workload read 0.86× and 0.99× on two instances a few hours apart with bit-identical modules; `--dry-run` prints every command first |
| `raidkm-rig-nvme.sh` | carve a real-disk rig for the suites — members of the size they are calibrated for (default 256 MiB, matching the ram disks they otherwise build), one per namespace, stale superblocks zeroed, and the `RK_DEVS` line printed. Whole-namespace or oversized members make every create resync the whole disk, which is what pushed `replace` past its budget on the first real-NVMe tier. Refuses a disk that is mounted, in swap, an LVM PV or held by md; needs `--yes` |
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
