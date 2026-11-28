# Kakao Plan 9: Plan 9 from Bell Labs (the 9k RISC-V port) for the Kakao
# SOC with kakao64, and for QEMU's virt machine, which the SOC copies.
#
#   make            everything, as far as build/9kkcpu.bin (the kernel)
#   make qemu       boot it in qemu-system-riscv64 (leave with Ctrl-A x)
#   make test       boot it in QEMU, type a few commands, check the answers
#   make kernel     the kernel again, after a change under overlay/
#   make clean      remove what was built here, keep what was fetched
#   make distclean  remove build/ altogether
#
# Everything is fetched into and built under build/.  README.md says what
# the host needs and what each step does.

include upstream/versions.mk

B      = build
SRC    = $(B)/src
P9P    = $(SRC)/p9p
P9SRC  = $(SRC)/plan9
P9P32  = $(B)/p9p32
HOST   = $(B)/host
ROOT   = $(B)/root
RUN    = tools/p9run $(ROOT)
KERNEL = $(B)/9kkcpu.bin

QEMU   = qemu-system-riscv64
QFLAGS = -M virt -m 512 -smp 1 -nographic -bios default
# a network device the driver accepts: QEMU's virtio-mmio is the legacy
# transport unless told otherwise, and the SOC's is not
QNET   = -global virtio-mmio.force-legacy=false \
	 -netdev user,id=n0 -device virtio-net-device,netdev=n0
# the SOC's device tree generator, when this directory is in the kakao repo
MKDTS  = ../soc/tools/mkdts.py

# libc first; the rest in an order in which each finds what it needs
LIBS = libbio libmp libsec libip libauthsrv libauth libndb lib9p libthread \
	libString libregexp libflate libdisk libbin libavl libstdio \
	libmemdraw libmemlayer libdraw libframe libcomplete libplumb

# the commands of the root file system the kernel carries
CMDS = echo ls cat ps bind mount unmount srv date sleep rm cp mkdir mv wc xd \
	test ed sed dd cmp tail read ramfs chmod touch \
	tar tee srvfs mntgen cpu import netstat stats clock colors pwd
AUTHCMDS = keyfs authsrv changeuser newns none wrkey
NDBCMDS = cs csquery query
AUXCMDS = listen listen1
# directories of the root file system that have nothing in them
ROOTDIRS = adm cfg mnt/keys mnt/term mnt/temp mnt/wsys mnt/plumb n tmp \
	usr/glenda/tmp usr/glenda/bin/rc sys/lib
ROOTLOGS = auth cpu cs listen timesync
# rio's font and the pieces of it that are not in its own directory
FONTS = lucm misc pelm

all: $(KERNEL)

# --- what it is built from ---------------------------------------------

fetch: $(P9P)/.fetched $(P9SRC)/.fetched $(B)/dist/.unpacked

$(P9P)/.fetched: upstream/versions.mk
	rm -rf $(P9P) && mkdir -p $(P9P)
	cd $(P9P) && git init -q && git remote add origin $(P9P_URL) && \
		git fetch -q --depth 1 origin $(P9P_COMMIT) && git checkout -q FETCH_HEAD
	touch $@

$(P9SRC)/.fetched: upstream/versions.mk
	rm -rf $(P9SRC) && mkdir -p $(P9SRC)
	cd $(P9SRC) && git init -q && git remote add origin $(P9_URL) && \
		git fetch -q --depth 1 origin $(P9_COMMIT) && git checkout -q FETCH_HEAD
	touch $@

$(B)/dist/.unpacked: $(DIST) upstream/SHA256SUMS
	cd upstream && sha256sum -c SHA256SUMS
	rm -rf $(B)/dist && mkdir -p $(B)/dist
	tar xzf $(DIST) -C $(B)/dist
	touch $@

# --- the host's tools ---------------------------------------------------

# plan9port, without its window system: rc, mk, awk, sed, yacc and the rest.
# Some of its programs do not link without X; those are not needed.
$(P9P)/.built: $(P9P)/.fetched
	cd $(P9P) && echo 'WSYSTYPE=nowsys' > LOCAL.config && \
		(./INSTALL > ../p9p.log 2>&1 || true)
	test -x $(P9P)/bin/rc -a -x $(P9P)/bin/mk -a -x $(P9P)/bin/yacc
	touch $@

