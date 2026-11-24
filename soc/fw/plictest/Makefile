# plictest: the PLIC and UART 0's interrupts, for kakao_soc's boot memory.
# Leaves plictest.{0,1,2,3}.hex, one per byte lane, 4096 lines each.

CROSS  ?= riscv64-unknown-elf-
CFLAGS  = -march=rv32im_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib \
	-fno-builtin -Wall -Wno-main

all: plictest.0.hex

plictest.elf: crt0.S main.c link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld crt0.S main.c -o $@ -lgcc

plictest.bin: plictest.elf
	$(CROSS)objcopy -O binary $< $@

plictest.0.hex: plictest.bin
	python3 -c "d=open('$<','rb').read(); assert len(d) <= 12288, 'too big'; d+=bytes(16384-len(d)); [open('plictest.%d.hex'%k,'w').write(''.join('%02x\n'%b for b in d[k::4])) for k in range(4)]"

clean:
	rm -f plictest.elf plictest.bin plictest.*.hex

.PHONY: all clean
