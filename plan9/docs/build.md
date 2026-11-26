# Building Plan 9 on Linux

Plan 9 is built with Plan 9's own compilers, by Plan 9's `mk` and `rc`,
from mkfiles that name their files from the root (`/sys/src`,
`/riscv64/lib`, `/rc/bin`). There is no Plan 9 machine here, so the
build brings just enough of one to Linux:

| what the mkfiles expect | what stands in for it |
|---|---|
| `jc`, `jl`, `ja`, `ar` for riscv64 | the distribution's own sources (`sys/src/cmd/cc`, `ic`, `il`, `ia`) and the Fourth Edition's `ar.c`, compiled for Linux against plan9port's `lib9` and `libbio`: `tools/mkhost.sh` |
| `mk`, `rc`, `awk`, `sed`, `yacc`, `xd`, `date -n` ... | plan9port's, which are those programs |
| `size`, `strip` | `tools/p9aout.c`: they need only the a.out header |
| `aux/data2s` | the Fourth Edition's, compiled for Linux |
| `/sys`, `/riscv64`, `/rc` at the root | `build/root`, and `tools/p9run`, which runs `rc` with that as its root directory |
| `bind -a ../9/port ../9k/port` and the like | links, made by `tools/mkroot.sh` |

With that, the distribution's mkfiles run as they are: `mk install` in
`/sys/src/libc`, `ARCH=kk mk` in `/sys/src/9k/rv`.

## The steps

`make` does these in order; each leaves a stamp in `build/` and a log
(`build/*.log`).

1. **fetch**: plan9port and the Fourth Edition from GitHub at the commits
   in `upstream/versions.mk`; the 9k distribution unpacked from
   `upstream/`, after its checksum is checked.
2. **plan9port** (`build/src/p9p`): its `INSTALL`, without the window
   system. A few of its programs do not link without X; none of them is
   used.
3. **lib9 and libbio at 32 bits** (`build/p9p32`).
4. **the compilers** (`build/host/bin`): `tools/mkhost.sh`.
5. **the root** (`build/root`): `tools/mkroot.sh`.
6. **libs**, **cmds**: `mk install` for libc and fifteen other libraries,
   then `rc`, the commands that go into the kernel's file system,
   `ip/ipconfig`, `ip/ping` and `auth/factotum`.
7. **kernel**: `overlay/` copied over the root again, then
   `ARCH=kk mk 9kkcpu.bin`; the result is `build/9kkcpu.bin`.

## Things that had to be found out

**The compilers must be 32 bit programs.** They are written in Plan 9's
C, where `long` is 32 bits. Built as 64 bit Linux programs they compiled
small files and then ran for ever on `libsec/port/dsaprimes.c`. With
`gcc -m32` they are the programs they are on a 386, which is where they
are used most. They are linked statically, so that they run inside
`build/root` with none of the host's libraries.

**plan9port's `mk` runs recipes with `sh`** unless told otherwise, and a
`MKSHELL=rc` in an included mkfile does not reach the including one.
`FORCERCFORMK=1` in the environment (set by `tools/p9run`) makes `rc`
the default, as on Plan 9.

**The distribution is not a whole system.** It has the kernel, libc, the
compilers and the headers of Geoff Collyer's tree, and those headers
belong to library sources it does not include. The Fourth Edition's
sources are used for the rest, and where the two disagree:

| | |
|---|---|
| `libc/port/mkfile` names `noansiterm.c`, which is not there | the name is removed; nothing uses it |
| `mp.h` declares `_mpfree` and makes `mpfree` a macro | the Fourth Edition's `mp.h` is used |
| `9p.h`, `bin.h`, `libthread/threadimpl.h` take sizes as `uintptr` | the three definitions are changed to match (`lib9p/mem.c`, `libbin/bin.c`, `libthread/lib.c`) |
| the kernel's `port/random.c` uses a ChaCha cipher from libsec | `overlay/sys/src/libsec/port/chacha.c`, written here from RFC 7539, and its declarations added to `libsec.h` |
| `rv/getdefs` looks in `/env` for `$ARCH` | changed to look at the variable |

All of these but the first two files are in `patches/kakao.patch`.

**Name spaces.** `9k` is built with `../9/port`, `../9/ip`, `../9/boot`
and `../9/pc` bound into it. `tools/mkroot.sh` links every file of
`9/port` that `9k/port` does not have into `9k/port`, and the three
directories whole; `bind` in the root is a script that does nothing.

**The root directory.** `tools/p9run` uses `chroot` when run as root,
else `bwrap`, else `unshare -r`. Only the first has been run. Nothing in
the build needs privilege beyond that.

## Changing things

- A kernel file of ours: edit it under `overlay/`, `make kernel`.
- A file of the distribution or the Fourth Edition: edit it in
  `build/root`, build, and when it is right add it to
  `patches/kakao.patch` (`diff -u` against the file in `build/dist` or
  `build/src/plan9`); `make root` starts the root again from the sources.
  So does any `make` once the patch file, `tools/mkroot.sh` or an
  overlay file outside the kernel is newer than the root, and what was edited in `build/root` by hand is gone then: put
  the change in the patch before building again.
- A kernel file is not compiled again because `CONFDEF` in `kk/defs`
  changed: remove its `.j` file in `build/root/sys/src/9k/rv`.
- A command for the root file system: its name in `CMDS` (or
  `AUTHCMDS`, `NDBCMDS`, `AUXCMDS`) in the Makefile; everything in
  `build/root/riscv64/bin` goes into the root. A file for it: under
  `rootfs/`. An empty directory: in `ROOTDIRS` in the Makefile, since
  git keeps none. `make kernel` packs the root again each time.
- To run something in the root by hand:
  `tools/p9run build/root 'cd /sys/src/9k/rv && ARCH=kk mk 9kkcpu.bin'`.
- To see where a kernel address is: the linker's listing is
  `build/root/sys/src/9k/rv/9kkcpu.bin.list`.