# plan9port's lib9 and libbio once more, as 32 bit libraries: the
# compilers have to be 32 bit programs (tools/mkhost.sh says why)
$(P9P32)/.built: $(P9P)/.built
	rm -rf $(P9P32) && mkdir -p $(P9P32)/lib
	cd $(P9P) && tar cf - --exclude='*.o' --exclude='*.a' --exclude='o.*' \
		bin/9c bin/9l bin/9ar include src/lib9 src/libbio \
		src/mkhdr src/mksyslib src/mkmk.sh src/mklib src/mkcommon \
		src/mkdirs src/mkone src/mkmany config | (cd $(CURDIR)/$(P9P32) && tar xf -)
	for l in lib9 libbio; do \
		(cd $(P9P32)/src/$$l && PLAN9=$(CURDIR)/$(P9P32) \
		 PATH=$(CURDIR)/$(P9P32)/bin:$(CURDIR)/$(P9P)/bin:$$PATH \
		 OBJTYPE=386 CC9='gcc -m32 -std=gnu17' mk install) > $(B)/p9p32.$$l.log 2>&1 || \
		{ tail -5 $(B)/p9p32.$$l.log; exit 1; }; \
	done
	touch $@

$(HOST)/.built: $(P9P32)/.built $(P9SRC)/.fetched $(B)/dist/.unpacked \
		tools/mkhost.sh tools/p9aout.c
	tools/mkhost.sh $(CURDIR)/$(B)/dist $(CURDIR)/$(P9SRC) $(CURDIR)/$(P9P) \
		$(CURDIR)/$(P9P32) $(CURDIR)/$(HOST) > $(B)/host.log 2>&1 || \
		{ grep -v warning $(B)/host.log | tail -20; exit 1; }
	touch $@

tools: $(HOST)/.built

# --- the Plan 9 root ----------------------------------------------------

# the kernel's own files under overlay/ are copied in again by `kernel`,
# so a change to one of them does not start the root again
$(ROOT)/.built: $(HOST)/.built tools/mkroot.sh patches/kakao.patch \
		$(shell find overlay -type f -not -path 'overlay/sys/src/9k/*')
	tools/mkroot.sh $(CURDIR)/$(P9SRC) $(CURDIR)/$(B)/dist $(CURDIR)/$(P9P) \
		$(CURDIR)/$(HOST)/bin $(CURDIR) $(CURDIR)/$(ROOT)
	touch $@

root: $(ROOT)/.built

$(ROOT)/.libs: $(ROOT)/.built
	$(RUN) 'cd /sys/src/libc && mk install' > $(B)/libc.log 2>&1 || \
		{ tail -20 $(B)/libc.log; exit 1; }
	$(RUN) 'cd /sys/src; for(l in $(LIBS)) @{ cd $$l && mk install } || exit $$l' \
		> $(B)/libs.log 2>&1 || { tail -20 $(B)/libs.log; exit 1; }
	touch $@

libs: $(ROOT)/.libs

