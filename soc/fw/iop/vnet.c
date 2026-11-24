/*
 * The network as a virtio network device, in the second slot: queue 0
 * takes what is received, queue 1 brings what is to be sent, and each
 * frame has virtio's header of 12 bytes before it, of which only the
 * count of buffers (one) says anything. No features: no checksums left
 * out, no merged buffers, and Linux gives the interface an address of
 * its own choosing (ip link set ... address sets another).
 */

#include "virtio.h"
#include "nic.h"

#define HDR 12

static struct vdev dev;
static uint32_t cfg[3];

static void net_start(struct vdev *d)
{
	if (!nic_init()) d->id = 0;		/* no interface on this board: no device */
}

void vnet_init(void)
{
	dev.id = 1;
	dev.feat = 0;
	dev.nq = 2;
	/* (Linux's driver stops sending while fewer than 19 descriptors
	   are free, whatever a frame needs: 16 would be none at all) */
	dev.qmax = 64;
	dev.cfg = cfg;
	dev.cfg_words = 3;
	dev.start = net_start;
	virtio_add(&dev, 1);
}

/* a received frame into a buffer of the driver's, after the header.
   Linux's buffers begin two bytes after a word (so that the IP header
   is on one), and then a word of the frame goes into two of the
   buffer's. */
static void frame_out(uint32_t d, const volatile uint32_t *src, unsigned len)
{
	unsigned words = len >> 2, i;

	if (!(d & 3)) {
		volatile uint32_t *q = (volatile uint32_t *)d;
		for (i = 0; i < words; i++) q[i] = src[i];
	} else if ((d & 3) == 2 && words) {
		volatile uint32_t *q = (volatile uint32_t *)(d + 2);
		uint32_t w = src[0], carry = w >> 16;
		*(volatile uint16_t *)d = (uint16_t)w;
		for (i = 1; i < words; i++) {
			w = src[i];
			*q++ = carry | w << 16;
			carry = w >> 16;
		}
		*(volatile uint16_t *)q = (uint16_t)carry;
	} else
		words = 0;
	for (i = words << 2; i < len; i++)
		((volatile uint8_t *)d)[i] = (uint8_t)(src[i >> 2] >> (8 * (i & 3)));
}

static void rx(void)
{
	struct vq *q = &dev.q[0];
	const volatile uint32_t *f;
	const struct vdesc *d;
	unsigned len, i;
	int head;

	f = nic_rx(&len);
	if (!f) return;
	if (!(dev.status & 4)) { nic_rx_done(); return; }	/* nobody listens: it is dropped */
	head = vq_take(q);
	if (head < 0) return;				/* no buffer yet: the frame waits where it is */
	d = vq_desc(q, (unsigned)head);
	if (d && (d->flags & VD_WRITE) && d->len >= HDR + len) {
		volatile uint8_t *h = (volatile uint8_t *)d->addr;
		for (i = 0; i < HDR; i++) h[i] = (i == 10);		/* one buffer */
		frame_out(d->addr + HDR, f, len);
		vq_done(&dev, q, (unsigned)head, HDR + len);
	} else
		vq_done(&dev, q, (unsigned)head, 0);
	nic_rx_done();
}

static void tx(void)
{
	struct vq *q = &dev.q[1];
	volatile uint32_t *buf;
	const struct vdesc *d;
	unsigned skip = HDR, n = 0, at, turns = 0;
	uint32_t w = 0;
	int head;

	if (!(dev.status & 4)) return;
	buf = nic_tx_buf();
	if (!buf) return;
	head = vq_take(q);
	if (head < 0) return;

	/* the chain's bytes one after another, the header left out, into
	   the frame's words */
	at = (unsigned)head;
	while ((d = vq_desc(q, at)) != 0 && ++turns <= q->num) {
		uint32_t a = d->addr, left = d->len;
		if (skip) {
			unsigned s = skip < left ? skip : left;
			a += s; left -= s; skip -= s;
		}
		if (n + left > 1518) break;
		if (!(n & 3) && !(a & 3)) {
			for (; left >= 4; left -= 4, a += 4, n += 4) buf[n >> 2] = *(const volatile uint32_t *)a;
		}
		for (; left; left--, a++) {
			w |= (uint32_t)*(const volatile uint8_t *)a << (8 * (n & 3));
			if ((++n & 3) == 0) { buf[(n >> 2) - 1] = w; w = 0; }
		}
		if (!(d->flags & VD_NEXT)) break;
		at = d->next;
	}
	if (n & 3) buf[n >> 2] = w;
	if (n >= 14) nic_tx(n);
	vq_done(&dev, q, (unsigned)head, 0);
}

void vnet_poll(void)
{
	if (!dev.id) return;
	rx();
	tx();
}
