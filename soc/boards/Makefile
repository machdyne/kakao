# The Kakao SOC for Machdyne's ECP5 boards (kakao_top.v).
#
#   make BOARD=<board>          build/<board>/kakao.bit, kakao.dtb and
#                               boot.json: the bitstream, and what goes on
#                               the SD card beside OpenSBI, the kernel and
#                               the root file system (README.md)
#   make BOARD=<board> seeds    the same, placed with each of SEEDS and the
#                               fastest that meets 48 MHz kept (FIRST=1:
#                               the first that does)
#   make BOARD=<board> synth    only build/<board>/kakao.json, and what it
#                               takes of the FPGA (build/<board>/synth.log)
#   make boards                 the boards there are
#   make release                every board's bitstream and card files as
#                               zips in build/release, with a summary
#                               (../tools/release.sh; RELEASE="-v 1.0 -c <dir>"
#                               and so on are its options)
#
# Boards: sergei_ml2 mozart_ml2 (45F, 512 MB DDR3), sergei_ml1 mozart_ml1
# (45F, 32 MB SDRAM), sergei_ml0 mozart_ml0 lakritz (25F, 32 MB SDRAM),
# konfekt (12F, 32 MB SDRAM), klinge (25F, 512 MB DDR3; no monitor, no
# keyboard: the serial console only, and an I/O processor for the disk
# and the network alone).
#
# What a board gets can be changed on the command line:
#
#   TERMINAL=0    no terminal: no picture, no keyboard, the serial console only
#   TERMS=n       consoles, each with its own terminal (1..10)
#   HIST=n        screens of scroll buffer for the first terminal (0..3)
#   USB=0         no USB host: the terminal without a keyboard
#   VIRTIO=n      virtio slots (2: the SD card as a disk and the network;
#                 0: none, and without a terminal no I/O processor)
#   I_KB=, D_KB=  the caches' sizes
#   FAST_MUL=0    the multiplier in 32 steps instead of in DSP blocks
#   KCACHE=0      Zeitlos's cache instead of k_cache
#   LAYOUTS=      the keyboard layouts built in (fw/iop)
#
# Tools: yosys, nextpnr-ecp5 and ecppack (YOSYS=yowasp-yosys and so on
# for the YoWASP builds), a RISC-V gcc for the programs, dtc. The pin
# files are Zeitlos's.

YOSYS   ?= yosys
NEXTPNR ?= nextpnr-ecp5
ECPPACK ?= ecppack

BOARD ?= sergei_ml2

# -- the boards --
# MEM: ddr3 (512 MB) or sdram (32 MB); VIDEO, USBH: 1 if the board has
# a DDMI connector, USB host ports; ETH: the board has an RMII Ethernet
# PHY, whose 50 MHz the FPGA makes (drive) or the PHY itself (phy)

ifeq ($(BOARD),sergei_ml2)
  NAME = Machdyne Sergei, Sechzig ML2
  DEVICE = 45k
  PINS = sergei_ml2.lpf
  MEM = ddr3
  VIDEO = 1
  USBH = 1
  ETH = drive
else ifeq ($(BOARD),mozart_ml2)
  NAME = Machdyne Mozart, Sechzig ML2
  DEVICE = 45k
  PINS = mozart_ml2.lpf
  MEM = ddr3
  VIDEO = 1
  USBH = 1
  ETH = phy
else ifeq ($(BOARD),sergei_ml1)
  NAME = Machdyne Sergei, Sechzig ML1
  DEVICE = 45k
  PINS = sergei_ml1.lpf
  MEM = sdram
  VIDEO = 1
  USBH = 1
  ETH = drive
else ifeq ($(BOARD),mozart_ml1)
  NAME = Machdyne Mozart, Sechzig ML1
  DEVICE = 45k
  PINS = mozart_ml1.lpf
  MEM = sdram
  VIDEO = 1
  USBH = 1
  ETH = phy
else ifeq ($(BOARD),sergei_ml0)
  NAME = Machdyne Sergei, Sechzig ML0
  DEVICE = 25k
  PINS = sergei_ml1.lpf
  MEM = sdram
  VIDEO = 1
  USBH = 1
  ETH = drive
