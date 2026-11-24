/*
 * The virtio devices the I/O processor is (rtl/k_virtio.v has their
 * slots): what a device says of itself, and the queues' handling that
 * all of them share. The host's memory is at the host's addresses, so
 * what a queue points at is read and written as it stands.
 */
#ifndef VIRTIO_H
#define VIRTIO_H

#include <stdint.h>

#define VQ_MAX   256		/* descriptors a queue can have, at the most (a device says: qmax) */
#define VQ_N     2			/* queues a device can have */

struct vq {
	uint32_t desc, avail, used;	/* where the driver put them */
	uint16_t num;				/* descriptors: a power of two */
	uint16_t last;				/* the next of the driver's entries to take */
	uint8_t  ready;
};

struct vdev {
	uint32_t id;				/* the kind of device (0: none here) */
	uint32_t feat;				/* what it offers, of the first 32 */
	uint8_t  slot;
	uint8_t  status, fsel, dsel, qsel;
	uint8_t  nq;
	uint16_t qmax;				/* descriptors a queue of its can have: a power of two */
	const uint32_t *cfg;		/* its configuration, cfg_words words */
	uint8_t  cfg_words;
	void (*start)(struct vdev *d);		/* the host looks at the slot for the first time */
	void (*reset)(struct vdev *d);
	struct vq q[VQ_N];
};

/* a descriptor, as it is in the host's memory */
struct vdesc {
	uint32_t addr, addr_hi;
	uint32_t len;
	uint16_t flags, next;
};
#define VD_NEXT   1
#define VD_WRITE  2

void virtio_add(struct vdev *d, int slot);
void virtio_poll(void);				/* the host's registers */
uint32_t virtio_notified(void);		/* queues notified since asked last: bit 4 * slot + queue */

/* the next chain the driver has put into the queue: its first
   descriptor's number, or -1 */
int vq_take(struct vq *q);
/* descriptor i, or 0 if it is not one or points outside the host's memory */
const struct vdesc *vq_desc(struct vq *q, unsigned i);
/* the chain that began with head is done, len bytes written into it */
void vq_done(struct vdev *d, struct vq *q, unsigned head, uint32_t len);

/* vblk.c: the SD card as a disk */
void vblk_init(void);
void vblk_poll(void);

/* vnet.c: the network */
void vnet_init(void);
void vnet_poll(void);

#endif
