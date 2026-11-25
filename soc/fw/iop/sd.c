/*
 * The SD card in SPI mode, a sector at a time, as kboot reads it
 * (fw/kboot/sdboot.c) and with writing. kboot has had the card before:
 * the SPI master becomes this side's with the first access to it (the
 * board sees to that), and the card is started again from CMD0.
 */

#include "sd.h"

#define SPI_DATA  (*(volatile uint32_t *)0x40000000)
#define SPI_CTRL  (*(volatile uint32_t *)0x40000008)
#define SPI_MAGIC (*(volatile uint32_t *)0x4000000c)
#define SPI_CS    1u
#define SPI_W32   2u
#define SPI_DIV(d) ((uint32_t)(d) << 8)
#define DIV_INIT  59			/* 400 kHz at 48 MHz */
#define DIV_FAST  1				/* 12 MHz */

static uint32_t spi_ctrl;
static uint8_t  sd_blk;			/* the card counts in blocks, not bytes */
static uint8_t  wr_busy;		/* selected still: it is writing */
static uint8_t  wr_err;			/* the last write: the card said it failed */
static uint8_t  inited;			/* sd_init has been through once */
static uint32_t card_size;
static uint32_t card_id[2];		/* two sums of its CID (both 0: none read) */

static uint8_t spi(uint8_t b)
{
	SPI_DATA = b;
	return (uint8_t)SPI_DATA;
}

static void sd_cs(int on)
{
	if (on) spi_ctrl |= SPI_CS; else spi_ctrl &= ~SPI_CS;
	SPI_CTRL = spi_ctrl;
	if (!on) spi(0xff);
}

static uint8_t sd_cmd(uint8_t cmd, uint32_t arg)
{
	int n;
	uint8_t r = 0xff;
	spi(0xff);
	spi(0x40 | cmd);
	spi((uint8_t)(arg >> 24)); spi((uint8_t)(arg >> 16)); spi((uint8_t)(arg >> 8)); spi((uint8_t)arg);
	spi(cmd == 0 ? 0x95 : cmd == 8 ? 0x87 : 0x01);
	for (n = 0; n < 16; n++) {
		r = spi(0xff);
		if (!(r & 0x80)) break;
	}
	return r;
}

/* wait for a block's start */
static int sd_token(void)
{
	int n;
	uint8_t r = 0xff;
	for (n = 0; n < 100000 && (r = spi(0xff)) == 0xff; n++) ;
	return r == 0xfe;
}

