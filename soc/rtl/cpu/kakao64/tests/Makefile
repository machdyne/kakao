# kakao64 test suite
#
#   make              riscv-tests (rv64ui, rv64um, rv64ua, rv64mi, rv64si, and
#                     rv64ui, rv64um and rv64ua again under Sv39 in
#                     their supervisor, the "v" environment) and this
#                     directory's own tests, at fixed wait-state
#                     latencies and with random latency and a busy port
#   make quick        the same at latency 0 and one random run
#   make one T=rv64ui-add LAT=0 [TRACE=1]
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
TLB_BITS ?= 5
TRACE    ?= 0

RT  = ../../../../ext/riscv-tests
RTL = ../kakao64.v ../kakao64_alu.v ../kakao64_decode.v ../kakao64_lsu.v \
	../kakao64_muldiv_lean.v ../kakao64_cexp.v

CFLAGS = -march=rv64imafdc_zicsr_zifencei -mabi=lp64 -static -mcmodel=medany \
	-fvisibility=hidden -nostdlib -nostartfiles \
	-I$(RT)/env/p -I$(RT)/isa/macros/scalar -T$(RT)/env/p/link.ld

# Not run, and why:
#   rv64mi-breakpoint   needs the debug triggers (tselect), which are not here
#   rv64mi-pmpaddr      needs PMP, which is not here
#   rv64ui-ma_data      needs misaligned loads and stores to work; here they
#                       trap, for the SBI firmware to emulate
SKIP = rv64mi-breakpoint rv64mi-pmpaddr rv64ui-ma_data v-rv64ui-ma_data

UI := $(patsubst $(RT)/isa/rv64ui/%.S,rv64ui-%,$(wildcard $(RT)/isa/rv64ui/*.S))
UM := $(patsubst $(RT)/isa/rv64um/%.S,rv64um-%,$(wildcard $(RT)/isa/rv64um/*.S))
MI := $(patsubst $(RT)/isa/rv64mi/%.S,rv64mi-%,$(wildcard $(RT)/isa/rv64mi/*.S))
UA := $(patsubst $(RT)/isa/rv64ua/%.S,rv64ua-%,$(wildcard $(RT)/isa/rv64ua/*.S))
UC := $(patsubst $(RT)/isa/rv64uc/%.S,rv64uc-%,$(wildcard $(RT)/isa/rv64uc/*.S))
# of F and D, what the core does itself (the rest is the firmware's,
# and is tested with it: soc/sim)
FP := $(foreach t,fclass ldst move fcmp,rv64uf-$(t) rv64ud-$(t))
SI := $(patsubst $(RT)/isa/rv64si/%.S,rv64si-%,$(wildcard $(RT)/isa/rv64si/*.S))
OWN := $(patsubst prog/%.S,own-%,$(wildcard prog/*.S))
# the same user-level tests under the "v" environment
V  := $(patsubst rv64u%,v-rv64u%,$(UI) $(UM) $(UA) $(UC))
TESTS = $(filter-out $(SKIP),$(UI) $(UM) $(UA) $(UC) $(FP) $(MI) $(SI) $(V)) $(OWN)

# (F only so that the assembler accepts the one FP instruction vm.c
# holds up for comparison; nothing executes it)
VFLAGS = -march=rv64imafdc_zicsr_zifencei -mabi=lp64 -static -mcmodel=medany \
	-fvisibility=hidden -nostdlib -nostartfiles -std=gnu99 -O2 -ffreestanding \
	-Ilibc -I$(RT)/env/v -I$(RT)/isa/macros/scalar -T$(RT)/env/v/link.ld
VSRC = $(RT)/env/v/entry.S $(RT)/env/v/vm.c $(RT)/env/v/string.c

LATS  = 0 1 3 12
SEEDS = 1 2 3

all: run

build/rv64ui-%.elf: $(RT)/isa/rv64ui/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64um-%.elf: $(RT)/isa/rv64um/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64mi-%.elf: $(RT)/isa/rv64mi/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64ua-%.elf: $(RT)/isa/rv64ua/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64uc-%.elf: $(RT)/isa/rv64uc/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64uf-%.elf: $(RT)/isa/rv64uf/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64ud-%.elf: $(RT)/isa/rv64ud/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/rv64si-%.elf: $(RT)/isa/rv64si/%.S
	@mkdir -p build; $(CC) $(CFLAGS) $< -o $@
build/v-rv64ui-%.elf: $(RT)/isa/rv64ui/%.S $(VSRC)
	@mkdir -p build; $(CC) $(VFLAGS) -DENTROPY=0x$$(echo $* | md5sum | cut -c 1-7) $(VSRC) $< -o $@
build/v-rv64um-%.elf: $(RT)/isa/rv64um/%.S $(VSRC)
	@mkdir -p build; $(CC) $(VFLAGS) -DENTROPY=0x$$(echo $* | md5sum | cut -c 1-7) $(VSRC) $< -o $@
build/v-rv64ua-%.elf: $(RT)/isa/rv64ua/%.S $(VSRC)
	@mkdir -p build; $(CC) $(VFLAGS) -DENTROPY=0x$$(echo $* | md5sum | cut -c 1-7) $(VSRC) $< -o $@
build/v-rv64uc-%.elf: $(RT)/isa/rv64uc/%.S $(VSRC)
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
	-Wno-CASEINCOMPLETE -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_kakao64 -o sim \
	-GFAST_MUL=$(FAST_MUL) -GBTFN=$(BTFN) -GBTB_BITS=$(BTB_BITS) -GFAST_XLATE=$(FAST_XLATE) -GTLB_BITS=$(TLB_BITS) -GTRACE=$(TRACE)
SRC = $(CURDIR)/tb_kakao64.v $(abspath $(RTL))

# (the core's options are compiled in: build/options changes when they do)
OPTS = $(FAST_MUL) $(BTFN) $(BTB_BITS) $(FAST_XLATE) $(TLB_BITS) $(TRACE)
build/options: FORCE
	@mkdir -p build
	@echo "$(OPTS)" | cmp -s - $@ || echo "$(OPTS)" > $@
FORCE:

build/tb_l%/sim: tb_kakao64.v $(RTL) build/options
	@mkdir -p build
	@$(VERILATE) -GLAT=$* -Mdir $(CURDIR)/build/tb_l$* $(SRC) > build/tb_l$*.log 2>&1 || { tail build/tb_l$*.log; exit 1; }

build/tb_rl%/sim: tb_kakao64.v $(RTL) build/options
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

T ?= rv64ui-add
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
