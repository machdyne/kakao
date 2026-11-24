# kakao32 test suite
#
#   make              riscv-tests (rv32ui, rv32um, rv32ua, rv32mi, rv32si, and
#                     rv32ui, rv32um and rv32ua again under Sv32 in
#                     their supervisor, the "v" environment) and this
#                     directory's own tests, at fixed wait-state
#                     latencies and with random latency and a busy port
#   make quick        the same at latency 0 and one random run
#   make one T=rv32ui-add LAT=0 [TRACE=1]
#
# The result files are not remade when the RTL changes: make clean-results
# (or clean) first.
#
# riscv-tests is a submodule: git submodule update --init --recursive
# soc/ext/riscv-tests. Needs Verilator (5 or later) and a RISC-V gcc
# (CROSS=riscv64-unknown-elf- by default; no C library is used).

.SUFFIXES:

CROSS    ?= riscv64-unknown-elf-
CC        = $(CROSS)gcc
OBJCOPY   = $(CROSS)objcopy
NM        = $(CROSS)nm
FAST_MUL ?= 0
# the core's options: static branch prediction, one-cycle translated loads
BTFN ?= 0
BTB_BITS ?= 6
FAST_XLATE ?= 1
TRACE    ?= 0

RT  = ../../../../ext/riscv-tests
RTL = ../kakao32.v ../kakao32_alu.v ../kakao32_decode.v ../kakao32_lsu.v \
	../kakao32_muldiv_lean.v

CFLAGS = -march=rv32ima_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
	-fvisibility=hidden -nostdlib -nostartfiles \
	-I$(RT)/env/p -I$(RT)/isa/macros/scalar -T$(RT)/env/p/link.ld

# Not run, and why:
#   rv32mi-breakpoint   needs the debug triggers (tselect), which are not here
#   rv32mi-pmpaddr      needs PMP, which is not here
#   rv32ui-ma_data      needs misaligned loads and stores to work; here they
#                       trap, for the SBI firmware to emulate
SKIP = rv32mi-breakpoint rv32mi-pmpaddr rv32ui-ma_data v-rv32ui-ma_data

