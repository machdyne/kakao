# memtest: main memory through the cache, for kakao_soc's boot memory.
# Leaves memtest.{0,1,2,3}.hex, one per byte lane, 4096 lines each.

CROSS  ?= riscv64-unknown-elf-
CFLAGS  = -march=rv32im_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -nostdlib \
	-fno-builtin -Wall -Wno-main

all: memtest.0.hex

memtest.elf: crt0.S main.c link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld crt0.S main.c -o $@ -lgcc

memtest.bin: memtest.elf
	$(CROSS)objcopy -O binary $< $@

memtest.0.hex: memtest.bin
	python3 -c "d=open('$<','rb').read(); assert len(d) <= 12288, 'too big'; d+=bytes(16384-len(d)); [open('memtest.%d.hex'%k,'w').write(''.join('%02x\n'%b for b in d[k::4])) for k in range(4)]"

clean:
	rm -f memtest.elf memtest.bin memtest.*.hex

.PHONY: all clean
