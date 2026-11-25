# kakao32

The Kakao SOC's CPU: RV32IMA with the standard privileged architecture
(M, S and U modes) and Sv32, as mainline Linux needs.

It began as a copy of Zeitlos's zeitlos32ps (zeitlos commit fdc072b)
with the modules renamed. zeitlos32ps is RV32IM with picorv32's
interrupt instructions and an MPU, in four stages, built to pass 48 MHz
in picorv32's area. kakao32 keeps its ALU, multiplier/divider, load and
store units and register file, and replaces the rest step by step.

Where it stands: it runs Kakao Linux (Buildroot) on the Sergei ML2 at
48 MHz, with the monitor, keyboard and mouse, the SD card and the
network; everything tried there worked. 27.98 DMIPS and 98.4 CoreMark
iterations a second. kakao64 is its 64 bit copy
([kakao64.md](kakao64.md)); what kakao64 gained since (two requests on
the memory port at once, a larger TLB) has not been brought back here.

## Steps

Each step ends with the tests passing and is committed on its own.

- [x] **0. Fork.** Modules renamed, the inherited directed tests pass
      at fixed and random latencies (`make -C tests`).
- [x] **1. Standard traps in M-mode.** mstatus, mie, mip, mtvec,
      mepc, mcause, mtval, mscratch, misa, the counters and the ID
      registers; ecall, ebreak, mret, wfi (a no-op); illegal-instruction
      and misaligned traps; the three M interrupt lines. picorv32's
      interrupt instructions, the IRQ timer, the MTU and the MPU ports
      are gone, and reset is at 0x8000_0000. Tests: riscv-tests
      `rv32ui`, `rv32um` and `rv32mi`, and `prog/irq.S` for the
      interrupts: 64 programs, each at four latencies and three random
      runs, all pass. Not run: `rv32mi-breakpoint` (debug triggers),
      `rv32mi-pmpaddr` (PMP), `rv32ui-ma_data` (misaligned accesses
      trap here, for the SBI firmware to emulate). Still to do in this
      step: comparison with QEMU instruction by instruction, which
      riscv-tests does not replace.
- [x] **2. The A extension.** lr.w and sc.w with one reservation, the
      AMOs as a read and a write. Tests: `rv32ua`.
- [x] **3. S and U modes.** The S CSR set, medeleg and mideleg, sret,
      the privilege checks, SUM, MXR, MPRV, TVM, TW and TSR, `time`
      from the CLINT's mtime. Tests: `rv32si`, and `rv32mi` again.
- [x] **4. Sv32.** One direct-mapped TLB (32 entries) for fetches and
      data, a hardware table walker on the memory port, megapages,
      page faults in program order, sfence.vma, A and D bits by fault.
      Tests: `rv32ui`, `rv32um` and `rv32ua` once more under riscv-tests'
      "v" environment, which runs them in U-mode under a small
      supervisor with paging. 139 programs in all.
- [x] **5. Linux in simulation.** OpenSBI 1.9 and the prebuilt Kakao
      image (Linux 6.1, the buildroot root file system) boot to the
      login prompt and a shell under Verilator, all three unmodified.
      See [../sim/README.md](../sim/README.md).
- [x] **6. Linux on a board, and speed.** The SOC around it
      ([design.md](design.md)) and the Sergei ML2: Linux 6.6.18 from
      the SD card. Then, for speed: a cache of its own (`k_cache`,
      separate instruction and data caches), translated loads and
      stores in X's first cycle (`FAST_XLATE`), a branch target buffer
      of 64 entries at the fetch (`BTB_BITS`), the multiplier in DSP
      blocks (`FAST_MUL`), static prediction (`BTFN`, off: 0.7%). The
      pipeline is still four stages and the clock 48 MHz, the USB
      controller's; a faster clock for the CPU alone is not started.
- [ ] **Comparison with QEMU**, instruction by instruction, on the
      Linux boot: riscv-tests and a booting kernel do not replace it.


## Open design points

- **Cache and page size.** Zeitlos's unified 8 KB direct-mapped cache
  is indexed with 13 address bits, one more than a 4 KB page leaves
  untranslated. As the core stands, translation comes before the
  port, so the cache sees physical addresses and the question is only
  one of timing: the TLB read and compare are in front of the cache's
  address. Step 6 decides between that, two 4 KB ways indexed inside
  the page, and a virtually indexed cache.
- **One TLB for fetches and data.** An instruction and the data it
  touches can fall on the same entry and evict each other, at two
  walks an access. It makes progress, slowly; separate TLBs or two
  ways are the remedy, to be measured.
- **wfi** is a no-op, so an idle kernel spins. Harmless, but an idle
  simulation is as slow as a busy one, and an idle board as warm.
- **Not implemented, by choice so far:** PMP, the debug triggers,
  vectored mtvec/stvec, ASIDs, hardware A/D updates, misaligned
  accesses (they trap for OpenSBI to emulate), Sstc.

## Size and timing

The whole SOC on the Sergei ML2, with ten terminals, the disk and the
network (build k4): 50.69 MHz for 48 on the first seed, 49.9 to 53.4
over six; the FPGA 43% full. On the 25F boards 51.6 to 54.5 MHz. All
at speed grade 6.

What it took, in the order it was found:

- Retired instructions are counted a cycle late: the counter's enable
  was at the end of the path from the cache's tag memory.
- The TLB is read twice, for the fetch PC and for X's data address,
  each from a register. A translated load or store at first took a
  cycle more (the address registered before the lookup), which cost
  the Linux boot a fifth of its speed; `FAST_XLATE` looks the page up
  from the adder's sum in X's first cycle and won it back.
- The cache's answer passes one LUT in the CPU before the registers it
  enables, and the cache compares its tags on the carry chain
  ([design.md](design.md), "The cache and the clock").

In simulation the Linux boot with a login and commands takes about 4.1
cycles an instruction with the 64 KB instruction cache; the cache's
table in design.md has how it got there. On the board, Dhrystone came
out within 2.5% of what simulation had said.
