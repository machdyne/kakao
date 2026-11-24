# Sergei ML2 (ECP5 45F, CABGA256).
#
#   make firstlight       build/firstlight.bit: kakao32's first program on
#                         the board (see firstlight.v), at 48 MHz
#   make firstlight24     build/firstlight24.bit: the same at 24 MHz
#   make sim-firstlight   the same design with a terminal on its UART
#   (the SOC itself is built in the directory above: make -C .. BOARD=sergei_ml2)
#   make sim-kboot        kboot's loader, with a host on the UART
#   make sim-sdboot       kboot booting from an SD card's image
#
# Tools: yosys, nextpnr-ecp5 and ecppack (YOSYS=yowasp-yosys and so on
# for the YoWASP builds), Verilator for the simulation, a RISC-V gcc
# for the program. The pin file is Zeitlos's.

YOSYS   ?= yosys
NEXTPNR ?= nextpnr-ecp5
ECPPACK ?= ecppack

SOC = $(CURDIR)/../..
R   = $(SOC)/rtl
FW  = $(SOC)/fw/firstlight
LPF = $(SOC)/ext/zeitlos/boards/sergei_ml2.lpf
RTL = $(CURDIR)/firstlight.v $(R)/k_uart.v $(R)/k_clint.v $(R)/cpu/kakao32/kakao32.v \
	$(R)/cpu/kakao32/kakao32_alu.v $(R)/cpu/kakao32/kakao32_decode.v \
	$(R)/cpu/kakao32/kakao32_lsu.v $(R)/cpu/kakao32/kakao32_muldiv_lean.v

CPU = $(R)/cpu/kakao32/kakao32.v $(R)/cpu/kakao32/kakao32_alu.v \
	$(R)/cpu/kakao32/kakao32_decode.v $(R)/cpu/kakao32/kakao32_lsu.v \
	$(R)/cpu/kakao32/kakao32_muldiv_lean.v
Z   = $(SOC)/ext/zeitlos/rtl
KB  = $(SOC)/fw/kboot
IOP = $(SOC)/fw/iop
SOCRTL = $(R)/kakao_soc.v $(R)/k_uart.v $(R)/k_vcon.v $(R)/k_clint.v $(R)/k_plic.v $(R)/k_cache.v $(R)/k_iop.v $(R)/k_text.v \
	$(Z)/cpu/picorv32/picorv32.v $(Z)/cache_one.v $(CPU)
