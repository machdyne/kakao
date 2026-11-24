/*
 * The I/O processor's program on a machine without a terminal (no
 * monitor, no USB host: Klinge): the host's virtio devices and nothing
 * else. The SD card as a disk (vblk.c), the network (vnet.c).
 *
 *   make iop-headless.hex
 */

#include <stddef.h>
#include "virtio.h"

/* (what the devices use of the C library) */
void *memcpy(void *to, const void *from, size_t n)
{
	unsigned char *t = to;
	const unsigned char *f = from;
	while (n--) *t++ = *f++;
	return to;
}

void *memset(void *to, int c, size_t n)
{
	unsigned char *t = to;
	while (n--) *t++ = (unsigned char)c;
	return to;
}

void main(void)
{
	vblk_init();
	vnet_init();
	for (;;) {
		virtio_poll();
		virtio_notified();
		vblk_poll();
		vnet_poll();
	}
}
