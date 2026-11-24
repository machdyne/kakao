/*
 * Booting from the SD card: part of kboot (main.c includes it).
 *
 * The card is on Zeitlos's SPI master (rtl/spim.v, "SPI1": a DATA
 * access waits for the transfer, and a transfer can be 32 bits) at
 * 0x0300_0800. It holds a FAT16 or FAT32 file system, with or without
 * a partition table (then the first partition), long names read.
 *
 * What to load is in /sys/linux/boot.json, in the form LiteX's
 * boot.json has, a file and where it goes:
 *
 *   {
 *     "fw_jump.bin":   "0x81e00000",
 *     "Image":         "0x80000000",
 *     "rootfs.cpio":   "0x81000000",
 *     "kakao.dtb":     "0x81f00000"
 *   }
 *
 * A name is a file in /sys/linux, or with a slash in front a path
 * from the card's root: so a card that also boots the LiteX SOC keeps
 * one Image and one rootfs.cpio in its root, beside LiteX's own
 * /boot.json, and the rest of ours stays out of the way. Then the
 * file named first is started (OpenSBI: put it first), with the
 * address of the file whose name ends in .dtb. A value that is not a
 * string (LiteX's "bootargs") is skipped.
 *
 * (The kernel is at the bottom of memory and OpenSBI near the top of
 * the first 32 MB, so that a board with 32 MB loses none of it: on
 * RV32 Linux cannot use what lies below its own image.)
 */

#define SPI_DATA  (*(volatile uint32_t *)0x03000800)
#define SPI_STAT  (*(volatile uint32_t *)0x03000804)
#define SPI_CTRL  (*(volatile uint32_t *)0x03000808)
#define SPI_MAGIC (*(volatile uint32_t *)0x0300080c)
#define SPI_CS    1u
#define SPI_W32   2u
#define SPI_DIV(d) ((uint32_t)(d) << 8)
#define DIV_INIT  59			/* 400 kHz at 48 MHz */
#define DIV_FAST  1				/* 12 MHz */

static uint32_t spi_ctrl;		/* what CTRL holds */
static uint8_t  sd_blk;			/* the card counts in blocks, not bytes */

static uint8_t spi(uint8_t b) {
	SPI_DATA = b;
	return SPI_DATA;
}
static void sd_cs(int on) {
	if (on) spi_ctrl |= SPI_CS; else spi_ctrl &= ~SPI_CS;
	SPI_CTRL = spi_ctrl;
	if (!on) spi(0xff);
}

/* a command; the answer's first byte (0xff: none came) */
static uint8_t sd_cmd(uint8_t cmd, uint32_t arg) {
	uint8_t r;
	int n;
	spi(0xff);
	spi(0x40 | cmd);
	spi(arg >> 24); spi(arg >> 16); spi(arg >> 8); spi(arg);
	spi(cmd == 0 ? 0x95 : cmd == 8 ? 0x87 : 0x01);
	for (n = 0; n < 16; n++) {
		r = spi(0xff);
		if (!(r & 0x80)) break;
	}
	return r;
}

static int sd_init(void) {
	int n, v2;
	uint8_t r;
	uint32_t ocr = 0;

	if (SPI_MAGIC != 0x53504931) return 0;		/* no SPI master of this kind */
	spi_ctrl = SPI_DIV(DIV_INIT);
	SPI_CTRL = spi_ctrl;
	for (n = 0; n < 12; n++) spi(0xff);			/* clocks with the card not selected */

	sd_cs(1);
	for (n = 0; n < 8 && (r = sd_cmd(0, 0)) != 0x01; n++) ;
	if (r != 0x01) { sd_cs(0); return 0; }

	v2 = (sd_cmd(8, 0x1aa) == 0x01);
	if (v2) { spi(0xff); spi(0xff); spi(0xff); spi(0xff); }
	for (n = 0; n < 20000; n++) {
		sd_cmd(55, 0);
		r = sd_cmd(41, v2 ? 0x40000000 : 0);
		if (r == 0x00) break;
		if (r != 0x01) { sd_cs(0); return 0; }
	}
	if (r != 0x00) { sd_cs(0); return 0; }
	sd_blk = 0;
	if (v2 && sd_cmd(58, 0) == 0x00) {
		ocr = (uint32_t)spi(0xff) << 24; spi(0xff); spi(0xff); spi(0xff);
		sd_blk = (ocr >> 30) & 1;
	}
	if (!sd_blk) sd_cmd(16, 512);
	sd_cs(0);

	spi_ctrl = SPI_DIV(DIV_FAST);
	SPI_CTRL = spi_ctrl;
	return 1;
}

