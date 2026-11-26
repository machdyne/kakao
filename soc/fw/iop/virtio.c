/*
 * The virtio slots' registers (virtio over MMIO, version 2) and the
 * queues. The host waits while a register is answered here.
 */

#include "virtio.h"

#define VREQ    (*(volatile uint32_t *)0x30000000)
#define VWDAT   (*(volatile uint32_t *)0x30000004)
#define VRSP    (*(volatile uint32_t *)0x30000008)
#define VNOTIFY (*(volatile uint32_t *)0x3000000c)
#define VIRQ    (*(volatile uint32_t *)0x30000010)

static struct vdev *devs[4];

void virtio_add(struct vdev *d, int slot)
{
	d->slot = (uint8_t)slot;
	devs[slot] = d;
}

static void dev_reset(struct vdev *d)
{
	int i;
	d->status = 0; d->fsel = 0; d->dsel = 0; d->qsel = 0;
	for (i = 0; i < VQ_N; i++) {
		d->q[i].ready = 0; d->q[i].last = 0; d->q[i].num = d->qmax;
	}
	if (d->reset) d->reset(d);
}

static uint32_t reg_read(struct vdev *d, uint32_t off)
{
	struct vq *q = d->qsel < d->nq ? &d->q[d->qsel] : 0;
	if (off >= 0x100) {
		if (d->cfg_read) return d->cfg_read(d, off - 0x100);
		off = (off - 0x100) >> 2;
		return off < d->cfg_words ? d->cfg[off] : 0;
	}
	switch (off) {
	case 0x000: return 0x74726976;			/* "virt" */
	case 0x004: return 2;
	case 0x008: return d->id;
	case 0x00c: return 0x4f4b414b;			/* "KAKO" */
	case 0x010: return d->fsel == 0 ? d->feat : d->fsel == 1 ? 1 : 0;	/* (bit 32: version 1) */
	case 0x034: return q ? d->qmax : 0;
	case 0x044: return q ? q->ready : 0;
	case 0x070: return d->status;
	}
	return 0;
}

static void reg_write(struct vdev *d, uint32_t off, uint32_t v, uint32_t sel)
{
	struct vq *q = d->qsel < d->nq ? &d->q[d->qsel] : 0;
	if (off >= 0x100) {
		if (d->cfg_write) d->cfg_write(d, off - 0x100, v, sel);
		return;
	}
	switch (off) {
	case 0x014: d->fsel = (uint8_t)(v > 2 ? 2 : v); return;
	case 0x024: d->dsel = (uint8_t)v; return;
	case 0x030: d->qsel = (uint8_t)(v > 255 ? 255 : v); return;
	case 0x070:
		if (!v) dev_reset(d); else d->status = (uint8_t)v;
		return;
	}
	if (!q) return;
	switch (off) {
	case 0x038: if (v && v <= d->qmax && !(v & (v - 1))) q->num = (uint16_t)v; break;
	case 0x044: q->ready = v & 1; break;
	case 0x080: q->desc = v; break;
	case 0x090: q->avail = v; break;
	case 0x0a0: q->used = v; break;
	}
}

void virtio_poll(void)
{
	static uint8_t started;
	uint32_t r = VREQ, v = 0;
	struct vdev *d;

	if (!(r & 0x80000000u)) return;
	d = devs[(r >> 16) & 3];
	if (d) {
		if (!(started & (1 << d->slot))) {
			started |= (uint8_t)(1 << d->slot);
			dev_reset(d);
			if (d->start) d->start(d);
		}
		if (r & 0x40000000u) reg_write(d, r & 0xffc, VWDAT, (r >> 20) & 15);
		else v = reg_read(d, r & 0xffc);
	} else if (!(r & 0x40000000u)) {
		/* an empty slot: a device of no kind */
		if ((r & 0xffc) == 0) v = 0x74726976;
		else if ((r & 0xffc) == 4) v = 2;
	}
	VRSP = v;
}

uint32_t virtio_notified(void)
{
	uint32_t n = VNOTIFY;
	if (n) VNOTIFY = n;
	return n;
}

/* the host's memory, and nothing else, is what a queue may point at */
static int in_host(uint32_t a, uint32_t len)
{
	return (a >> 29) == 4 && len <= 0x20000000u && ((a + len - 1) >> 29) == 4;
}

int vq_take(struct vq *q)
{
	const volatile uint16_t *av;
	unsigned head;
	if (!q->ready || !in_host(q->avail, 4 + 2 * (uint32_t)q->num) || !in_host(q->used, 4 + 8 * (uint32_t)q->num) ||
	    !in_host(q->desc, 16 * (uint32_t)q->num))
		return -1;
	av = (const volatile uint16_t *)q->avail;	/* flags, idx, ring[] */
	if (av[1] == q->last) return -1;
	head = av[2 + (q->last & (q->num - 1))];
	q->last++;
	return (int)(head & (q->num - 1));
}

const struct vdesc *vq_desc(struct vq *q, unsigned i)
{
	const struct vdesc *d = (const struct vdesc *)(q->desc + 16 * (i & (q->num - 1)));
	if (d->addr_hi || !d->len || !in_host(d->addr, d->len)) return 0;
	return d;
}

void vq_done(struct vdev *d, struct vq *q, unsigned head, uint32_t len)
{
	volatile uint16_t *us = (volatile uint16_t *)q->used;		/* flags, idx, ring[] of { id, len } */
	volatile uint32_t *e = (volatile uint32_t *)(q->used + 4 + 8 * (us[1] & (q->num - 1)));
	e[0] = head;
	e[1] = len;
	us[1] = (uint16_t)(us[1] + 1);
	/* the interrupt, unless the driver has said it is not listening */
	if (!(*(const volatile uint16_t *)q->avail & 1)) VIRQ = 1u << (2 * d->slot);
}
