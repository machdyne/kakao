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
# (what a card that cannot be booted from has on it: sdboot.c)
CFLAGS += -DSD_SAYS
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

# The FAT code on the host, on cards made here: FAT16; FAT32 with one
# and with eight sectors a cluster behind a partition table; a long
# name; and cards that cannot be booted from, for what kboot then says.
# Needs dosfstools (4.2: --offset), mtools and e2fsprogs.
T = build/hosttest
hosttest: hosttest.c sdboot.c
	@mkdir -p $(T)
	cc -O1 -Wall -Wno-unused-function -Wno-int-to-pointer-cast -o $(T)/hosttest hosttest.c
	@printf '{ "x": "0x80000000" }\n' > $(T)/boot.json
	@rm -f $(T)/*.img
	@mkfs.vfat -F 16 -C $(T)/fat16.img 16384 > /dev/null
	@for s in 1 8; do truncate -s 80M $(T)/fat32-$$s.img && \
		mkfs.vfat -F 32 -s $$s -S 512 --offset 2048 $(T)/fat32-$$s.img $$((64 * 1024)) > /dev/null && \
		python3 -c "import struct,sys; f=open(sys.argv[1],'r+b'); f.seek(446); f.write(struct.pack('<BBBBBBBBII',0,0,0,0,0x0c,0,0,0,2048,131072)); f.seek(510); f.write(b'\x55\xaa')" $(T)/fat32-$$s.img || exit 1; done
	@cp $(T)/fat32-1.img $(T)/nolinux.img; cp $(T)/fat32-1.img $(T)/nojson.img
	@for i in $(T)/fat16.img $(T)/fat32-1.img@@1M $(T)/fat32-8.img@@1M; do \
		MTOOLS_SKIP_CHECK=1 mmd -i $$i ::/sys ::/sys/linux && \
		MTOOLS_SKIP_CHECK=1 mcopy -i $$i $(T)/boot.json ::/sys/linux/ && \
		MTOOLS_SKIP_CHECK=1 mcopy -i $$i $(T)/boot.json "::/sys/linux/a-long-name.with dots.bin" || exit 1; done
	@MTOOLS_SKIP_CHECK=1 mmd -i $(T)/nolinux.img@@1M ::/sys ::/other
	@MTOOLS_SKIP_CHECK=1 mmd -i $(T)/nojson.img@@1M ::/sys ::/sys/linux
	@MTOOLS_SKIP_CHECK=1 mcopy -i $(T)/nojson.img@@1M $(T)/boot.json ::/sys/linux/boot.jsn
	@truncate -s 16M $(T)/ext.img && mke2fs -q -F $(T)/ext.img
	@for i in fat16 fat32-1 fat32-8; do \
		$(T)/hosttest $(T)/$$i.img > $(T)/$$i.txt && grep -q "^found: boot.json, 22 bytes" $(T)/$$i.txt && \
		$(T)/hosttest $(T)/$$i.img "a-long-name.with dots.bin" | grep -q "^found" || { echo "hosttest: $$i FAILED"; cat $(T)/$$i.txt; exit 1; }; \
		echo "$$i: ok"; done
	@cp $(T)/fat32-1.img $(T)/both.img && printf '{ "y": "0x80200000" }\n' > $(T)/boot64.json && \
		MTOOLS_SKIP_CHECK=1 mcopy -i $(T)/both.img@@1M $(T)/boot64.json ::/sys/linux/ && \
		$(T)/hosttest $(T)/both.img boot64.json | grep -q "^found: boot64.json, 22 bytes" && echo "boot64.json: ok"
	@for i in nolinux nojson ext; do echo "-- $$i:"; ! $(T)/hosttest $(T)/$$i.img || { echo "hosttest: $$i was booted from"; exit 1; }; done
	@$(T)/hosttest $(T)/nolinux.img | grep -q "no /sys/linux. In /sys:" && \
		$(T)/hosttest $(T)/nojson.img | grep -q "in /sys/linux:.* BOOT.JSN" && \
		$(T)/hosttest $(T)/ext.img | grep -q "sector 0 ends" && echo "hosttest: PASS"

clean:
	rm -rf kboot*.elf kboot*.bin kboot*.hex ddr3_train.inc build

.PHONY: all clean hosttest