/* a sector, to anywhere a word can be stored */
static int sd_read(uint32_t lba, uint32_t *to) {
	int n, ok = 0;
	uint8_t r;
	sd_cs(1);
	if (sd_cmd(17, sd_blk ? lba : lba << 9) == 0x00) {
		for (n = 0; n < 100000 && (r = spi(0xff)) == 0xff; n++) ;
		if (r == 0xfe) {
			SPI_CTRL = spi_ctrl | SPI_W32;
			for (n = 0; n < 128; n++) {
				SPI_DATA = 0xffffffff;
				to[n] = SPI_DATA;		/* (the master puts the first byte lowest) */
			}
			SPI_CTRL = spi_ctrl;
			spi(0xff); spi(0xff);		/* the CRC, not checked */
			ok = 1;
		}
	}
	sd_cs(0);
	return ok;
}

/* -- the file system -- */

static uint32_t sec[128];		/* a sector of a directory or a file's end */
static uint32_t fat[128];		/* a sector of the table */
static uint32_t fat_at;			/* which one (0: none) */
static uint32_t v_fat, v_data, v_root, v_rootn;	/* sectors; v_root a cluster on FAT32 */
static uint8_t  v_spc, v_32;

#define B(p, o)   (((const uint8_t *)(p))[o])
#define W16(p, o) (B(p, o) | B(p, o + 1) << 8)
#define W32(p, o) ((uint32_t)W16(p, o) | (uint32_t)W16(p, o + 2) << 16)

static int fat_mount(void) {
	uint32_t base = 0, tot, fsz, rsv, nclu;
	if (!sd_read(0, sec)) return 0;
	if (W16(sec, 510) != 0xaa55) return 0;
	if (!((B(sec, 0) == 0xeb || B(sec, 0) == 0xe9) && W16(sec, 11) == 512)) {
		/* a partition table: the first partition */
		base = W32(sec, 0x1c6);
		if (!base || !sd_read(base, sec)) return 0;
		if (W16(sec, 510) != 0xaa55 || W16(sec, 11) != 512) return 0;
	}
	v_spc = B(sec, 13);
	rsv = W16(sec, 14);
	v_rootn = W16(sec, 17);
	tot = W16(sec, 19); if (!tot) tot = W32(sec, 32);
	fsz = W16(sec, 22); if (!fsz) fsz = W32(sec, 36);
	if (!v_spc || !fsz) return 0;
	v_fat = base + rsv;
	v_root = v_fat + B(sec, 16) * fsz;				/* FAT16: the root's sectors */
	v_data = v_root + ((v_rootn * 32 + 511) >> 9);
	nclu = (tot - (v_data - base)) / v_spc;
	if (nclu < 4085) return 0;						/* FAT12: no */
	/* FAT32 by what the boot sector says of itself (no 16 bit FAT size, no
	   root directory of its own), not by the count of clusters alone: mkfs
	   will make a FAT32 with fewer than the rule allows when asked to */
	v_32 = (nclu >= 65525) || (W16(sec, 22) == 0 && v_rootn == 0);
	if (v_32) v_root = W32(sec, 44);
	fat_at = 0;
	return 1;
}

/* the cluster after this one; 0 at the end */
static uint32_t fat_next(uint32_t c) {
	uint32_t s = v_fat + (v_32 ? c >> 7 : c >> 8), n;
	if (s != fat_at) {
		if (!sd_read(s, fat)) return 0;
		fat_at = s;
	}
	if (v_32) { n = fat[c & 127] & 0x0fffffff; return n >= 0x0ffffff8 || n < 2 ? 0 : n; }
	n = W16(fat, (c & 255) * 2);
	return n >= 0xfff8 || n < 2 ? 0 : n;
}

static char up(char c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }

/* the entry for a name (of n characters) in a directory (its first
 * cluster; 0: the root); its first cluster and size; 0 if not there */
