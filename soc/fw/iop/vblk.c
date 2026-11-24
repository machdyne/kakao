/*
 * The SD card as a virtio block device, in the first slot. A request
 * is done a sector a turn (vblk_poll), so that the terminal and the
 * keyboard go on meanwhile; a sector goes straight between the card
 * and the host's memory when the host's buffer is on a word, and
 * through one here when it is not.
 */

#include "virtio.h"
#include "sd.h"
#include "string.h"

#define BLK_IN     0
#define BLK_OUT    1
#define BLK_FLUSH  4
#define BLK_GET_ID 8

#define ST_OK      0
#define ST_IOERR   1
#define ST_UNSUPP  2

static uint32_t cfg[2];			/* the capacity, in sectors (64 bits) */
static struct vdev dev;

/* the request in hand */
static struct {
	uint8_t  on, type, status;
	uint16_t head, at;			/* its first descriptor, and the one being done */
	uint32_t sector, off, done;	/* ...how far into that one, and bytes read so far */
} rq;

static uint32_t bounce[128];

#ifdef VDEBUG
#define OUT (*(volatile uint32_t *)0x2000000c)
static void dbg(char c, uint32_t v)
{
	int i;
	OUT = (uint32_t)c;
	for (i = 28; i >= 0; i -= 4) OUT = (uint32_t)"0123456789abcdef"[(v >> i) & 15];
	OUT = ' ';
}
#else
#define dbg(c, v)
#endif

static void blk_start(struct vdev *d)
{
	uint32_t n = sd_init();
	cfg[0] = n; cfg[1] = 0;
	d->id = n ? 2 : 0;			/* no card: no device */
}

static void blk_reset(struct vdev *d)
{
	(void)d;
	rq.on = 0;
}

void vblk_init(void)
{
	dev.id = 2;
	dev.feat = 0;
	dev.nq = 1;
	dev.qmax = 16;
	dev.cfg = cfg;
	dev.cfg_words = 2;
	dev.start = blk_start;
	dev.reset = blk_reset;
	virtio_add(&dev, 0);
}

static void finish(void)
{
	struct vq *q = &dev.q[0];
	const struct vdesc *d = vq_desc(q, rq.at);
	if (d && (d->flags & VD_WRITE)) {
		*(volatile uint8_t *)(d->addr + d->len - 1) = rq.status;
		rq.done++;
	}
	vq_done(&dev, q, rq.head, rq.done);
	dbg('D', (uint32_t)rq.status << 28 | rq.done);
	rq.on = 0;
}

void vblk_poll(void)
{
	struct vq *q = &dev.q[0];
	const struct vdesc *d;

	if (sd_busy()) return;

	if (!rq.on) {
		const volatile uint32_t *h;
		int head;
		if (!(dev.status & 4)) return;			/* the driver is not there yet */
		head = vq_take(q);
		if (head < 0) return;
		rq.on = 1; rq.head = (uint16_t)head; rq.done = 0; rq.off = 0;
		rq.status = ST_IOERR;
		d = vq_desc(q, (unsigned)head);
		if (!d || d->len < 16 || !(d->flags & VD_NEXT)) { rq.at = rq.head; finish(); return; }
		h = (const volatile uint32_t *)d->addr;
		rq.type = (uint8_t)h[0];
		rq.sector = h[2];
		rq.at = d->next;
		if (h[3]) rq.type = 0xff;				/* beyond any card here */
		dbg('T', (uint32_t)rq.type << 28 | rq.sector);
		rq.status = ST_OK;
		return;
	}

	d = vq_desc(q, rq.at);
	if (!d) { rq.status = ST_IOERR; finish(); return; }
	if (!(d->flags & VD_NEXT)) { finish(); return; }	/* the last is the status */
	if (!rq.off) dbg('d', d->len << 4 | d->flags);

	if (rq.status == ST_OK && (rq.type == BLK_IN || rq.type == BLK_OUT)) {
		uint32_t a = d->addr + rq.off;
		int direct = !(a & 3), ok;
		if (d->len - rq.off < 512 || rq.sector >= cfg[0] ||
		    !(d->flags & VD_WRITE) != (rq.type == BLK_OUT))
			ok = 0;
		else if (rq.type == BLK_IN) {
			ok = sd_read(rq.sector, direct ? (uint32_t *)a : bounce);
			if (ok && !direct) memcpy((void *)a, bounce, 512);
			if (ok) rq.done += 512;
		} else {
			if (!direct) memcpy(bounce, (const void *)a, 512);
			ok = sd_write(rq.sector, direct ? (const uint32_t *)a : bounce);
		}
		if (!ok) rq.status = ST_IOERR;
		rq.sector++;
		rq.off += 512;
		if (ok && rq.off < d->len) return;
	} else if (rq.status == ST_OK && rq.type == BLK_GET_ID) {
		if ((d->flags & VD_WRITE) && d->len >= 20) {
			memset((void *)d->addr, 0, 20);
			memcpy((void *)d->addr, "kakao-sd", 8);
			rq.done += 20;
		}
	} else if (rq.status == ST_OK && rq.type != BLK_FLUSH)
		rq.status = ST_UNSUPP;

	rq.off = 0;
	rq.at = d->next;
}