else ifeq ($(BOARD),mozart_ml0)
  NAME = Machdyne Mozart, Sechzig ML0
  DEVICE = 25k
  PINS = mozart_ml1.lpf
  MEM = sdram
  VIDEO = 1
  USBH = 1
  ETH = phy
else ifeq ($(BOARD),lakritz)
  NAME = Machdyne Lakritz
  DEVICE = 25k
  PINS = lakritz_v0.lpf
  MEM = sdram
  VIDEO = 1
  USBH = 1
  CONSOLE = usb
else ifeq ($(BOARD),konfekt)
  NAME = Machdyne Konfekt
  DEVICE = 12k
  PINS = konfekt_v0.lpf
  MEM = sdram
  VIDEO = 1
  USBH = 1
  CONSOLE = usb
else ifeq ($(BOARD),klinge)
  NAME = Machdyne Klinge
  DEVICE = 25k
  PINS = klinge_v1.lpf
  MEM = ddr3
  VIDEO = 0
  USBH = 0
  CONSOLE = usb
  ETH = drive
else
  $(error no board "$(BOARD)": see "make boards")
endif

BOARDS = sergei_ml2 mozart_ml2 sergei_ml1 mozart_ml1 sergei_ml0 mozart_ml0 lakritz konfekt klinge

# -- what a board gets, by what it has room for --
# (block RAM decides: the 45F has 108 blocks, the 25F and the 12F 56)

KCACHE   ?= 1
BTFN     ?= 0
D_KB     ?= 16
ifeq ($(DEVICE),45k)
  I_KB     ?= 64
  FAST_MUL ?= 1
  # eight terminals, and two screens more of cells as the first one's
  # scroll buffer (60 rows): the block RAM that ten terminals took
  TERMS    ?= 8
  HIST     ?= 2
else
  # (the 12F is the 25F's die, and all of it is there for these tools)
  # With the disk, the network and the mouse the I/O processor's program
  # is 44 KB, 20 of the 56 blocks: two terminals fit beside it, and one
  # where there is an Ethernet MAC too (three blocks).
  I_KB     ?= 16
  FAST_MUL ?= 1
  ifeq ($(ETH),)
    TERMS  ?= 2
  else
    TERMS  ?= 1
  endif
endif
ifeq ($(VIDEO)$(USBH),11)
  TERMINAL ?= 1
else
  TERMINAL ?= 0
endif
USB ?= $(USBH)
# screens of scroll buffer for the first terminal (0..3; a screen is 30
# rows and about two and a half block RAMs)
HIST ?= 0
VIRTIO ?= 2
ifeq ($(TERMINAL),0)
  # no terminal: with virtio slots the I/O processor has the program for
  # them alone, in 8 KB
  override TERMS = 1
  override USB = 0
  ifneq ($(VIRTIO),0)
    override IOP_WORDS = 2048
    HEADLESS = 1
  endif
endif

ifeq ($(MEM),ddr3)
  MEM_MB  = 512
  MEMORY  = 512 MB DDR3
  ROM     = kboot
else
  MEM_MB  = 32
  MEMORY  = 32 MB SDRAM
  ROM     = kboot-sdram
endif
# where the boot puts things: the same on every board, in the first
# 32 MB. The kernel at the bottom (Linux cannot use what lies below
# it), OpenSBI and the device tree at the top.
SBI_AT  = 0x81e00000
INITRD  = 0x81000000
DTB_AT  = 0x81f00000
# CPU64=1: kakao64 instead of kakao32 (docs/kakao64.md), built beside the
# other as build/<board>-64. Its memory is laid out as QEMU's virt lays
# it out for RV64: OpenSBI at the bottom, the kernel 2 MB above it. The
# root file system is the SD card's second partition.
CPU64 ?= 0
comma := ,
ifeq ($(CPU64),1)
  override ROM := $(subst kboot,kboot64,$(ROM))
  SBI_AT  = 0x80000000
  KERN_AT = 0x80200000
  DTB_AT  = 0x87f00000
  ISA     = rv64imafdc
  BOOTARGS ?= root=/dev/vda2 rw rootwait
  SUF     = -64
