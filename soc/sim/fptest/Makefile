# The floating-point tests of riscv-tests (rv64uf, rv64ud) as one image
# for the SBI firmware to start: obj/fptest.bin, to load at 0x8020_0000.
# riscv_test.h says how it runs.
#
#   make              the image
#   make qemu         run it on QEMU's virt (OPENSBI=<fw_jump.bin>)

CROSS ?= riscv64-unknown-elf-
RT     = ../../ext/riscv-tests
TESTS ?= $(foreach t,fadd fdiv fcvt fcvt_w fmadd fmin fcmp fclass ldst move recoding,rv64uf/$(t) rv64ud/$(t)) rv64ud/structural
CFLAGS = -march=rv64imafdc_zicsr_zifencei -mabi=lp64 -static -mcmodel=medany -nostdlib -nostartfiles \
	-I. -I$(RT)/env -I$(RT)/isa/macros/scalar -Wl,-T,link.ld

all: obj/fptest.bin

obj/fptest.bin: riscv_test.h done.S link.ld Makefile
	@mkdir -p obj; rm -f obj/t*.bin; i=0; : > obj/list.txt; \
	for t in $(TESTS) done; do \
		if [ $$t = done ]; then src=done.S; else src=$(RT)/isa/$$t.S; fi; \
		n=`printf %02d $$i`; \
		$(CROSS)gcc $(CFLAGS) -DTEST_INDEX=$$i -Wl,--defsym,BASE=`printf '0x%x' $$((0x80200000 + i * 0x10000))` \
			$$src -o obj/t$$n.elf || exit 1; \
		$(CROSS)objcopy -O binary obj/t$$n.elf obj/t$$n.raw; \
		python3 -c "import sys; d=open('obj/t$$n.raw','rb').read(); assert len(d) <= 65536; sys.stdout.buffer.write(d + bytes(65536 - len(d)))" >> obj/fptest.tmp.$$$$; \
		echo "$$i `python3 -c "print(chr(65+$$i//26)+chr(97+$$i%26))"` $$t" >> obj/list.txt; \
		i=$$((i+1)); \
	done; mv obj/fptest.tmp.$$$$ $@
	@echo "$@: `wc -l < obj/list.txt` programs (obj/list.txt names them)"

qemu: obj/fptest.bin
	@test -n "$(OPENSBI)" || { echo "make qemu OPENSBI=<fw_jump.bin>"; exit 1; }
	timeout 60 qemu-system-riscv64 -M virt -m 256 -nographic -bios $(OPENSBI) \
		-device loader,file=obj/fptest.bin,addr=0x80200000 | tail -3

clean:
	rm -rf obj

.PHONY: all qemu clean
