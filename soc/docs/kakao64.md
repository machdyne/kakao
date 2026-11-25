# kakao64

The 64 bit CPU of the Kakao SOC, for the boards with 512 MB of memory
and an ECP5 45F: what Debian's `riscv64` port needs. It runs Kakao
Linux (Debian) on the Sergei ML2 ([debian.md](debian.md)).

## What it is

- **RV64IMAC**, with Zicsr and Zifencei: 64 bit registers, the W
  instructions, multiply and divide, lr/sc and the AMOs for words and
  doublewords, and the compressed instructions.
- **M, S and U modes** and **Sv39**: three levels, gigapages and
  megapages, a TLB of 128 entries shared by fetches and data, a
  hardware table walker. No ASIDs; the A and D bits are set by a fault.
- **F and D, with the firmware's help.** The CPU has f0 to f31,
  `mstatus.FS`, fcsr, the floating-point loads and stores (also the
  compressed ones), fmv, fsgnj, fclass and the compares. Arithmetic,
  square root, fused multiply-add, min/max and the conversions are
  illegal instructions, which the SBI firmware does in M-mode with
  Berkeley SoftFloat: `fw/opensbi/0001-emulate-F-and-D-arithmetic.patch`
  on OpenSBI 1.9. Linux and Debian see RV64GC (`rv64imafdc`).
- **Four stages**, a branch target buffer of 64 entries at the fetch, a
  queue of four fetched words in front of decode, a multiplier in four
  DSP blocks (8 cycles a product), a divider of 64 steps.
- **A memory port a doubleword wide**, on which two requests may be on
  their way at once. `rtl/k_port64.v` puts it on the SOC's cache, whose
  port is a word wide: a doubleword is two accesses there.

It is a copy of kakao32 (`rtl/cpu/kakao64`), not a parameter of it.

Not implemented: PMP, the debug triggers, vectored trap vectors, Sstc,
misaligned accesses (they trap, and OpenSBI emulates them), and an
access fault for an address above 4 GB (the port has 32 address bits,
and a page table entry that points higher is a page fault).

## Building it

```
make -C boards BOARD=sergei_ml2 CPU64=1
```

`boards/README.md` has its options and what goes on its card.

| parameter | | as built |
|---|---|---|
| `FAST_MUL` | the multiplier in DSP blocks, not 64 steps | 1 |
| `TLB_BITS` | the TLB has 2^n entries | 7 |
| `BTB_BITS` | the branch target buffer has 2^n entries (0: none) | 6 |
| `BTFN` | static prediction where the buffer has nothing | 0 |

## How fast

On the Sergei ML2 at 48 MHz, under Debian with the busybox as init,
with the same two programs as kakao32's figures (built for rv64imac):

| | kakao64 | kakao32 |
|---|---|---|
| Dhrystone 2.1 | 18.87 DMIPS, 0.39 DMIPS/MHz | 27.98, 0.58 |
| CoreMark 1.0 | 60.6 iterations a second, 1.26 CoreMark/MHz | 98.4, 2.05 |

What kakao64 pays that kakao32 does not: a load or store asks from a
registered address, a cycle later; the cache's answer comes through a
register; and a doubleword, which on RV64 is every pointer and every
long, is two accesses of the cache. Each floating-point operation the
firmware does costs some thousands of cycles.

The SOC with it fills 65% of the 45F's LUTs and all 108 of its block
RAMs, and places at 49.61 MHz for 48 (speed grade 6, seed 2; other
seeds have given 45 to 50).

## Tests

```
make -C rtl/cpu/kakao64/tests run     riscv-tests and its own, 203 programs,
                                      each at four latencies and three random runs
make -C sim/fptest                    rv64uf and rv64ud as one image, for the firmware
make -C sim sim64                     the SOC with kakao64 under Verilator
```

The riscv-tests suites are `rv64ui`, `um`, `ua`, `uc`, `mi` and `si`,
and the user suites again under the "v" environment (U-mode under a
small supervisor with Sv39), all compiled with the C extension.
`rv64uf` and `rv64ud` (23 programs) run under the firmware, on QEMU and
on the simulated SOC. Linux boots in simulation with the disk and the
network, and Debian's base system gives the same output there as on
QEMU for the same commands (`sim/README.md`).

Little of riscv-tests aims at the hard cases of C and Sv39: a 32 bit
instruction across a page boundary whose second page faults, a
predicted jump gone stale under changed code, misaligned superpages,
addresses that are not canonical and reserved bits in a page table
entry are written and not known to be exercised.

## What is left

- **Speed.** A cache 64 bits wide, so that a doubleword is one access;
  cache lines longer than 16 bytes, or the next one fetched ahead
  (waiting for memory is the largest single share of the cycles); a
  page walk in fewer than three doublewords; floating-point arithmetic
  in hardware, if what Debian runs shows it is worth it; the SD card,
  which moves a sector at a time over SPI.
- **Access faults above 4 GB.** Written, and it passes its test, but
  the SOC then placed at 45 to 46 MHz on three seeds: it waits for a
  way that costs no time.
