# Linux on kakao32 in simulation. See README.md.
#
#   make                 build the simulator (obj/sim) and the device tree
#   make boot OPENSBI=<fw_jump.bin> [IMAGE=<Image>] [INITRD=<rootfs.cpio>] [DTB=<dtb>]
#                        [TYPE=<script>] [MAX=<cycles>] [SIM=simsoc]
#
# obj/sim is the CPU on an ideal memory; obj/simsoc is the SOC, with the
# cache and a memory that takes its time.

R   = $(CURDIR)/../rtl/cpu/kakao32
RTL = $(CURDIR)/sim_top.v $(R)/kakao32.v $(R)/kakao32_alu.v $(R)/kakao32_decode.v \
	$(R)/kakao32_lsu.v $(R)/kakao32_muldiv_lean.v

IMAGE  ?= ../../images/Image
INITRD ?= ../../images/rootfs.cpio
MAX    ?= 4000000000

Z   = $(CURDIR)/../ext/zeitlos/rtl
SOCRTL = $(CURDIR)/sim_soc.v $(CURDIR)/../rtl/kakao_soc.v $(CURDIR)/../rtl/k_uart.v $(CURDIR)/../rtl/k_port64.v $(wildcard $(CURDIR)/../rtl/cpu/kakao64/*.v) \
	$(CURDIR)/../rtl/k_clint.v $(CURDIR)/../rtl/k_plic.v $(CURDIR)/../rtl/k_cache.v $(CURDIR)/../rtl/k_iop.v $(CURDIR)/../rtl/k_vcon.v \
	$(CURDIR)/../rtl/k_text.v $(CURDIR)/../rtl/k_virtio.v $(CURDIR)/sd_card.v $(CURDIR)/rmii_peer.v $(Z)/spim.v $(Z)/ethmac_rmii.v $(Z)/cpu/picorv32/picorv32.v $(Z)/cache_one.v $(filter-out %/sim_top.v,$(RTL))
CROSS ?= riscv64-unknown-elf-
CACHE_KB ?= 8
# SOCG: more parameters for sim_soc (-GTERMINAL=1: with the terminal, and
# its screen is printed at the end), SOCBIN: the binary's name
SOCG ?=
SOCBIN ?= simsoc
# SIMC: -DSIMKEYS for a build with several terminals, so that script
# lines "@n ..." can be typed at terminal n
SIMC ?=

all: obj/sim obj/simsoc obj/kakao-sim.dtb

obj/sim: $(RTL) sim_main.cpp
	verilator --cc --exe --build -j 2 -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -DSYNTHESIS \
		-CFLAGS -O2 --top-module sim_top -Mdir $(CURDIR)/obj/sim.d -o ../sim \
		$(RTL) $(CURDIR)/sim_main.cpp > obj.log 2>&1 || { tail -20 obj.log; exit 1; }

# the whole SOC: the cache and the bus, and a model of main memory
obj/$(SOCBIN): $(SOCRTL) sim_main.cpp obj/boot.0.hex obj/k_font.hex ../fw/iop/iop.hex
	verilator --cc --exe --build -j 2 -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -DSYNTHESIS -DK_CACHE_STATS -DK_PROFILE $(SOCD) \
		-CFLAGS "-O2 -DSOC $(SIMC)" --prefix Vsim_top --top-module sim_soc -GCACHE_KB=$(CACHE_KB) $(SOCG) \
		-Mdir $(CURDIR)/obj/$(SOCBIN).d -o ../$(SOCBIN) \
		$(SOCRTL) $(CURDIR)/sim_main.cpp > objsoc.log 2>&1 || { tail -20 objsoc.log; exit 1; }

obj/boot.0.hex: boot.S
	@mkdir -p obj
	$(CROSS)gcc -march=rv32i -mabi=ilp32 -nostdlib -Ttext=0x1000 $(BOOTDEFS) boot.S -o obj/boot.elf
	$(CROSS)objcopy -O binary obj/boot.elf obj/boot.bin
	python3 -c "d=open('obj/boot.bin','rb').read(); n=4096; assert len(d) <= 4096, 'boot: %d bytes, too big' % len(d); d+=bytes(n-len(d)); [open('obj/boot.%d.hex'%k,'w').write(''.join('%02x\n'%b for b in d[k::4])) for k in range(4)]"

# ...and where a 64 bit machine has them: OpenSBI at the bottom of
# memory, the device tree at 0x87f0_0000
obj/boot64.0.hex: boot.S
	@mkdir -p obj
	$(CROSS)gcc -march=rv32i -mabi=ilp32 -nostdlib -Ttext=0x1000 -DSBI_AT=0x80000000 -DDTB_AT=0x87f00000 boot.S -o obj/boot64.elf
	$(CROSS)objcopy -O binary obj/boot64.elf obj/boot64.bin
	python3 -c "d=open('obj/boot64.bin','rb').read(); n=4096; d+=bytes(n-len(d)); [open('obj/boot64.%d.hex'%k,'w').write(''.join('%02x\n'%b for b in d[k::4])) for k in range(4)]"

# the SOC with kakao64 (docs/kakao64.md)
sim64: obj/boot64.0.hex
	$(MAKE) obj/simsoc64 SOCBIN=simsoc64 SIMC="-DCPU64 $(SIMC)" \
		SOCG="-GCPU64=1 -GMEM_MB=256 -GKCACHE=1 -GI_KB=16 -GBOOT_HEX='\"obj/boot64\"' $(SOCG)"

obj/k_font.hex: ../tools/mkfont.py
	@mkdir -p obj
	python3 ../tools/mkfont.py ../ext/zeitlos/sw/data/font/font16.mem $@

../fw/iop/iop.hex: FORCE
	$(MAKE) -C ../fw/iop
FORCE:

obj/kakao-sim.dtb: kakao-sim.dts
	@mkdir -p obj
	dtc -q -I dts -O dtb -o $@ $<

SIM ?= sim
DTB ?= obj/kakao-sim.dtb
boot: all
	@test -n "$(OPENSBI)" || { echo "make boot OPENSBI=<fw_jump.bin>  (see README.md)"; exit 1; }
	obj/$(SIM) +load=$(OPENSBI)@81e00000 +load=$(IMAGE)@80000000 \
		+load=$(INITRD)@81000000 +load=$(DTB)@81f00000 \
		+max=$(MAX) $(if $(TYPE),+type=$(TYPE))

# the SOC on Zeitlos's DDR3 controller and its DRAM model, running
# fw/memtest (Icarus: the model works with delays and tri-states)
KC ?= 1
WC ?= 1
ddr3:
	$(MAKE) -C ../fw/memtest
	@mkdir -p obj
	iverilog -g2012 -DSYNTHESIS -Ptb_soc_ddr3.KC=$(KC) -Ptb_soc_ddr3.WC=$(WC) -o obj/tb_soc_ddr3 \
		tb_soc_ddr3.v $(Z)/tb/ddr3_model.v $(Z)/tb/ddr3_phy_sim.v $(Z)/mem/ddr3_ctrl.v \
		$(filter-out %/sim_soc.v,$(SOCRTL))
	vvp -n obj/tb_soc_ddr3

# the SOC alone, running a program from its boot memory (Icarus)
ROM ?= plictest
rom:
	$(MAKE) -C ../fw/$(ROM)
	@mkdir -p obj
	iverilog -g2012 -DSYNTHESIS -Ptb_soc_rom.ROM='"../fw/$(ROM)/$(ROM)"' -o obj/tb_soc_rom \
		tb_soc_rom.v $(filter-out %/sim_soc.v,$(SOCRTL))
	vvp -n obj/tb_soc_rom

clean:
	rm -rf obj obj.log objsoc.log

.PHONY: all boot ddr3 rom clean

# The I/O processor with a USB keyboard, on a root port and behind a
# hub: see tb_iop_usb.v. Icarus Verilog, since Zeitlos's device model
# is written for it.
USBRTL = $(Z)/usb/usb_host.v $(Z)/usb/usb_sie.v $(Z)/usb/usb_port.v $(Z)/usb/usb_xact.v \
	$(Z)/usb/usb_hid_compat.v
usb:
	@mkdir -p obj
	$(MAKE) -C ../fw/iop
	iverilog -g2005 -DMT_AFTER=3 -o obj/tb_iop_usb -s tb_iop_usb tb_iop_usb.v ../rtl/k_iop.v \
		$(Z)/cpu/picorv32/picorv32.v $(USBRTL) $(Z)/tb/tb_usb_device.v
	iverilog -g2005 -DNOMOUSE -P tb_iop_usb.HUB=1 -o obj/tb_iop_usb_hub -s tb_iop_usb tb_iop_usb.v ../rtl/k_iop.v \
		$(Z)/cpu/picorv32/picorv32.v $(USBRTL) $(Z)/tb/tb_usb_device.v
	vvp -n obj/tb_iop_usb | grep -v "^\[\|VCD"
	vvp -n obj/tb_iop_usb_hub | grep -v "^\[\|VCD"

# the mouse plugged in at the end of the keyboard's test, 8 ms after the
# last key: known to fail; MT_DELAY=960000 (20 ms later) passes
# (tb_iop_usb.v says what is known)
usb-late:
	@mkdir -p obj
	$(MAKE) -C ../fw/iop
	iverilog -g2005 $(if $(MT_DELAY),-DMT_DELAY=$(MT_DELAY)) -o obj/tb_iop_usb_late -s tb_iop_usb tb_iop_usb.v ../rtl/k_iop.v \
		$(Z)/cpu/picorv32/picorv32.v $(USBRTL) $(Z)/tb/tb_usb_device.v
	vvp -n obj/tb_iop_usb_late | grep -v "^\[\|VCD"

.PHONY: usb usb-late

# the SOC on Zeitlos's SDRAM controller and its model of the SDRAM,
# running fw/memtest (Icarus): see tb_soc_sdram.v
sdram:
	$(MAKE) -C ../fw/memtest
	@mkdir -p obj
	iverilog -g2012 -DSYNTHESIS -o obj/tb_soc_sdram tb_soc_sdram.v $(Z)/tb/sdram_model.v \
		$(Z)/mem/sdram_kianv.v $(filter-out %/sim_soc.v,$(SOCRTL))
	vvp -n obj/tb_soc_sdram

.PHONY: sdram