else
  KERN_AT = 0x80000000
  ISA     = rv32ima
endif
IOP_WORDS ?= 11264
# frames the Ethernet MAC holds until the I/O processor takes them (2 or
# 4: a block RAM each)
ETH_RX_SLOTS ?= 2

SOC = $(CURDIR)/..
R   = $(SOC)/rtl
Z   = $(SOC)/ext/zeitlos/rtl
KB  = $(SOC)/fw/kboot
IOP = $(SOC)/fw/iop
LPF = $(SOC)/ext/zeitlos/boards/$(PINS)
B   = build/$(BOARD)$(SUF)

CPU = $(R)/cpu/kakao32/kakao32.v $(R)/cpu/kakao32/kakao32_alu.v \
	$(R)/cpu/kakao32/kakao32_decode.v $(R)/cpu/kakao32/kakao32_lsu.v \
	$(R)/cpu/kakao32/kakao32_muldiv_lean.v
RTL = $(CURDIR)/kakao_top.v $(R)/kakao_soc.v $(R)/k_uart.v $(R)/k_vcon.v $(R)/k_clint.v $(R)/k_plic.v \
	$(R)/k_cache.v $(R)/k_iop.v $(R)/k_text.v $(R)/k_virtio.v \
	$(Z)/cpu/picorv32/picorv32.v $(Z)/cache_one.v $(Z)/spim.v $(CPU)
DEFS = -DSYNTHESIS -DFPGA_ECP5 -DOSC48
ifeq ($(MEM),ddr3)
  RTL  += $(Z)/mem/ddr3.v $(Z)/mem/ddr3_ctrl.v $(Z)/mem/ddr3_phy_ecp5.v $(Z)/mem/ddr3_rdasm.v \
	$(Z)/mem/ddr3_clk.v $(Z)/mem/ddr3_phy_init.v $(Z)/clk/pll2.v
  DEFS += -DK_MEM_DDR3
else
  RTL  += $(Z)/mem/sdram_kianv.v
  DEFS += -DK_MEM_SDRAM
endif
ifeq ($(VIDEO),1)
  RTL  += $(Z)/clk/pll1.v $(Z)/gpu/gpu_ddmi.v $(Z)/gpu/ddmi_island.v $(Z)/gpu/tmds_encoder.v
  DEFS += -DK_VIDEO
endif
ifneq ($(ETH),)
ifneq ($(VIRTIO),0)
ifneq ($(VIRTIO),1)
  RTL  += $(Z)/ethmac_rmii.v
  DEFS += -DK_ETH -DETH_RX_SLOTS=$(ETH_RX_SLOTS)
ifeq ($(ETH),drive)
  RTL  += $(Z)/clk/pll0.v
  DEFS += -DETH_RMII_DRIVE_REFCLK
endif
endif
endif
endif
ifeq ($(HEADLESS),1)
  DEFS += -DK_IOP_HEADLESS
