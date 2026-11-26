/*
 * virtio network device over virtio-mmio, version 2 of the transport
 * ("Virtual I/O Device (VIRTIO) Version 1.1", sections 2, 4.2 and 5.1):
 * QEMU's virt machine and the Kakao SOC's network device.
 *
 * Written for the Kakao port.  ethertemu.c in this directory is a driver
 * for tinyemu's device and takes shortcuts that device allows; this one
 * does what the specification asks.
 *
 * One interface.  The device's register page is one of the virtio slots
 * the device tree names (kkfdt.c).
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"

#include "../port/netif.h"
#include "etherif.h"
#include "kkfdt.h"

enum {
	/* registers */
	Magic		= 0x000,
		Magicvirt	= 0x74726976,		/* "virt" */
	Version		= 0x004,
	Deviceid	= 0x008,
		Devnet		= 1,
	Devfeat		= 0x010,
	Devfeatsel	= 0x014,
	Drvfeat		= 0x020,
	Drvfeatsel	= 0x024,
	Queuesel	= 0x030,
	Queuenummax	= 0x034,
	Queuenum	= 0x038,
	Queueready	= 0x044,
	Queuenotify	= 0x050,
	Intstatus	= 0x060,
	Intack		= 0x064,
	Status		= 0x070,
		Sack		= 1<<0,
		Sdriver		= 1<<1,
		Sdriverok	= 1<<2,
		Sfeatok		= 1<<3,
		Sfailed		= 1<<7,
	Queuedesc	= 0x080,
	Queuedriver	= 0x090,
	Queuedevice	= 0x0a0,
	Config		= 0x100,

	/* feature bits: word 0 */
	Fmac		= 1<<5,		/* the device has a MAC address */
	/* word 1 */
	Fversion1	= 1<<0,		/* bit 32: not a legacy device */

	/* descriptor flags */
	Dnext		= 1<<0,
	Dwrite		= 1<<1,		/* the device writes the buffer */

	Rx		= 0,
	Tx		= 1,
	Nqueue		= 2,

	Maxqsize	= 64,
	Nhdr		= 12,		/* struct virtio_net_hdr, version 1 */
	Rbsz		= 2048,		/* Nhdr + 1514 and room to spare */
};

typedef struct Ctlr Ctlr;
typedef struct Vdesc Vdesc;
typedef struct Vavail Vavail;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;

struct Vdesc {
	uvlong	addr;
	uint	len;
	ushort	flags;
	ushort	next;
};

struct Vavail {
	ushort	flags;
	ushort	idx;
	ushort	ring[Maxqsize];
};

/*
 * The used ring's elements are pairs of 32-bit words, the descriptor
 * then the length.  They are not declared as an array of structs: the
 * compiler would align that to 8 bytes and the ring starts at 4.
 */
struct Vused {
	ushort	flags;
	ushort	idx;
	uint	ring[2*Maxqsize];
};

struct Vqueue {
	int	n;			/* descriptors; a power of 2 */
	Vdesc	*desc;
	Vavail	*avail;
	Vused	*used;
	ushort	lastused;
	Block	*blk[Maxqsize];		/* the buffer of each descriptor */
	ushort	free[Maxqsize];		/* Tx: descriptors not in use */
	int	nfree;
};

struct Ctlr {
	Ether	*edev;
	uint	*mmio;
	uintptr	pa;
	Vqueue	q[Nqueue];
	Lock	txlock;
	QLock	alock;
	Rendez	rendez;
	int	attached;
	int	havemac;

	uint	rcved;
	uint	xmited;
	uint	intrs;
	uint	nobufs;
};

#define RD(r)		(ctlr->mmio[(r)>>2])
#define WR(r, v)	(ctlr->mmio[(r)>>2] = (v), coherence())

extern uchar ether0mac[];

static Ctlr virtnet;

static void
vqalloc(Ctlr *ctlr, int qi)
{
	int n;
	Vqueue *q;

	q = &ctlr->q[qi];
	WR(Queuesel, qi);
	n = RD(Queuenummax);
	if(n == 0)
		panic("ethervirtio: queue %d not available", qi);
	if(n > Maxqsize)
		n = Maxqsize;
	while(!ispow2(n))
		n &= n - 1;
	q->n = n;
	q->lastused = 0;
	/* each part page-aligned and zeroed; the kernel's memory is contiguous */
	q->desc = mallocalign(n * sizeof(Vdesc), PGSZ, 0, 0);
	q->avail = mallocalign(sizeof(Vavail), PGSZ, 0, 0);
	q->used = mallocalign(sizeof(Vused), PGSZ, 0, 0);
	if(q->desc == nil || q->avail == nil || q->used == nil)
		panic("ethervirtio: no memory for queue %d", qi);

	WR(Queuenum, n);
	WR(Queuedesc, (uint)PADDR(q->desc));
	WR(Queuedesc+4, (uvlong)PADDR(q->desc) >> 32);
	WR(Queuedriver, (uint)PADDR(q->avail));
	WR(Queuedriver+4, (uvlong)PADDR(q->avail) >> 32);
	WR(Queuedevice, (uint)PADDR(q->used));
	WR(Queuedevice+4, (uvlong)PADDR(q->used) >> 32);
}

