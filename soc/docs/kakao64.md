# kakao64

The 64 bit CPU of the Kakao SOC. The goal: **Debian on our own CPU**,
on the Sergei ML2 (ECP5 45F, 512 MB of DDR3), with Debian's own
packages unmodified, and if it can be had Debian's own kernel too.
Where it stands: Debian's base system runs on the board; Debian's init
has not been tried (step 8).

## What Debian asks for

Debian's `riscv64` port (an official architecture since Debian 13,
trixie) is built for **rv64gc**: RV64IMAFDC with Zicsr and Zifencei,
and the `lp64d` ABI, which passes floating-point arguments in the f
registers. Every binary in the archive may use compressed instructions
and the F and D instructions, and the dynamic loader and glibc do. What
a later release will ask for (RVA23 has been discussed for the one
after trixie) is not decided; trixie is the target.

So against kakao32 (RV32IMA, M/S/U, Sv32):

| | kakao32 | Debian needs | work |
|---|---|---|---|
| registers, ALU, shifts | 32 bit | 64 bit, and the W instructions | wider datapath; the adder and comparator paths get longer |
| M | 32 x 32 | 64 x 64, and the W forms | the multiplier in more steps; the divider twice as long |
| A | lr/sc/AMO .w | and .d | small |
| C | none | needed | instructions at either half of a fetched word and across two, an expander in front of decode |
| F, D | none | needed | see below: the largest single piece |
| CSRs | 32 bit | 64 bit; mstatus with SXL/UXL (fixed at 64), FS | mechanical, plus FS |
| paging | Sv32, two levels | Sv39, three levels (Linux also runs on it alone) | the walker one level deeper, wider tags in the TLB, the canonical address check |
| memory port | 32 bit words | 64 bit loads and stores | the cache's data path 64 bits wide, or two accesses for a doubleword (to decide in step 1) |
| physical addresses | 32 bit | 56 in Sv39 | stay 32 on the bus; a page table entry that points above 4 GB is an access fault |

Around the CPU nothing changes in kind: the machine stays QEMU `virt`
(CLINT, PLIC, 16550s, virtio-mmio, syscon reset), which is what
Debian's kernel and installer images already run on. kboot is C and is
rebuilt for RV64; OpenSBI is built for RV64; the device tree says
`rv64imafdc` and `riscv,sv39`.

## Floating point

Three ways, in rising cost:

1. **Trapped and emulated in M-mode.** The CPU has no f registers. F
   and D instructions are illegal instructions; the handler in the SBI
   firmware keeps f0..f31 and fcsr in memory and does the instruction
   with a software float library. `mstatus.FS` is real (the kernel
   turns it off and on, and reads Dirty to decide what to save), and
   with FS off the trap goes to the kernel as it should. Linux and
   Debian see a machine with F and D. Cost in the FPGA: almost
   nothing. Cost in speed: some hundreds to thousands of cycles for
   each floating-point instruction, which includes every `fld` and
   `fsd` the kernel does to save and restore a process's registers.
2. **The registers, loads, stores and moves in hardware, arithmetic
   trapped.** f0..f31 as a second register file (two more block RAMs,
   or LUT RAM), fld/fsd/flw/fsw, fmv, fsgnj, and the compares and
   classify, which are cheap. That takes the context switches and
   argument passing out of the emulator: most of what a system that
   does no arithmetic in floating point executes. Add, multiply,
   divide, square root, the fused forms and the conversions still
   trap.
3. **All of it in hardware.** A multi-cycle double-precision unit on
   the DSP blocks (a 53 x 53 multiply is nine of the 45F's 72). Some
   thousands of LUTs, and the part of this plan with the most to test.

The plan is 1 first, because it gets to Debian soonest and its test is
the same for all three (riscv-tests `rv64uf` and `rv64ud`, which then
run against the emulator); then 2; 3 only if what Debian is used for on
this machine shows it is worth it.

The emulator has to live in M-mode, so in or under OpenSBI. OpenSBI
already emulates what a hart lacks (misaligned accesses, `rdtime`) in
its illegal-instruction path; floating point would be a patch to it, or
a platform of our own carrying it. That is a change to the firmware,
not to Linux.

## Steps

As for kakao32: each step ends with its tests passing and is committed
on its own. The core is a copy (`rtl/cpu/kakao64`), not a parameter of
kakao32: kakao32 stays the tested CPU of the 32 bit SOC while this
grows.

- [x] **0. Fork.** kakao32 copied and renamed (`rtl/cpu/kakao64`), and
      its test bench builds the 64 bit suites (`rv64ui`, `um`, `ua`,
      `mi`, `si`, and the user ones under the "v" environment). The
      core is still the 32 bit one: 108 of 193 programs pass with no
      wait states, those that never look above bit 31. That is the
      baseline, not a result.
- [x] **1. RV64I in M-mode.** 64 bit registers and datapath, the W
      instructions, ld/sd/lwu, 64 bit CSRs (misa and mstatus say 64 bits
      for all three modes; the high-half counter CSRs are gone). The
      memory port is a doubleword wide: a load or store is one access
      whatever its size, and a fetch takes its word from the half it
      asked for. Tests: `rv64ui`, `rv64mi`.
- [x] **2. M and A at 64 bits.** The multiplier/divider at 64 bits
      (64 steps; the W forms extend their operands and run the same),
      lr/sc and the AMOs for words and doublewords. Tests: `rv64um`,
      `rv64ua`. With step 1: 106 programs, each at four latencies and
      three random runs, all pass. The 87 others need paging (step 4).
      Not done, and not tested by riscv-tests: an access fault for an
      address above 4 GB (the port has 32 address bits; the upper bits
      are dropped today). Not carried over from kakao32: the Zbb
      rotates. PCs are 64 bits wide for now; the BTB keeps 30 bits of a
      target and D checks the rest.
- [x] **3. C.** The queue still holds fetched words; D takes its
      instruction from either half of the head word, or from its upper
      half and the next word's lower, and expands a 16 bit one
      (`kakao64_cexp.v`). The BTB knows a jump by the word and half it
      ends in. An illegal 16 bit instruction traps with its 16 bits in
      tval. Tests: `rv64uc`, and every other suite compiled with C (in
      `rv64ui-add`, 264 of 431 instructions are 16 bit): 195 programs,
      each at four latencies and three random runs, and once more with
      BTFN and without the BTB, all pass. riscv-tests does not aim at
      the hard cases here either: a 32 bit instruction across a page
      boundary whose second page faults, and a BTB entry gone stale
      under changed code, are written and not known to be exercised.
      The floating-point forms (c.fld and the like) are illegal until
      step 6.
- [x] **4. S and U, Sv39.** (Done before step 3.) Three levels,
      gigapages and megapages, the canonical address check, satp with
      bare and Sv39 and no ASIDs; the TLB and the walker are kakao32's,
      wider. Tests: `rv64si`, and the user suites under riscv-tests'
      "v" environment: with steps 1 and 2, 193 programs, each at four
      latencies and three random runs, all pass. Little of this is
      aimed at by those tests: superpages that are misaligned,
      addresses that are not canonical, and reserved bits in an entry
      are written and not known to be exercised. A page table entry
      that points above 4 GB is a page fault, not the access fault it
      should be.
- [x] **5. The SOC at 64 bits.** `rtl/k_port64.v` puts kakao64's
      doubleword port on the cache's word port (a doubleword is two
      accesses); `CPU64` in `kakao_soc`; kboot builds for RV64
      (`XLEN=64`) and its SD boot test passes; OpenSBI 1.9 for RV64;
      `buildroot/board/kakao_soc/linux64.config` (Linux 6.6.18). A
      layout of memory as QEMU's `virt` has it for RV64: OpenSBI at
      0x8000_0000, the kernel at 0x8020_0000, the device tree at
      0x87f0_0000. `make -C sim sim64`.