endif
ifeq ($(CPU64),1)
  RTL  += $(R)/k_port64.v $(wildcard $(R)/cpu/kakao64/*.v)
  DEFS += -DK_CPU64
endif
ifeq ($(CONSOLE),usb)
  # the serial console is a USB serial port (CDC-ACM) on the USB-C socket
  RTL  += $(wildcard $(Z)/ext/usb_cdc/*.v)
  DEFS += -DK_USB_CDC
endif
ifeq ($(USBH),1)
  RTL  += $(Z)/usb/usb_host.v $(Z)/usb/usb_sie.v $(Z)/usb/usb_port.v $(Z)/usb/usb_xact.v \
	$(Z)/usb/usb_hid_compat.v
  DEFS += -DK_USB
endif

PARAMS = -chparam KCACHE $(KCACHE) -chparam I_KB $(I_KB) -chparam D_KB $(D_KB) \
	-chparam BTFN $(BTFN) -chparam FAST_MUL $(FAST_MUL) \
	-chparam TERMINAL $(TERMINAL) -chparam TERMS $(TERMS) -chparam HIST $(HIST) -chparam USB $(USB) \
	-chparam IOP_WORDS $(IOP_WORDS) -chparam VIRTIO $(VIRTIO)

all: $(B)/kakao.bit card
card: $(B)/kakao.dtb $(B)/boot.json
synth: $(B)/kakao.json
	@grep -A40 "Number of cells" $(B)/synth.log | grep "DP16KD\|LUT4\|TRELLIS_FF\|MULT18X18D\|TRELLIS_DPR16X4" | tail -5

boards:
	@echo $(BOARDS)

release:
	YOSYS="$(YOSYS)" NEXTPNR="$(NEXTPNR)" ECPPACK="$(ECPPACK)" MAKEFLAGS= \
		sh $(SOC)/tools/release.sh $(RELEASE)

# (always asked: the programs' own Makefiles know what they are made of)
$(KB)/$(ROM).0.hex: FORCE
	$(MAKE) -C $(KB) MEM=$(MEM) $(if $(filter 1,$(CPU64)),XLEN=64)
$(IOP)/iop-headless.hex: FORCE
	$(MAKE) -C $(IOP) iop-headless.hex HRAM_BYTES=$$(( $(IOP_WORDS) * 4 ))
$(IOP)/iop.hex: FORCE
	$(MAKE) -C $(IOP) BOARD="$(NAME)" CLOCK="48 MHz" MEMORY="$(MEMORY)" $(if $(filter 1,$(CPU64)),CPU="kakao64$(comma) RV64IMAFDC") RAM_BYTES=$$(( $(IOP_WORDS) * 4 )) $(if $(LAYOUTS),LAYOUTS="$(LAYOUTS)")
$(IOP)/k_font.hex: $(SOC)/tools/mkfont.py
	python3 $(SOC)/tools/mkfont.py $(SOC)/ext/zeitlos/sw/data/font/font16.mem $@
FORCE:

# (synthesis runs in kboot's directory: the block RAMs' contents are read
# from there and from ../iop)
$(B)/kakao.json: $(RTL) $(KB)/$(ROM).0.hex $(IOP)/iop$(if $(HEADLESS),-headless).hex $(IOP)/k_font.hex
	@mkdir -p $(B)
	cd $(KB) && $(YOSYS) -q -l $(CURDIR)/$(B)/synth.log \
		-p "read_verilog -defer $(DEFS) $(RTL); hierarchy -top kakao_top $(PARAMS); synth_ecp5 -abc9 -top kakao_top -json $(CURDIR)/$@"

# The placer is told to weigh timing more than it does by itself: the
# design's longest paths are mostly wire, and with this the same seeds
# place 3 to 8 MHz faster.
PNRFLAGS ?= --placer-heap-timingweight 60
PNR = $(NEXTPNR) --$(DEVICE) --package CABGA256 --lpf $(LPF) $(PNRFLAGS)
SEED ?= 2

$(B)/kakao.config: $(B)/kakao.json
	$(PNR) --json $< --textcfg $@ -l $(B)/pnr.log --seed $(SEED) -q
	@grep "Max frequency" $(B)/pnr.log | tail -4

# The kakao64 CPU alone (kakao64_bare.v): its size and its clock on this
# board's FPGA, for 48 MHz. Not a bitstream; the pins are wherever the
# tools put them. K64="-chparam FAST_MUL 1" and the like set the core's
# options.
K64RTL = $(CURDIR)/kakao64_bare.v $(wildcard $(R)/cpu/kakao64/*.v)
kakao64-bare:
	@mkdir -p build/kakao64
	$(YOSYS) -q -l build/kakao64/synth.log \
		-p "read_verilog -defer -DSYNTHESIS $(K64RTL); hierarchy -top kakao64_bare $(K64); synth_ecp5 -abc9 -top kakao64_bare -json build/kakao64/bare.json"
	@grep " LUT4$$\| TRELLIS_FF$$\| CCU2C$$\| TRELLIS_DPR16X4$$\| MULT18X18D$$\| DP16KD$$" build/kakao64/synth.log | tail -6
	$(NEXTPNR) --$(DEVICE) --package CABGA256 --lpf-allow-unconstrained --freq 48 $(PNRFLAGS) \
		--json build/kakao64/bare.json --textcfg build/kakao64/bare.config -l build/kakao64/pnr.log --seed $(SEED) -q
	@grep "Max frequency\|Total LUT4s" build/kakao64/pnr.log | tail -2

$(B)/kakao.bit: $(B)/kakao.config
	$(ECPPACK) --compress --freq 2.4 $< --bit $@

# (the SOC's clock is "clk" on a DDR3 board and the pin's own net on an
# SDRAM board)
# 48 MHz is met or missed by the seed: place with each of SEEDS and keep
# the fastest that passes (FIRST=1: the first that passes, and no more
# are tried)
SEEDS ?= 1 2 3 4
seeds: $(B)/kakao.json card
	@best=0; pick=; for s in $(SEEDS); do \
		$(PNR) --json $(B)/kakao.json --textcfg $(B)/kakao.s$$s.config -l $(B)/pnr.s$$s.log --seed $$s -q > /dev/null 2>&1; \
		f=$$(grep -E "Max frequency for clock *'.glbnet.(clk|CLK_48[^']*)'" $(B)/pnr.s$$s.log | tail -1 | sed "s/.*: \([0-9.]*\) MHz (\([A-Z]*\).*/\1 \2/"); \
		echo "seed $$s: $$f"; \
		case "$$f" in *PASS) m=$${f%% *}; m=$${m%.*}$${m#*.}; \
			if [ $$m -gt $$best ]; then best=$$m; pick=$$s; fi; \
			if [ -n "$(FIRST)" ]; then break; fi;; esac; \
	done; \
	test -n "$$pick" || { echo "no seed of $(SEEDS) meets 48 MHz"; exit 1; }; \
	echo "seed $$pick it is"; \
	cp $(B)/kakao.s$$pick.config $(B)/kakao.config; \
	$(ECPPACK) --compress --freq 2.4 $(B)/kakao.config --bit $(B)/kakao.bit

# for the SD card's /sys/linux: the device tree, and where kboot loads
# what and what it starts: the file named first (OpenSBI's fw_jump.bin,
# the kernel and the root file system are the same for every board)
$(B)/kakao.dtb: $(SOC)/tools/mkdts.py Makefile
	@mkdir -p $(B)
ifeq ($(CPU64),1)
	python3 $(SOC)/tools/mkdts.py --model "Kakao SOC, $(NAME), kakao64" --mem $(MEM_MB) --consoles $(TERMS) --virtio $(VIRTIO) \
		--isa $(ISA) --bootargs "$(BOOTARGS)" > $(B)/kakao.dts
else
	python3 $(SOC)/tools/mkdts.py --model "Kakao SOC, $(NAME)" --mem $(MEM_MB) --consoles $(TERMS) --virtio $(VIRTIO) \
		--initrd $(INITRD) $$(printf '0x%x' $$(( $(INITRD) + 0x800000 ))) > $(B)/kakao.dts
endif
	dtc -q -I dts -O dtb -o $@ $(B)/kakao.dts

$(B)/boot.json: Makefile
	@mkdir -p $(B)
ifeq ($(CPU64),1)
	printf '{\n\t"fw_jump.bin": "$(SBI_AT)",\n\t"Image": "$(KERN_AT)",\n\t"kakao.dtb": "$(DTB_AT)"\n}\n' > $@
else
	printf '{\n\t"fw_jump.bin": "$(SBI_AT)",\n\t"Image": "0x80000000",\n\t"rootfs.cpio": "$(INITRD)",\n\t"kakao.dtb": "$(DTB_AT)"\n}\n' > $@
endif

clean:
	rm -rf build

.PHONY: kakao64-bare all card synth boards seeds release clean FORCE
.PRECIOUS: $(B)/kakao.json $(B)/kakao.config