/* give descriptor id of the receive queue a fresh buffer and the device both */
static int
rxfill(Vqueue *q, int id)
{
	Block *b;
	Vdesc *d;

	b = allocb(Rbsz);
	if(b == nil)
		return -1;
	q->blk[id] = b;
	d = &q->desc[id];
	d->addr = PADDR(b->wp);
	d->len = Rbsz;
	d->flags = Dwrite;
	d->next = 0;
	q->avail->ring[q->avail->idx & (q->n - 1)] = id;
	coherence();
	q->avail->idx++;
	coherence();
	return 0;
}

static void
virtiotransmit(Ether *edev)
{
	int id, sent;
	Block *b;
	Ctlr *ctlr;
	Vdesc *d;
	Vqueue *q;

	ctlr = edev->ctlr;
	if(ctlr == nil || !ctlr->attached)
		return;
	q = &ctlr->q[Tx];
	sent = 0;
	ilock(&ctlr->txlock);
	while(q->nfree > 0 && (b = qget(edev->oq)) != nil){
		b = padblock(b, Nhdr);
		memset(b->rp, 0, Nhdr);		/* no offloads, one buffer */
		id = q->free[--q->nfree];
		q->blk[id] = b;
		d = &q->desc[id];
		d->addr = PADDR(b->rp);
		d->len = BLEN(b);
		d->flags = 0;
		d->next = 0;
		q->avail->ring[q->avail->idx & (q->n - 1)] = id;
		coherence();
		q->avail->idx++;
		coherence();
		sent++;
	}
	iunlock(&ctlr->txlock);
	if(sent)
		WR(Queuenotify, Tx);
}

static int
haswork(void *arg)
{
	Ctlr *ctlr;

	ctlr = arg;
	return ctlr->q[Rx].used->idx != ctlr->q[Rx].lastused ||
		ctlr->q[Tx].used->idx != ctlr->q[Tx].lastused;
}

static void
virtioproc(void *arg)
{
	int id, len, got, done;
	Block *b;
	Ctlr *ctlr;
	Ether *edev;
	Vqueue *q;
	uint *e;

	edev = arg;
	ctlr = edev->ctlr;
	for(;;){
		/* received frames */
		q = &ctlr->q[Rx];
		got = 0;
		while(q->used->idx != q->lastused){
			e = &q->used->ring[2*(q->lastused & (q->n - 1))];
			id = e[0];
			len = e[1];
			q->lastused++;
			if(id < 0 || id >= q->n || (b = q->blk[id]) == nil){
				print("ethervirtio: bad used id %d\n", id);
				continue;
			}
			q->blk[id] = nil;
			if(len > Nhdr && len <= Rbsz){
				b->wp += len;
				b->rp += Nhdr;
				etheriq(edev, b, 1);
				ctlr->rcved++;
			}else
				freeb(b);
			if(rxfill(q, id) < 0)
				ctlr->nobufs++;
			got = 1;
		}
		if(got)
			WR(Queuenotify, Rx);

		/* frames the device has sent */
		q = &ctlr->q[Tx];
		done = 0;
		while(q->used->idx != q->lastused){
			e = &q->used->ring[2*(q->lastused & (q->n - 1))];
			id = e[0];
			q->lastused++;
			if(id < 0 || id >= q->n || (b = q->blk[id]) == nil){
				print("ethervirtio: bad used id %d\n", id);
				continue;
			}
			ilock(&ctlr->txlock);
			q->blk[id] = nil;
			q->free[q->nfree++] = id;
			iunlock(&ctlr->txlock);
			freeb(b);
			ctlr->xmited++;
			done = 1;
		}
		if(done)
			virtiotransmit(edev);	/* what waited for a descriptor */

		if(!got && !done)
			tsleep(&ctlr->rendez, haswork, ctlr, 100);
	}
}

static Intrsvcret
virtiointerrupt(Ureg*, void *arg)
{
	uint st;
	Ctlr *ctlr;
	Ether *edev;

	edev = arg;
	ctlr = edev->ctlr;
	st = RD(Intstatus);
	if(st == 0)
		return Intrnotforme;
	WR(Intack, st);
	ctlr->intrs++;
	wakeup(&ctlr->rendez);
	return Intrforme;
}

static void
virtioattach(Ether *edev)
{
	int i;
	char name[KNAMELEN];
	Ctlr *ctlr;
	Vqueue *q;

	ctlr = edev->ctlr;
	qlock(&ctlr->alock);
	if(ctlr->attached){
		qunlock(&ctlr->alock);
		return;
	}
	vqalloc(ctlr, Rx);
	vqalloc(ctlr, Tx);

	q = &ctlr->q[Tx];
	for(i = 0; i < q->n; i++)
		q->free[q->nfree++] = i;
	q = &ctlr->q[Rx];
	for(i = 0; i < q->n; i++)
		if(rxfill(q, i) < 0)
			panic("ethervirtio: no receive buffers");

	for(i = 0; i < Nqueue; i++){
		WR(Queuesel, i);
		WR(Queueready, 1);
	}
	WR(Status, RD(Status) | Sdriverok);
	ctlr->attached = 1;
	snprint(name, sizeof name, "#l%d", edev->ctlrno);
	kproc(name, virtioproc, edev);
	qunlock(&ctlr->alock);
	WR(Queuenotify, Rx);
}

