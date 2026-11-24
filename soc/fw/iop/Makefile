# The I/O processor's program. Leaves iop.hex, a word a line, for
# rtl/k_iop.v's memory (RAM_WORDS words: RAM_BYTES here must agree).
#
#   make          iop.hex
#   make iop-headless.hex   the program for a machine without a terminal:
#                 the virtio devices alone (headless.c), HRAM_BYTES of it
#   make test     the mouse's selecting and pasting, and the terminal
#                 built for this machine and compared with
#                 pyte, a terminal emulator in Python (pip install pyte),
#                 on the texts in tests/
#
#   LAYOUTS=      the keyboard layouts built in, by Zeitlos's names
#                 (ext/zeitlos/sw/common/zkbd_layouts.c): the first is
#                 the one after power-on
#   BOARD=, CLOCK=, MEMORY=, CPU=   what "About this machine" says
#   EXTRA=        more for the compiler (-DVDEBUG: the disk's requests
#                 are written to the simulation's log)
#
# The USB host stack and the layouts are Zeitlos's sources as they are
# (ext/zeitlos/sw/apps/usb, sw/common), built with what they need from
# here: shim/ for the C library's headers, usbglue.c for the rest.

CROSS  ?= riscv64-unknown-elf-
RAM_BYTES ?= 45056
HRAM_BYTES ?= 8192
LAYOUTS ?= us gb de de-nodeadkeys
BOARD  ?= Kakao
CLOCK  ?= 48 MHz
MEMORY ?= 512 MB
CPU    ?= kakao32, RV32IMA

Z      = ../../ext/zeitlos/sw
ZUSB   = $(Z)/apps/usb
# (small before fast; one program, optimised as a whole: what is not
# used of Zeitlos's sources, their messages too, is left out)
CFLAGS = -march=rv32ic -mabi=ilp32 -Os -msave-restore -fno-jump-tables \
	-ffreestanding -nostdlib -fno-builtin -flto -ffunction-sections -fdata-sections \
	-Wall -Wno-main -Ishim -I$(ZUSB) -I$(Z)/common \
	-DZ_SMALL -DZ_USBH_OWN_PRINTF \
	'-DK_BOARD="$(BOARD)"' '-DK_CLOCK="$(CLOCK)"' '-DK_MEMORY="$(MEMORY)"' '-DK_CPU="$(CPU)"' $(EXTRA)
OWN    = main.c term.c kbd.c hud.c mouse.c usbglue.c virtio.c vblk.c sd.c vnet.c nic_rmii.c
THEIRS = $(ZUSB)/usbh.c $(ZUSB)/usbh_hid.c $(ZUSB)/usbh_hub.c

all: iop.hex

HOWN = headless.c virtio.c vblk.c sd.c vnet.c nic_rmii.c
iop-headless.elf: crt0.S $(HOWN) virtio.h sd.h nic.h link.ld Makefile
	$(CROSS)gcc $(CFLAGS) -Wl,--gc-sections -Wl,--defsym=RAM_BYTES=$(HRAM_BYTES) -T link.ld \
		crt0.S $(HOWN) -o $@ -lgcc
	$(CROSS)size $@
iop-headless.hex: iop-headless.elf
	$(CROSS)objcopy -O binary $< iop-headless.bin
	python3 -c "import struct; d=open('iop-headless.bin','rb').read(); d+=bytes($(HRAM_BYTES)-len(d)); open('$@','w').write(''.join('%08x\n'%w for w in struct.unpack('<%dI'%(len(d)//4), d)))"

# what was asked for, kept: asked for something else, everything is made
# again (the boards ask for their own names)
CONFIG = $(RAM_BYTES) $(LAYOUTS) $(BOARD) $(CLOCK) $(MEMORY) $(CPU) $(EXTRA)
config.stamp: FORCE
	@echo '$(CONFIG)' | cmp -s - $@ || echo '$(CONFIG)' > $@
FORCE:

k_zkbd.c: ../../tools/mkkbd.py $(Z)/common/zkbd.c $(Z)/common/zkbd_layouts.c Makefile config.stamp
	python3 ../../tools/mkkbd.py $(Z)/common $@ $(LAYOUTS)

iop.elf: crt0.S $(OWN) term.h iop.h virtio.h sd.h nic.h link.ld k_zkbd.c $(THEIRS) Makefile config.stamp
	$(CROSS)gcc $(CFLAGS) -Wl,--gc-sections -Wl,--defsym=RAM_BYTES=$(RAM_BYTES) -T link.ld \
		crt0.S $(OWN) -w k_zkbd.c $(THEIRS) -o $@ -lgcc
	@$(CROSS)size $@

iop.bin: iop.elf
	$(CROSS)objcopy -O binary $< $@

iop.hex: iop.bin
	python3 -c "import struct; d=open('$<','rb').read(); d+=bytes($(RAM_BYTES)-len(d)); open('$@','w').write(''.join('%08x\n'%w for w in struct.unpack('<%dI'%(len(d)//4), d)))"

term_test: term_test.c term.c term.h
	cc -O1 -Wall -DTERM_HOST -o $@ term_test.c term.c

scroll_test: scroll_test.c term.c term.h
	cc -O1 -Wall -DTERM_HOST -o $@ scroll_test.c term.c

# the menus for the host: tests/hud.py draws what they put on the screen
#   python3 tests/hud.py ./hud_test k_font.hex menu.png s r e d
hud_test: hud_test.c hud.c iop.h k_zkbd.c
	cc -O1 -Wall -DTERM_HOST -I$(ZUSB) -I$(Z)/common -o $@ hud_test.c hud.c -w k_zkbd.c

# selecting with the mouse, copying and pasting, on the terminal
mouse_test: mouse_test.c mouse.c term.c term.h iop.h
	cc -O1 -Wall -DTERM_HOST -o $@ mouse_test.c mouse.c term.c

test: term_test mouse_test scroll_test
	./mouse_test
	./scroll_test
	python3 tests/compare.py ./term_test tests/*.txt
	python3 tests/compare.py ./term_test --fuzz 1000 1

clean:
	rm -f iop.elf iop.bin iop.hex iop-headless.elf iop-headless.bin iop-headless.hex term_test hud_test mouse_test scroll_test k_zkbd.c config.stamp

.PHONY: all test clean FORCE