# K64=1: the same with kakao64 and kboot built for it
ifeq ($(K64),1)
SOCRTL += $(R)/k_port64.v $(wildcard $(R)/cpu/kakao64/*.v)
KG = -GCPU64=1 -GKROM='"../../fw/kboot/kboot64"'
KHEX = $(KB)/kboot64.0.hex
else
KHEX = $(KB)/kboot.0.hex
endif
$(KB)/kboot64.0.hex: $(KB)/main.c $(KB)/crt0.S $(KB)/link.ld $(SOC)/ext/zeitlos/sw/bios/bios.c
	$(MAKE) -C $(KB) XLEN=64
firstlight: build/firstlight.bit

$(KB)/kboot.0.hex: $(KB)/main.c $(KB)/crt0.S $(KB)/link.ld $(SOC)/ext/zeitlos/sw/bios/bios.c
	$(MAKE) -C $(KB)

sim-kboot: $(KHEX)
	@mkdir -p build
	verilator --binary --timing -DSYNTHESIS -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
		-Wno-CASEINCOMPLETE -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_kboot $(KG) \
		-Mdir $(CURDIR)/build/simkboot -o sim $(CURDIR)/tb_kboot.v $(SOCRTL) $(Z)/spim.v \
		$(SOC)/sim/sd_model.v > build/simkboot.log 2>&1
	build/simkboot/sim

# kboot booting from the SD card: Zeitlos's SPI master, a card model
# (soc/sim/sd_model.v) and two cards made here with mtools and
# dosfstools: FAT16 with no partition table, and FAT32 in a partition.
# On each, /sys/linux/boot.json names a program with a long name beside
# it and a file in the root, which the program prints a byte from.
# (the program: lui a0, 0x80021; lbu a0, 0(a0); lui a1, 0x10000;
# sb a0, 0(a1); j .)
sim-sdboot: $(KHEX)
	@mkdir -p build/card
	python3 -c "import struct; open('build/card/a-program-with-a-long-name.bin','wb').write(struct.pack('<5I', 0x80021537, 0x00054503, 0x100005b7, 0x00a58023, 0x0000006f))"
	python3 -c "open('build/card/data.bin','wb').write(bytes(0x11000) + b'K' + bytes(4095))"
	printf '{\n\t"a-program-with-a-long-name.bin": "0x80000000",\n\t"/DATA.BIN": "0x80010000",\n\t"bootargs": { "r1": "0x0" }\n}\n' > build/card/boot.json
	rm -f build/card/fat16.img build/card/fat32.img
	mkfs.vfat -F 16 -C build/card/fat16.img 16384 > /dev/null
	truncate -s 48M build/card/fat32.img
	mkfs.vfat -F 32 --offset 2048 build/card/fat32.img > /dev/null
	python3 -c "import struct; f=open('build/card/fat32.img','r+b'); f.seek(446); f.write(struct.pack('<BBBBBBBBII',0,0,0,0,0x0c,0,0,0,2048,48*2048-2048)); f.seek(510); f.write(b'\x55\xaa')"
	for i in build/card/fat16.img build/card/fat32.img@@1M; do \
		mmd -i $$i ::/sys ::/sys/linux && \
		mcopy -i $$i build/card/boot.json build/card/a-program-with-a-long-name.bin ::/sys/linux/ && \
		mcopy -i $$i build/card/data.bin ::/DATA.BIN || exit 1; done
	for i in fat16 fat32; do \
		verilator --binary --timing -DSYNTHESIS -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
			-Wno-CASEINCOMPLETE -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_kboot \
			-GSD='"build/card/'$$i'.img"' $(KG) \
			-Mdir $(CURDIR)/build/simsd -o sim $(CURDIR)/tb_kboot.v $(SOCRTL) $(Z)/spim.v \
			$(SOC)/sim/sd_model.v > build/simsd.log 2>&1 || { tail build/simsd.log; exit 1; }; \
		echo "== $$i"; build/simsd/sim || exit 1; done

firstlight24: build/firstlight24.bit

SEED ?= 2
# The placer is told to weigh timing more than it does by itself: the
# design is a third of the device and its longest paths are mostly wire,
# and with this the same seeds place 3 to 8 MHz faster.
PNRFLAGS ?= --placer-heap-timingweight 60

$(FW)/firstlight.0.hex: $(FW)/main.c $(FW)/crt0.S $(FW)/link.ld
	$(MAKE) -C $(FW)

# (synthesis runs in the program's directory: the block RAM's contents
# are read from firstlight.N.hex there)
build/firstlight.json: $(RTL) $(FW)/firstlight.0.hex
	@mkdir -p build
	cd $(FW) && $(YOSYS) -q -l $(CURDIR)/build/firstlight.synth.log \
		-p "read_verilog -DSYNTHESIS $(RTL); synth_ecp5 -abc9 -top firstlight -json $(CURDIR)/$@"

build/firstlight24.json: $(RTL) $(FW)/firstlight.0.hex
	@mkdir -p build
	cd $(FW) && $(YOSYS) -q -l $(CURDIR)/build/firstlight24.synth.log \
		-p "read_verilog -DSYNTHESIS -DFIRSTLIGHT_PLL24 $(RTL); chparam -set UART_DIV 24 firstlight; synth_ecp5 -abc9 -top firstlight -json $(CURDIR)/$@"

build/%.config: build/%.json
	$(NEXTPNR) --45k --package CABGA256 --lpf $(LPF) --lpf-allow-unconstrained $(PNRFLAGS) \
		--json $< --textcfg $@ -l build/$*.pnr.log --seed $(SEED) -q
	@grep "Max frequency" build/$*.pnr.log | tail -1

build/%.bit: build/%.config
	$(ECPPACK) --compress --freq 2.4 $< --bit $@

sim-firstlight: $(FW)/firstlight.0.hex
	@mkdir -p build
	verilator --binary --timing -DSYNTHESIS -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
		-Wno-CASEINCOMPLETE -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_firstlight \
		-Mdir $(CURDIR)/build/sim -o sim $(CURDIR)/tb_firstlight.v $(RTL) > build/sim.log 2>&1
	build/sim/sim

clean:
	rm -rf build

.PHONY: firstlight firstlight24 sim-firstlight sim-kboot sim-sdboot clean
.PRECIOUS: build/%.json build/%.config
