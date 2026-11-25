# kakao32

The 32 bit CPU of the Kakao SOC. It runs Kakao Linux (Buildroot) on
the Sergei ML2 at 48 MHz, with mainline Linux and OpenSBI as they are.

## What it is

- **RV32IMA**, with Zicsr and Zifencei: multiply and divide, lr/sc
  with one reservation, the AMOs as a read and a write.
- **M, S and U modes** with the standard CSRs, medeleg and mideleg,
  SUM, MXR, MPRV, TVM, TW and TSR, and `time` from the CLINT's mtime.
- **Sv32**: a TLB of 32 entries shared by fetches and data, a hardware
  table walker on the memory port, megapages, page faults in program
  order. No ASIDs; the A and D bits are set by a fault.
- **Four stages**, a branch target buffer of 64 entries at the fetch,
  the multiplier in DSP blocks (one cycle) or in 32 steps.

Not implemented: PMP, the debug triggers, vectored trap vectors, Sstc,
and misaligned accesses (they trap, and OpenSBI emulates them). `wfi`
is a no-op, so an idle kernel spins.

kakao64 is its 64 bit copy ([kakao64.md](kakao64.md)). What that has
gained since (two requests on the memory port at once, a larger TLB)
has not been brought back here.

## Building it

`make -C boards BOARD=<board>` builds the SOC with it
(`boards/README.md`).

| parameter | | as built |
|---|---|---|
| `FAST_MUL` | the multiplier in DSP blocks, not 32 steps | 1 on the 45F |
| `FAST_XLATE` | a translated load or store looks its page up in X's first cycle | 1 |
| `BTB_BITS` | the branch target buffer has 2^n entries (0: none) | 6 |
| `TLB_BITS` | the TLB has 2^n entries | 5 |
| `BTFN` | static prediction where the buffer has nothing | 0 (it gains 0.7%) |

## How fast

On the Sergei ML2 at 48 MHz: **27.98 DMIPS** (0.58 DMIPS/MHz) and
**98.4 CoreMark** iterations a second (2.05 CoreMark/MHz). Dhrystone
came out within 2.5% of what simulation had said.

In simulation the Linux boot with a login and commands takes about 4.1
cycles an instruction with the 64 KB instruction cache
([design.md](design.md) has the cache's part in that).

The whole SOC on the Sergei ML2, with eight terminals, the disk and the
network, fills 43% of the 45F and places at 50 to 53 MHz for 48 over
six seeds; on the 25F boards at 51 to 54 MHz. All at speed grade 6.

## Tests

```
make -C rtl/cpu/kakao32/tests     riscv-tests and its own, 139 programs,
                                  each at four latencies and three random runs
make -C sim boot OPENSBI=...      Linux on the CPU under Verilator
```

The riscv-tests suites are `rv32ui`, `um`, `ua`, `mi` and `si`, and the
user suites again under the "v" environment (U-mode under a small
supervisor with paging); `prog/irq.S` is for the interrupts. Not run:
`rv32mi-breakpoint`, `rv32mi-pmpaddr`, `rv32ui-ma_data`. Not done: a
comparison with QEMU instruction by instruction on the Linux boot,
which riscv-tests and a booting kernel do not replace.

---

# Notes

## Where it came from

It began as a copy of Zeitlos's zeitlos32ps (zeitlos commit fdc072b)
with the modules renamed. zeitlos32ps is RV32IM with picorv32's
interrupt instructions and an MPU, in four stages, built to pass 48 MHz
in picorv32's area. kakao32 keeps its ALU, multiplier/divider, load and
store units and register file; the rest was replaced step by step:
standard traps in M-mode, the A extension, S and U modes, Sv32, Linux
in simulation, then the board and speed.

## Timing

What it took to meet 48 MHz, in the order it was found:

- Retired instructions are counted a cycle late: the counter's enable
  was at the end of the path from the cache's tag memory.
- The TLB is read twice, for the fetch PC and for X's data address,
  each from a register. A translated load or store at first took a
  cycle more (the address registered before the lookup), which cost the
  Linux boot a fifth of its speed; `FAST_XLATE` looks the page up from
  the adder's sum in X's first cycle and won it back.
- The cache's answer passes one LUT in the CPU before the registers it
  enables, and the cache compares its tags on the carry chain
  ([design.md](design.md), "The cache and the clock").

The pipeline is still four stages and the clock 48 MHz, which is the
USB controller's; a faster clock for the CPU alone is not started.

## Open design points

- **One TLB for fetches and data.** An instruction and the data it
  touches can fall on the same entry and evict each other, at two walks
  an access. It makes progress, slowly; separate TLBs or two ways are
  the remedy, to be measured.
- **The cache is indexed with physical addresses**, so the TLB's read
  and comparison are in front of the cache's address. Two ways indexed
  inside the page, or a virtually indexed cache, would take them out of
  that path.