static int fat_find(uint32_t dir, const char *name, int n, uint32_t *clu, uint32_t *size) {
	char lfn[80];
	int have = 0, fixed = (dir == 0 && !v_32), i, k;
	uint32_t c = dir ? dir : v_root, s, base, nsec;

	for (;;) {
		/* FAT16's root is a run of sectors; everything else is clusters */
		base = fixed ? v_root : v_data + (c - 2) * v_spc;
		nsec = fixed ? v_data - v_root : v_spc;
		for (s = 0; s < nsec; s++) {
			if (!sd_read(base + s, sec)) return 0;
			for (i = 0; i < 512; i += 32) {
				const uint8_t *e = (const uint8_t *)sec + i;
				if (e[0] == 0) return 0;
				if (e[0] == 0xe5) { have = 0; continue; }
				if (e[11] == 0x0f) {
					/* a piece of a long name: thirteen characters, the last piece first */
					static const uint8_t at[13] = { 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
					int seq = (e[0] & 0x3f) - 1;
					if (seq < 0 || seq > 5) { have = 0; continue; }
					if (e[0] & 0x40) { for (k = 0; k < 80; k++) lfn[k] = 0; have = 1; }
					for (k = 0; k < 13; k++) lfn[seq * 13 + k] = e[at[k] + 1] ? '?' : e[at[k]];
					continue;
				}
				if (!(e[11] & 0x08)) {
					int hit = 0;
					if (have) {
						for (k = 0; k < n && up(lfn[k]) == up(name[k]); k++) ;
						hit = (k == n && lfn[n] == 0);
					}
					if (!hit) {
						/* the short name: eight and three, padded */
						char sn[13];
						int j = 0;
						for (k = 0; k < 8 && e[k] != ' '; k++) sn[j++] = e[k];
						if (e[8] != ' ') { sn[j++] = '.'; for (k = 8; k < 11 && e[k] != ' '; k++) sn[j++] = e[k]; }
						for (k = 0; k < n && k < j && sn[k] == up(name[k]); k++) ;
						hit = (k == n && j == n);
					}
					if (hit) {
						*clu = W16(e, 26) | (v_32 ? (uint32_t)W16(e, 20) << 16 : 0);
						*size = W32(e, 28);
						return 1;
					}
				}
				have = 0;
			}
		}
		if (fixed) return 0;
		c = fat_next(c);
		if (!c) return 0;
	}
}

/* a path from the root, or a name in /sys/linux */
static int fat_open(const char *path, int n, uint32_t *clu, uint32_t *size) {
	uint32_t dir = 0;
	int i;
	if (n && path[0] == '/') { path++; n--; }
	else {
		if (!fat_find(0, "sys", 3, &dir, size)) return 0;
		if (!fat_find(dir, "linux", 5, &dir, size)) return 0;
	}
	for (;;) {
		for (i = 0; i < n && path[i] != '/'; i++) ;
		if (!fat_find(dir, path, i, clu, size)) return 0;
		if (i == n) return 1;
		dir = *clu; path += i + 1; n -= i + 1;
	}
}

/* a file's bytes to an address (a multiple of four) */
static int fat_load(uint32_t clu, uint32_t size, uint32_t *to) {
	uint32_t left = (size + 511) >> 9;
	int s;
	while (left && clu) {
		for (s = 0; s < v_spc && left; s++, left--, to += 128)
			if (!sd_read(v_data + (clu - 2) * v_spc + s, to)) return 0;
		if (left) clu = fat_next(clu);
	}
	return left == 0;
}

/* -- boot.json, and off we go -- */

static uint32_t js[128];

static int sd_boot(void) {
	uint32_t clu, size, dtb = DTB_ADDR, adr, entry = MEM_MAIN;
	const char *p, *name, *end;
	int n, loaded = 0;

	if (!sd_init()) { print("sd: no card\n"); return 0; }
	if (!fat_mount()) { print("sd: no FAT16 or FAT32 on it\n"); return 0; }
	if (!fat_open("boot.json", 9, &clu, &size)) { print("sd: no /sys/linux/boot.json\n"); return 0; }
	if (size > 508 || !sd_read(v_data + (clu - 2) * v_spc, js)) { print("sd: boot.json: too long\n"); return 0; }
	((char *)js)[size] = 0;

	p = (const char *)js;
	end = p + size;
	for (;;) {
		/* "name" : "0x..." */
		while (p < end && *p != '"' && *p != '}') p++;
		if (p >= end || *p == '}') break;
		name = ++p;
		while (p < end && *p != '"') p++;
		n = p - name;
		p++;
		while (p < end && (*p == ' ' || *p == ':' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
		if (p < end && *p == '{') {				/* an object: not ours */
			while (p < end && *p != '}') p++;
			p++;
			continue;
		}
		if (p >= end || *p != '"') break;
		p++;
		adr = 0;
		if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
		for (; p < end && *p != '"'; p++) {
			char c = up(*p);
			adr = adr << 4 | (c >= 'A' ? c - 'A' + 10 : c - '0');
		}
		p++;

		print("sd: ");
		for (int k = 0; k < n; k++) putc_(name[k]);
		if (!fat_open(name, n, &clu, &size)) { print(": not there\n"); return 0; }
		print(" -> "); print_hex(adr, 8);
		if (adr & 3) { print(": not a multiple of four\n"); return 0; }
		if (!fat_load(clu, size, (uint32_t *)adr)) { print(": read error\n"); return 0; }
		print(", "); print_hex(size, 8); print(" bytes\n");
		if (n > 4 && name[n - 4] == '.' && up(name[n - 3]) == 'D' && up(name[n - 2]) == 'T' && up(name[n - 1]) == 'B')
			dtb = adr;
		if (!loaded) entry = adr;
		loaded++;
	}
	if (!loaded) { print("sd: boot.json names nothing\n"); return 0; }
	print("go\n");
	while (!(UART_LSR & 0x40)) ;
	((void (*)(unsigned long, unsigned long))(uintptr_t)entry)(0, (unsigned long)dtb);
	return 0;
}