uint32_t sd_init(void)
{
	int n, v2;
	uint8_t r = 0xff, csd[16];
	uint32_t size = 0;

	/* (once: the disk and the network both ask, in whichever order the
	   host looks at them) */
	if (inited) return card_size;
	inited = 1;
	if (SPI_MAGIC != 0x53504931) return 0;
	wr_busy = 0; wr_err = 0;
	spi_ctrl = SPI_DIV(DIV_INIT);
	SPI_CTRL = spi_ctrl;
	for (n = 0; n < 12; n++) spi(0xff);

	sd_cs(1);
	for (n = 0; n < 8 && (r = sd_cmd(0, 0)) != 0x01; n++) ;
	if (r != 0x01) goto out;
	v2 = (sd_cmd(8, 0x1aa) == 0x01);
	if (v2) { spi(0xff); spi(0xff); spi(0xff); spi(0xff); }
	for (n = 0; n < 20000; n++) {
		sd_cmd(55, 0);
		r = sd_cmd(41, v2 ? 0x40000000 : 0);
		if (r != 0x01) break;
	}
	if (r != 0x00) goto out;
	sd_blk = 0;
	if (v2 && sd_cmd(58, 0) == 0x00) {
		sd_blk = (spi(0xff) >> 6) & 1;
		spi(0xff); spi(0xff); spi(0xff);
	}
	if (!sd_blk) sd_cmd(16, 512);

	/* how big it is: the CSD */
	if (sd_cmd(9, 0) == 0x00 && sd_token()) {
		for (n = 0; n < 16; n++) csd[n] = spi(0xff);
		spi(0xff); spi(0xff);
		if (csd[0] >> 6) {
			/* version 2: units of 512 KB */
			size = (((uint32_t)(csd[7] & 0x3f) << 16 | (uint32_t)csd[8] << 8 | csd[9]) + 1) << 10;
		} else {
			uint32_t c = (uint32_t)(csd[6] & 3) << 10 | (uint32_t)csd[7] << 2 | csd[8] >> 6;
			unsigned mult = (unsigned)(csd[9] & 3) << 1 | csd[10] >> 7;
			unsigned bl = csd[5] & 15;
			size = (c + 1) << (mult + 2 + bl - 9);
		}
	}
	/* which card it is: the CID, of which two sums are kept (the
	   network's address is made of them) */
	if (size && sd_cmd(10, 0) == 0x00 && sd_token()) {
		uint32_t a = 2166136261u, b = 0x4b414b4f;
		for (n = 0; n < 16; n++) {
			uint8_t c = spi(0xff);
			a = (a ^ c) * 16777619u;
			b = (b << 5 | b >> 27) + c * 0x9e3779b1u;
		}
		spi(0xff); spi(0xff);
		card_id[0] = a; card_id[1] = b;
	}
out:
	sd_cs(0);
	spi_ctrl = SPI_DIV(DIV_FAST);
	SPI_CTRL = spi_ctrl;
	card_size = size;
	return size;
}

const uint32_t *sd_ident(void)
{
	sd_init();
	return card_id;
}

int sd_read(uint32_t lba, uint32_t *to)
{
	int n, ok = 0;
	sd_cs(1);
	if (sd_cmd(17, sd_blk ? lba : lba << 9) == 0x00 && sd_token()) {
		SPI_CTRL = spi_ctrl | SPI_W32;
		for (n = 0; n < 128; n++) {
			SPI_DATA = 0xffffffff;
			to[n] = SPI_DATA;		/* (the master puts the first byte lowest) */
		}
		SPI_CTRL = spi_ctrl;
		spi(0xff); spi(0xff);		/* the CRC, not checked */
		ok = 1;
	}
	sd_cs(0);
	return ok;
}

int sd_write(uint32_t lba, const uint32_t *from)
{
	int n, ok = 0;
	sd_cs(1);
	if (sd_cmd(24, sd_blk ? lba : lba << 9) == 0x00) {
		spi(0xff);
		spi(0xfe);
		SPI_CTRL = spi_ctrl | SPI_W32;
		for (n = 0; n < 128; n++) SPI_DATA = from[n];
		SPI_CTRL = spi_ctrl;
		spi(0xff); spi(0xff);		/* a CRC, not looked at by the card */
		/* the card's verdict on the block: at once, or a byte or two later */
		{
			uint8_t r = 0xff;
			for (n = 0; n < 8 && ((r = spi(0xff)) & 0x11) != 0x01; n++) ;
			ok = (r & 0x1f) == 0x05;
		}
	}
	/* the card keeps its answer low while it writes, and stays selected
	   so that it can be asked (sd_busy) */
	if (ok) wr_busy = 1; else sd_cs(0);
	return ok;
}

int sd_busy(void)
{
	if (!wr_busy) return 0;
	if (spi(0xff) != 0xff) return 1;
	wr_busy = 0;
	sd_cs(0);
	/* It took the block; did it write it? Its status says (CMD13: two
	   bytes, both zero when nothing went wrong). */
	sd_cs(1);
	if (sd_cmd(13, 0) != 0x00) wr_err = 1;
	if (spi(0xff) != 0x00) wr_err = 1;
	sd_cs(0);
	return 0;
}

int sd_write_failed(void)
{
	int e = wr_err;
	wr_err = 0;
	return e;
}
