# kakao32

The Kakao SOC's CPU: RV32IMA with the standard privileged architecture
(M, S and U modes) and Sv32, as mainline Linux needs.

It began as a copy of Zeitlos's zeitlos32ps (zeitlos commit fdc072b)
with the modules renamed. zeitlos32ps is RV32IM with picorv32's
interrupt instructions and an MPU, in four stages, built to pass 48 MHz
in picorv32's area. kakao32 keeps its ALU, multiplier/divider, load and
store units and register file, and replaces the rest step by step.

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
- [ ] **6. The pipeline, for clock.** The cache's hit compare in its
      own stage, the TLB read beside the tag RAM, execute and memory
      as separate stages, branch prediction. Place and route on a 45F
      and a 25F at the highest clock that closes.
- [ ] **Comparison with QEMU**, instruction by instruction, on the
      Linux boot: riscv-tests and a booting kernel do not replace it.

Speed is worked on after Linux runs (step 6 and beyond), not before.

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

`firstlight` on the 45F (the core, 64 KB of block RAM, CLINT, UART):
about 6,900 cells placed, of which the core is about 6,000, against
3,454 before the S-mode, the MMU and the atomics. It passes 48 MHz
(49 to 52 MHz over seeds). The whole SOC for Sergei ML2, with the
32 KB cache and the DDR3 controller, passes too (48.3 and 51.0 MHz on
two seeds) once retired instructions are counted a cycle late: the
counter's enable was at the end of the path from the cache's tag RAM.

To get there the TLB is read twice, for the fetch PC and for X's data
address, each from a register, and a translated load or store takes a
cycle more (the address is registered before the lookup). That cycle
costs: the Linux boot went from 1.83 to 2.21 cycles an instruction.
Step 6 should win it back, for instance by looking up the base
register's page while the adder runs.