# rc, the commands of CMDS, and the three that are directories of their own
$(ROOT)/.cmds: $(ROOT)/.libs
	$(RUN) 'cd /sys/src/cmd/rc && mk install' > $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd; for(c in $(CMDS)) { mk $$c.install || exit $$c }' \
		>> $(B)/cmds.log 2>&1 || { tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/grep && mk install' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/ip && mk ping.install' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/ip/ipconfig && mk install' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/auth/factotum && mk j.factotum && \
		cp j.factotum /riscv64/bin/auth/factotum' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/auth/lib && mk install' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/auth; for(c in $(AUTHCMDS)) { mk $$c.install || exit $$c }' \
		>> $(B)/cmds.log 2>&1 || { tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/auth && jc -FTVw passtokey.c && jl -o j.passtokey passtokey.j && \
		cp j.passtokey /riscv64/bin/auth/passtokey' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/ndb; for(c in $(NDBCMDS)) { mk $$c.install || exit $$c }' \
		>> $(B)/cmds.log 2>&1 || { tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/aux; for(c in $(AUXCMDS)) { mk $$c.install || exit $$c }' \
		>> $(B)/cmds.log 2>&1 || { tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/exportfs && mk install' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	$(RUN) 'cd /sys/src/cmd/rio && mk install' >> $(B)/cmds.log 2>&1 || \
		{ tail -20 $(B)/cmds.log; exit 1; }
	touch $@

cmds: $(ROOT)/.cmds

# --- the kernel ---------------------------------------------------------

# The overlay is copied over the root again each time, so that an edit
# under overlay/ is what gets built; mk then rebuilds what depends on it.
kernel $(KERNEL): $(ROOT)/.cmds FORCE
	cd overlay && tar cf - . | (cd $(CURDIR)/$(ROOT) && tar xf -)
	# the root file system the kernel carries (kk/kkinit unpacks it):
	# rootfs/, the commands built above, and three files of the system's
	rm -rf $(B)/kkroot && mkdir -p $(B)/kkroot
	cd rootfs && tar cf - . | (cd $(CURDIR)/$(B)/kkroot && tar xf -)
	cd $(B)/kkroot && mkdir -p $(ROOTDIRS) sys/log riscv64/bin rc/lib lib/ndb && \
		for l in $(ROOTLOGS); do : > sys/log/$$l; done
	# the commands stay in the kernel's /boot: their names into the
	# configuration, and for those in a directory an empty file in the
	# root and a line that binds the command over it
	cd $(ROOT)/riscv64/bin && find . -type f | sed 's|^\./||' | sort > $(CURDIR)/$(B)/kkbin.list
	sed 's|^|	/riscv64/bin/|' $(B)/kkbin.list > $(B)/kkbin.conf
	sed -i -e '/^#KKBIN/r $(B)/kkbin.conf' -e '/^#KKBIN/d' $(ROOT)/sys/src/9k/rv/kkcpu
	: > $(B)/kkroot/lib/namespace.kkbin
	grep / $(B)/kkbin.list | while read f; do \
		mkdir -p $(B)/kkroot/riscv64/bin/$$(dirname $$f) && \
		: > $(B)/kkroot/riscv64/bin/$$f && \
		echo "bind /boot/$$(basename $$f) /riscv64/bin/$$f" >> $(B)/kkroot/lib/namespace.kkbin; \
	done
	cp $(ROOT)/rc/lib/rcmain $(B)/kkroot/rc/lib/rcmain
	cp $(P9SRC)/lib/ndb/common $(B)/kkroot/lib/ndb/common
	mkdir -p $(B)/kkroot/lib/font/bit && for f in $(FONTS); do \
		cp -r $(P9SRC)/lib/font/bit/$$f $(B)/kkroot/lib/font/bit/$$f; done
	cp $(P9SRC)/rc/bin/kill $(P9SRC)/rc/bin/slay $(P9SRC)/rc/bin/window \
		$(B)/kkroot/rc/bin/
	chmod -R a+rX $(B)/kkroot && chmod 755 $(B)/kkroot/rc/bin/*  \
		$(B)/kkroot/rc/bin/service/* $(B)/kkroot/rc/bin/service.auth/*
	chmod 777 $(B)/kkroot/tmp $(B)/kkroot/usr/glenda/tmp
	chmod 666 $(B)/kkroot/sys/log/*
	cd $(B)/kkroot && tar --format=ustar --owner=glenda --group=glenda \
		-cf $(CURDIR)/$(ROOT)/sys/src/9k/rv/kk/kkroot.tar *
	rm -f $(ROOT)/sys/src/9k/rv/kkcpu.root.*
	$(RUN) 'cd /sys/src/9k/rv && ARCH=kk mk 9kkcpu.bin' > $(B)/kernel.log 2>&1 || \
		{ grep -v "^jc \|^ja \|^ar \|^a - " $(B)/kernel.log | tail -20; exit 1; }
	cp $(ROOT)/sys/src/9k/rv/9kkcpu.bin $(KERNEL)
	@grep '^[0-9]*t + ' $(B)/kernel.log | tail -1
	@ls -l $(KERNEL)

# --- running it ---------------------------------------------------------

qemu: $(KERNEL)
	$(QEMU) $(QFLAGS) $(QNET) -kernel $(KERNEL)

# the same with a screen, a keyboard and a mouse, in a window of this
# machine's: kkrio at the console starts the window system
QGFX   = -M virt -m 512 -smp 1 -serial mon:stdio -bios default -device ramfb \
	 -device virtio-keyboard-device -device virtio-tablet-device
qemu-rio: $(KERNEL)
	$(QEMU) $(QGFX) $(QNET) -kernel $(KERNEL)

# the shell; the network and a 9P mount; two machines, one the CPU server
# of the other; then QEMU as near the SOC as it gets: 128 MB and the SOC's own device tree (48 MHz timebase)
test: $(KERNEL)
	sh tools/qemutest.sh "$(QEMU) $(QFLAGS) -kernel $(KERNEL)" $(B)/test.log
	sh tools/nettest.sh "$(QEMU) $(QFLAGS) $(QNET) -kernel $(KERNEL)" \
		$(CURDIR)/$(P9P) $(B)/nettest.log
	sh tools/cputest.sh "$(QEMU) $(QFLAGS) -kernel $(KERNEL)" $(B)/cputest.log
	sh tools/riotest.sh "$(QEMU) $(QFLAGS) -kernel $(KERNEL)" $(B)/riotest.log
	@if [ -f $(MKDTS) ] && command -v dtc >/dev/null; then \
		$(MAKE) --no-print-directory dttest fbtest; \
	else echo "skip  dttest, fbtest: need $(MKDTS) and dtc"; fi

dttest: $(KERNEL)
	python3 $(MKDTS) --model "Kakao SOC, test, kakao64" --mem 128 --consoles 1 \
		--virtio 2 --isa rv64imafdc > $(B)/kakao64.dts
	dtc -q -O dtb -o $(B)/kakao64.dtb $(B)/kakao64.dts
	sh tools/qemutest.sh "$(QEMU) $(QFLAGS) -m 128 -dtb $(B)/kakao64.dtb \
		-kernel $(KERNEL)" $(B)/dttest.log 'clint timebase: 48 MHz' \
		'^1[12][0-9]M memory'

# The SOC's framebuffer, the kernel's side of it: the SOC's device tree
# with the framebuffer (--fb), its registers moved into memory QEMU has
# (tools/fbtest.sh).  The picture is left in $(B)/fbtest.log.ppm.
fbtest: $(KERNEL)
	python3 $(MKDTS) --model "Kakao SOC, test, kakao64" --mem 256 --consoles 1 \
		--virtio 2 --isa rv64imafdc --fb | \
		sed 's/kakao,ctrl = <0x03001000>/kakao,ctrl = <0x8ff00000>/' > $(B)/kakaofb.dts
	dtc -q -O dtb -o $(B)/kakaofb.dtb $(B)/kakaofb.dts
	sh tools/fbtest.sh "$(QEMU) $(QFLAGS) -m 256 -kernel $(KERNEL)" \
		$(B)/kakaofb.dtb $(B)/fbtest.log

# drawterm (github.com/9front/drawterm, CONF=unix make) on this machine
# logs in to the kernel in QEMU.  As root: it forwards port 567.
DRAWTERM = drawterm
drawtermtest: $(KERNEL)
	sh tools/drawtermtest.sh "$(QEMU) $(QFLAGS) -kernel $(KERNEL)" \
		$(DRAWTERM) $(B)/drawtermtest.log

# The SOC itself, simulated: docs/port.md, "On the simulated SOC", says
# how obj/simsoc64 and fw_jump.bin are made.  The better part of an hour.
SIM     = ../soc/sim/obj/simsoc64
OPENSBI = fw_jump.bin
simtest: $(KERNEL)
	python3 $(MKDTS) --model "Kakao SOC, sim, kakao64" --mem 256 \
		--consoles 1 --virtio 2 --isa rv64imafdc > $(B)/sim64.dts
	dtc -q -O dtb -o $(B)/sim64.dtb $(B)/sim64.dts
	sh tools/simtest.sh $(abspath $(SIM)) $(abspath $(OPENSBI)) \
		$(CURDIR)/$(KERNEL) $(CURDIR)/$(B)/sim64.dtb $(B)/simtest.log

clean:
	rm -rf $(ROOT) $(HOST) $(P9P32) $(KERNEL) $(B)/*.log

distclean:
	rm -rf $(B)

FORCE:
.PHONY: all fetch tools root libs cmds kernel qemu qemu-rio test dttest fbtest drawtermtest simtest clean distclean FORCE