- **Debian's own kernel.** Ours is Linux 6.6.18 with a small
  configuration. Debian's needs nothing QEMU's `virt` does not have,
  but its initrd is tens of megabytes to load and unpack.

---

# Notes

What follows is how it came to be as it is: of use to whoever changes
it.

## What Debian asks for

Debian's `riscv64` port (an official architecture since Debian 13,
trixie) is built for rv64gc and the `lp64d` ABI, which passes
floating-point arguments in the f registers. Every binary in the
archive may use compressed instructions and the F and D instructions,
and the dynamic loader and glibc do. What a later release will ask for
(RVA23 has been discussed for the one after trixie) is not decided.

Around the CPU nothing changes in kind from kakao32's SOC: the machine
stays QEMU's `virt`, which is what Debian's kernel and installer images
already run on. kboot is built for RV64 (`XLEN=64`), OpenSBI for RV64,
and the device tree says `rv64imafdc` and `riscv,sv39`. Memory is laid
out as QEMU has it for RV64: OpenSBI at 0x8000_0000, the kernel at
0x8020_0000, the device tree at 0x87f0_0000.

## Floating point: why this way

There were three ways, in rising cost: everything trapped and emulated
in M-mode, with no f registers in the CPU; the registers, loads, stores,
moves and compares in hardware and the arithmetic trapped; all of it in
hardware (a 53 by 53 multiply is nine of the 45F's 72 DSP blocks, and
some thousands of LUTs).

The second is what was built. It takes context switches and argument
passing out of the emulator, which is most of what a system that does
no arithmetic in floating point executes, and its test is the same as
for the third (`rv64uf`, `rv64ud`). The emulator has to live in M-mode;
OpenSBI already emulates what a hart lacks in its illegal-instruction
path, and floating point is a patch to that: a change to the firmware,
not to Linux.

## Timing

kakao32's SOC meets 48 MHz with the FPGA 43% full. With kakao64 it was
60% full when first built, and seeds alone gave 43 to 46 MHz. What made
it pass:

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
  and whether it takes the CPU's request is a register too.

As first done, the last allowed one access at a time, a fetch every
other cycle at best. Now two requests may be outstanding: the CPU asks
for the next word while the one before is on its way, and for X's load
or store behind a fetch; `k_port64` shows the cache a request while the
cache answers the one before, and keeps the one the cache did not take.
None of the paths above came back with it.

## What each change gave

Cycles an instruction in a simulated Linux boot (`sim/README.md`). The
first two rows are with the simulation's memory writing every store on
its own, which the boards do not do; the rest with the controller's
write combining, as built.

| | cycles an instruction |
|---|---|
| one request at a time | 6.83 |
| two requests in flight, the multiplier in DSP blocks | 6.06 |
| the same, with write combining | 5.15 |
| ...and a TLB of 64 entries | 4.95 |
| ...or a TLB of 128 entries (as built) | 4.83 |
| ...or a data cache of 32 KB in place of 16 (as built; it costs four terminals) | 4.89 |
| ...or a data cache of 64 KB | 4.62 |
| ...or both caches 32 KB (the instruction cache halved) | 5.31 |

As built, with both the 128 entries and the 32 KB, a boot with a
script took 4.52 cycles an instruction, for 4.72 with 16 KB.

With 128 TLB entries and the 16 KB data cache, by what the CPU was
waiting for: a load's or store's answer after its first cycle 34% of
all cycles, fetches on their way 15%, page walks 6%, a translated
address 7%.

## Not known

- **Where systemd's minutes go.** The first boot's log has the kernel
  at its init after 6 s, systemd's first line at 27 s (its program and
  libraries, from the card), its units loaded at 120 s, and the rest
  after: udev's first pass over the devices alone ran two minutes. How
  much of that is the CPU, the card, or the floating point the
  firmware does for it has not been measured.
- **How slow the SD card is** for a root file system of a gigabyte or
  two. In simulation 23 MB read and summed took about a minute of the
  machine's time, the sum included.
- **How much floating point Debian's ordinary programs execute**, which
  decides whether its arithmetic belongs in hardware.

## The steps it was built in

Each ended with its tests passing and was committed on its own.

0. **Fork.** kakao32 copied and renamed; its test bench builds the 64
   bit suites.
1. **RV64I in M-mode.** 64 bit registers and datapath, the W
   instructions, ld/sd/lwu, 64 bit CSRs. The memory port a doubleword
   wide: a load or store is one access whatever its size.
2. **M and A at 64 bits.**
3. **C.** The queue still holds fetched words; D takes its instruction
   from either half of the head word, or from its upper half and the
   next word's lower, and expands a 16 bit one (`kakao64_cexp.v`). The
   BTB knows a jump by the word and half it ends in.
4. **S and U, Sv39** (done before step 3).
5. **The SOC at 64 bits.** `k_port64`, `CPU64` in `kakao_soc`, kboot
   and OpenSBI for RV64, the kernel's configuration.
6. **Floating point, with the firmware's help.**
7. **Timing and the board.** Linux on the Sergei ML2, first with a
   busybox root.
8. **Debian.** Debian's base system with a busybox as init; then
   `apt install systemd-sysv` on the machine, and the next boot was
   systemd's.
9. **Speed**, which is where it is now.
