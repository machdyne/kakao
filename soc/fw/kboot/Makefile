# kboot: the boot ROM (see main.c). Leaves kboot.0.hex .. kboot.3.hex, a
# byte lane each, for a board with DDR3 (the DDR3 trainer is Zeitlos's,
# cut from its BIOS and moved to this SOC's addresses), and with
# MEM=sdram kboot-sdram.0.hex .. for a board with 32 MB of SDRAM, which
# needs no training.
#
#   make              kboot.N.hex: 16 KB of boot memory (ROM_WORDS 4096)
#   make MEM=sdram    kboot-sdram.N.hex: 8 KB (ROM_WORDS 2048)

CROSS  ?= riscv64-unknown-elf-
# XLEN=64: for kakao64 (kboot64.N.hex, kboot64-sdram.N.hex). Addresses
# stay 32 bits wide in the program: all of the machine is below 4 GB.
XLEN   ?= 32
ifeq ($(XLEN),64)
ARCH    = -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany \
	-Wno-int-to-pointer-cast -Wno-pointer-to-int-cast -DDTB_ADDR=0x87f00000u
K       = kboot64
else
ARCH    = -march=rv32ima_zicsr -mabi=ilp32
K       = kboot
endif
CFLAGS  = $(ARCH) -Os -ffreestanding -nostdlib \
	-fno-builtin -Wall -Wno-main -Wno-unused-function
BIOS    = ../../ext/zeitlos/sw/bios/bios.c
MEM    ?= ddr3

ifeq ($(MEM),sdram)
NAME    = $(K)-sdram
SIZE    = 8192
CFLAGS += -DKBOOT_SDRAM
INC     =
else
NAME    = $(K)
SIZE    = 16384
INC     = ddr3_train.inc
endif

all: $(NAME).0.hex

# from "#ifdef BIOS_DDR3" to the end of ddr3_train()
ddr3_train.inc: $(BIOS) Makefile
	awk '/^#ifdef BIOS_DDR3/ { on = 1; next } /^\/\/ Compare the loaded kernel/ { on = 0 } on' $(BIOS) | \
	sed -e 's/0x70000700/0x03000700/; s/0x70000704/0x03000704/; s/0x70000708/0x03000708/; s/0x70000110/0x03000110/' > $@
	@grep -q "static int ddr3_train" $@ || { echo "ddr3_train.inc: the trainer was not found in $(BIOS)"; rm -f $@; exit 1; }
	@! grep -q "0x7000" $@ || { echo "ddr3_train.inc: an address was not moved"; rm -f $@; exit 1; }

$(NAME).elf: crt0.S main.c sdboot.c link.ld $(INC) Makefile
	$(CROSS)gcc $(CFLAGS) -Wl,--defsym=ROM_SIZE=$(SIZE) -T link.ld crt0.S main.c -o $@

$(NAME).0.hex: $(NAME).elf
	$(CROSS)objcopy -O binary $< $(NAME).bin
	python3 -c "d=open('$(NAME).bin','rb').read(); n=$(SIZE); assert len(d) <= n - 2048, '$(NAME): %d bytes, too big' % len(d); d+=bytes(n-len(d)); [open('$(NAME).%d.hex'%k,'w').write(''.join('%02x\n'%b for b in d[k::4])) for k in range(4)]"

clean:
	rm -f kboot*.elf kboot*.bin kboot*.hex ddr3_train.inc

.PHONY: all clean
