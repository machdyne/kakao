# firstlight: the test program in the first-light bitstream's block RAM.
# Leaves firstlight.{0,1,2,3}.hex, one per byte lane, 16384 lines each.

CROSS  ?= riscv64-unknown-elf-
CFLAGS  = -march=rv32ima_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib \
	-fno-builtin -Wall -Wno-main

all: firstlight.0.hex

firstlight.elf: crt0.S main.c link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld crt0.S main.c -o $@

firstlight.bin: firstlight.elf
	$(CROSS)objcopy -O binary $< $@

firstlight.0.hex: firstlight.bin
	python3 -c "import sys; d=open('$<','rb').read(); d+=bytes(65536-len(d)); [open('firstlight.%d.hex'%k,'w').write(''.join('%02x\n'%b for b in d[k::4])) for k in range(4)]"

clean:
	rm -f firstlight.elf firstlight.bin firstlight.*.hex

.PHONY: all clean