static void
virtioshutdown(Ether *edev)
{
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	WR(Status, 0);			/* reset: the device forgets the queues */
	delay(10);
}

static long
virtioifstat(Ether *edev, void *a, long n, ulong offset)
{
	char buf[256];
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	snprint(buf, sizeof buf,
		"virtio-mmio %#p irq %d %s\nrcv %ud\nxmit %ud\nintr %ud\nnobufs %ud\n",
		ctlr->pa, (int)edev->irq, ctlr->havemac? "device mac": "own mac",
		ctlr->rcved, ctlr->xmited, ctlr->intrs, ctlr->nobufs);
	return readstr(offset, a, n, buf);
}

static void
virtioprom(void*, int)
{
}

static void
virtiomcast(void*, uchar*, int)
{
}

/* the handshake up to FEATURES_OK; the queues are set up at attach */
static int
negotiate(Ctlr *ctlr)
{
	uint f0, f1;

	WR(Status, 0);				/* reset */
	WR(Status, Sack);
	WR(Status, Sack|Sdriver);
	WR(Devfeatsel, 0);
	f0 = RD(Devfeat);
	WR(Devfeatsel, 1);
	f1 = RD(Devfeat);
	if((f1 & Fversion1) == 0){
		print("ethervirtio: %#p: device does not offer VERSION_1\n", ctlr->pa);
		WR(Status, Sfailed);
		return -1;
	}
	ctlr->havemac = (f0 & Fmac) != 0;
	WR(Drvfeatsel, 0);
	WR(Drvfeat, f0 & Fmac);			/* nothing else: no offloads */
	WR(Drvfeatsel, 1);
	WR(Drvfeat, Fversion1);
	WR(Status, Sack|Sdriver|Sfeatok);
	if((RD(Status) & Sfeatok) == 0){
		print("ethervirtio: %#p: device refused our features\n", ctlr->pa);
		WR(Status, Sfailed);
		return -1;
	}
	return 0;
}

/*
 * The device has no address (the SOC's has none): make one up, as Linux
 * does.  ether0mac's first three bytes, which say it is locally
 * administered, then three from the clock as it stands now, which
 * differs from one power-up of a board to the next but is not much of a
 * random number.  Two boards on a network will rarely agree; a board
 * that has to keep its address needs it set some other way.
 */
static void
ownmac(uchar *ea)
{
	uvlong t;

	t = rdcltime();
	t ^= t >> 23;
	t *= 0x2545f4914f6cdd1dull;
	t ^= t >> 29;
	memmove(ea, ether0mac, 3);
	ea[3] = t >> 16;
	ea[4] = t >> 8;
	ea[5] = t;
}

static int
pnp(Ether *edev)
{
	int i, legacy;
	uint *mmio;
	Ctlr *ctlr;
	Vslot *s;

	ctlr = &virtnet;
	if(ctlr->mmio != nil)
		return -1;			/* the one interface is taken */
	legacy = 0;
	mmio = nil;
	s = nil;
	for(i = 0; i < nkkvslot; i++){
		s = &kkvslots[i];
		mmio = vmap(s->pa, PGSZ);
		if(mmio == nil)
			continue;
		if(mmio[Magic>>2] == Magicvirt && mmio[Deviceid>>2] == Devnet){
			if(mmio[Version>>2] == 2)
				break;
			legacy = 1;
		}
		vunmap(mmio, PGSZ);
	}
	if(i >= nkkvslot){
		if(legacy)
			print("ethervirtio: only a legacy virtio-mmio network device"
				" (QEMU: -global virtio-mmio.force-legacy=false)\n");
		return -1;
	}
	ctlr->mmio = mmio;
	ctlr->pa = s->pa;
	if(negotiate(ctlr) < 0){
		ctlr->mmio = nil;
		vunmap(mmio, PGSZ);
		return -1;
	}
	if(ctlr->havemac)
		for(i = 0; i < Eaddrlen; i++)
			edev->ea[i] = ((uchar*)mmio)[Config+i];
	else
		ownmac(edev->ea);

	edev->ctlr = ctlr;
	ctlr->edev = edev;
	edev->port = s->pa;
	edev->irq = s->irq;
	edev->mbps = 100;

	edev->attach = virtioattach;
	edev->interrupt = virtiointerrupt;
	edev->ifstat = virtioifstat;
	edev->transmit = virtiotransmit;
	edev->shutdown = virtioshutdown;
	edev->promiscuous = virtioprom;
	edev->multicast = virtiomcast;
	return 0;
}

void
ethervirtiolink(void)
{
	addethercard("virtio", pnp);
}