- [x] **6. Floating point, with the firmware's help.** In the core: f0
      to f31, `mstatus.FS` and SD, fflags/frm/fcsr, the loads and
      stores (also the compressed ones), fmv, fsgnj, fclass and the
      compares. The arithmetic, square root, fused multiply-add,
      min/max and conversions are illegal instructions that the SBI
      firmware does in M-mode with Berkeley SoftFloat 3e:
      `fw/opensbi/0001-emulate-F-and-D-arithmetic.patch` on OpenSBI
      1.9. Tests: riscv-tests' `rv64uf` and `rv64ud` under the firmware
      (`sim/fptest`: 23 programs, on QEMU and on the simulated SOC),
      and a glibc program computing with doubles under Linux.
- [x] **7. Timing and the board.** `make -C boards BOARD=sergei_ml2
      CPU64=1 FAST_MUL=0`: 48.73 MHz for 48 (seed 2), 60% of the 45F's
      LUTs, 107 of 108 block RAMs. It took registers between the CPU
      and the cache in three places (see "Timing" below) and costs
      speed. **Linux boots on the Sergei ML2** to a shell, first with a
      busybox root on the card's second partition.
- [ ] **8. Debian.** Debian 13.8's own base system (the root file
      system of the official image: apt, dpkg, bash) runs on the board,
      with a static busybox as init: a shell, the network by DHCP, the
      time by NTP, `apt update` from Debian's archive. Not yet: Debian's
      init (systemd), which is `apt install systemd-sysv` away and has
      not been tried. `tools/mkdebian.sh` makes a card with a full
      Debian by mmdebstrap on another machine; on the one machine it
      was tried on, kboot did not find `boot.json` on the card it made,
      and why is not known. One card showed older data beyond 500 MB
      than had been written to it last; whether that was the card's
      writing or ours is not settled.
- [ ] **9. Speed.** Two fetches in flight (below); a multiplier in the
      DSP blocks (it is 64 steps now); a cache 64 bits wide; floating
      point arithmetic in hardware; the SD card.

## Timing

kakao32's SOC meets 48 MHz with the FPGA 43% full. With kakao64 it is
60% full, and seeds alone gave 43 to 46 MHz. What made it pass:

- A trap takes two cycles: found in one, taken from registers in the
  next.
- A load or store asks the port from a registered address, the cycle
  after its adder.
- A predicted jump's target is checked in X, not in D behind the
  expander; sc compares its address a cycle before it asks.
- `k_cache`'s request registers take the CPU's request whenever one
  could be taken, without waiting for the hit; a fetch or load that
  misses is put back and looked up again (two cycles on a miss).
- `k_port64` gives the cache's answer to the CPU through a register,
  one access at a time.

The last is the expensive one: a fetch completes every other cycle at
best. A simulated Linux boot takes 6.9 cycles an instruction, 5.4
before these changes. Letting two fetches be in flight would give most
of that back without touching the paths that were too long.

## What is not known yet

- **Simulating Debian.** A small Linux takes 20 to 25 minutes to boot
  under Verilator. Debian with systemd would take many hours, so
  Debian itself is tested on the board; simulation gets as far as a
  user space built the way Debian's is.
- **How slow the SD card is** for a root file system of a gigabyte or
  two: the I/O processor moves one sector at a time over SPI.
- **How much floating point Debian's ordinary programs execute**, which
  decides whether emulation is bearable. To be counted under QEMU
  before step 6.
- **Whether Debian's kernel boots as it is.** It needs nothing QEMU
  `virt` does not have, but its initrd is tens of megabytes to load and
  unpack at this speed.