UI := $(patsubst $(RT)/isa/rv32ui/%.S,rv32ui-%,$(wildcard $(RT)/isa/rv32ui/*.S))
UM := $(patsubst $(RT)/isa/rv32um/%.S,rv32um-%,$(wildcard $(RT)/isa/rv32um/*.S))
MI := $(patsubst $(RT)/isa/rv32mi/%.S,rv32mi-%,$(wildcard $(RT)/isa/rv32mi/*.S))
UA := $(patsubst $(RT)/isa/rv32ua/%.S,rv32ua-%,$(wildcard $(RT)/isa/rv32ua/*.S))
SI := $(patsubst $(RT)/isa/rv32si/%.S,rv32si-%,$(wildcard $(RT)/isa/rv32si/*.S))
OWN := $(patsubst prog/%.S,own-%,$(wildcard prog/*.S))
# the same user-level tests under the "v" environment
V  := $(patsubst rv32u%,v-rv32u%,$(UI) $(UM) $(UA))
TESTS = $(filter-out $(SKIP),$(UI) $(UM) $(UA) $(MI) $(SI) $(V)) $(OWN)

# (F only so that the assembler accepts the one FP instruction vm.c
# holds up for comparison; nothing executes it)
VFLAGS = -march=rv32imaf_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
	-fvisibility=hidden -nostdlib -nostartfiles -std=gnu99 -O2 -ffreestanding \
	-Ilibc -I$(RT)/env/v -I$(RT)/isa/macros/scalar -T$(RT)/env/v/link.ld
VSRC = $(RT)/env/v/entry.S $(RT)/env/v/vm.c $(RT)/env/v/string.c

LATS  = 0 1 3 12
SEEDS = 1 2 3

all: run

build/rv32ui-%.elf: $(RT)/isa/rv32ui/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv32um-%.elf: $(RT)/isa/rv32um/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv32mi-%.elf: $(RT)/isa/rv32mi/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv32ua-%.elf: $(RT)/isa/rv32ua/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv32si-%.elf: $(RT)/isa/rv32si/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/v-rv32ui-%.elf: $(RT)/isa/rv32ui/%.S $(VSRC)
	@mkdir -p build; $(CC) $(VFLAGS) -DENTROPY=0x$$(echo $* | md5sum | cut -c 1-7) $(VSRC) $< -o $@
build/v-rv32um-%.elf: $(RT)/isa/rv32um/%.S $(VSRC)
	@mkdir -p build; $(CC) $(VFLAGS) -DENTROPY=0x$$(echo $* | md5sum | cut -c 1-7) $(VSRC) $< -o $@
build/v-rv32ua-%.elf: $(RT)/isa/rv32ua/%.S $(VSRC)
	@mkdir -p build; $(CC) $(VFLAGS) -DENTROPY=0x$$(echo $* | md5sum | cut -c 1-7) $(VSRC) $< -o $@
build/own-%.elf: prog/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/%.hex: build/%.elf
	@$(OBJCOPY) -O verilog --verilog-data-width=4 --change-addresses=-0x80000000 $< $@
	@$(NM) $< | awk '$$3 == "tohost" { print $$1 }' > build/$*.tohost

HEX = $(addprefix build/,$(addsuffix .hex,$(TESTS)))

# The test bench is compiled with Verilator, once per configuration
# (build/tb_<cfg>/sim): Icarus runs these many times slower.
VERILATE = verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
	-Wno-CASEINCOMPLETE -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_kakao32 -o sim \
	-GFAST_MUL=$(FAST_MUL) -GBTFN=$(BTFN) -GBTB_BITS=$(BTB_BITS) -GFAST_XLATE=$(FAST_XLATE) -GTRACE=$(TRACE)
SRC = $(CURDIR)/tb_kakao32.v $(abspath $(RTL))

build/tb_l%/sim: tb_kakao32.v $(RTL)
	@mkdir -p build
	@$(VERILATE) -GLAT=$* -Mdir $(CURDIR)/build/tb_l$* $(SRC) > build/tb_l$*.log 2>&1 || { tail build/tb_l$*.log; exit 1; }

build/tb_rl%/sim: tb_kakao32.v $(RTL)
	@mkdir -p build
	@$(VERILATE) -GLAT=12 -GRANDLAT=1 -GBUSY=1 -GSEED=$* -Mdir $(CURDIR)/build/tb_rl$* $(SRC) > build/tb_rl$*.log 2>&1 || { tail build/tb_rl$*.log; exit 1; }

# One target per configuration (make -j runs them side by side), each
# leaving build/result-<cfg>.txt: a line for every failure and a count.
CFGS = $(addprefix l,$(LATS)) $(addprefix rl,$(SEEDS))

build/result-%.txt: build/tb_%/sim $(HEX)
	@n=0; bad=0; : > $@.tmp; \
	for t in $(TESTS); do \
		r=`build/tb_$*/sim +hex=build/$$t.hex +tohost=$$(cat build/$$t.tohost) | grep -E "PASS|FAIL"`; \
		n=$$((n+1)); \
		echo "$$r" | grep -q PASS || { bad=$$((bad+1)); echo "  $*  $$t  $$r" >> $@.tmp; }; \
	done; \
	echo "== $*: $$((n-bad)) of $$n pass" >> $@.tmp; mv $@.tmp $@

run: $(addprefix build/result-,$(addsuffix .txt,$(CFGS)))
	@cat $^; if grep -q "FAIL" $^; then echo "FAILURES"; exit 1; else echo "ALL PASS"; fi

# the quick check while working: no wait states, and one random run
quick: build/result-l0.txt build/result-rl1.txt
	@cat $^; if grep -q "FAIL" $^; then echo "FAILURES"; exit 1; else echo "ALL PASS"; fi

T ?= rv32ui-add
LAT ?= 0
one: build/$(T).hex
	@rm -rf build/tb_l$(LAT); $(MAKE) -s build/tb_l$(LAT)/sim TRACE=$(TRACE)
	build/tb_l$(LAT)/sim +hex=build/$(T).hex +tohost=$$(cat build/$(T).tohost)

clean-results:
	rm -rf build/result-*.txt build/tb_*

clean:
	rm -rf build

.PRECIOUS: build/%.elf build/%.hex build/tb_l%/sim build/tb_rl%/sim
.PHONY: all run quick one clean clean-results
