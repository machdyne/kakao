/*
 * Keyboards and mice as virtio input devices over virtio-mmio ("Virtual
 * I/O Device (VIRTIO) Version 1.1", section 5.8): QEMU's
 * virtio-keyboard-device, virtio-mouse-device and virtio-tablet-device.
 * A device sends events as Linux has them (type, code, value); a
 * keyboard's become characters for the console, a mouse's and a
 * tablet's movements of the pointer.
 *
 * The keys are a US keyboard's. A key held down repeats here: the
 * devices say down and up and nothing between, and leave repeating to
 * the host, which Linux's input layer does and this kernel otherwise
 * would not.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"

#define	Image	IMAGE
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include <keyboard.h>
#include "screen.h"
#include "kkfdt.h"

enum {
	/* registers: ethervirtio.c says what they are */
	Magic		= 0x000,
		Magicvirt	= 0x74726976,
	Version		= 0x004,
	Deviceid	= 0x008,
		Devinput	= 18,
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
	Config		= 0x100,	/* select[1] subsel[1] size[1] pad[5] answer[128] */
		Cfgabsinfo	= 0x12,	/* answer: min[4] max[4] fuzz[4] flat[4] res[4] */

	Fversion1	= 1<<0,		/* feature bit 32 */
	Dwrite		= 1<<1,

	Nev		= 32,		/* events the device may have on its way */
	Maxinput	= 4,

	Repdelay	= 400,		/* ms a key is held before it repeats */
	Reprate		= 40,		/* ...and between repeats */
	Reptick		= 20,		/* how often that is looked at */

	/* events */
	Evsyn		= 0,
	Evkey		= 1,
	Evrel		= 2,
	Evabs		= 3,

	Relx		= 0,
	Rely		= 1,
	Relwheel	= 8,
	Absx		= 0,
	Absy		= 1,
	Absmax		= 0x7fff,	/* QEMU's tablet, if a device does not say */

	Btnleft		= 0x110,
	Btnright	= 0x111,
	Btnmiddle	= 0x112,
	Btnwheelup	= 0x150,	/* QEMU sends the wheel as buttons too */
	Btnwheeldown	= 0x151,

	Keyctl		= 29,
	Keylshift	= 42,
	Keyrshift	= 54,
	Keyalt		= 56,
	Keycaps		= 58,
	Keyrctl		= 97,
	Keyraltgr	= 100,
};

typedef struct Vdesc Vdesc;
typedef struct Vavail Vavail;
typedef struct Vused Vused;
typedef struct Vevent Vevent;
typedef struct Input Input;

struct Vdesc {
	uvlong	addr;
	uint	len;
	ushort	flags;
	ushort	next;
};

struct Vavail {
	ushort	flags;
	ushort	idx;
	ushort	ring[Nev];
};

struct Vused {			/* the ring as words: ethervirtio.c says why */
	ushort	flags;
	ushort	idx;
	uint	ring[2*Nev];
};

struct Vevent {
	ushort	type;
	ushort	code;
	uint	value;
};

struct Input {
	uint	*mmio;
	uintptr	pa;
	int	irq;
	int	n;		/* descriptors */
	Vdesc	*desc;
	Vavail	*avail;
	Vused	*used;
	Vevent	*ev;
	ushort	lastused;

	int	shift, ctl, caps, alt;
	int	buttons;
	int	dx, dy;		/* since the last report */
	int	absx, absy;
	int	absmax[2];	/* the most X and Y can be: the device says */
	int	isabs, moved;
};

#define RD(r)		(in->mmio[(r)>>2])
#define WR(r, v)	(in->mmio[(r)>>2] = (v), coherence())

static Input inputs[Maxinput];
static int ninput;

/* the key that repeats: the last one that went down and is still down */
static struct {
	Lock;
	Rune	r;
	int	code;
	Input	*in;
	ulong	at;		/* ms: when it is next typed */
} rep;

static void
repclock(void)
{
	Rune r;
	ulong now;

	if(rep.r == 0)
		return;
	now = TK2MS(sys->ticks);
	r = 0;
	ilock(&rep);
	if(rep.r != 0 && (long)(now - rep.at) >= 0){
		r = rep.r;
		rep.at = now + Reprate;
	}
	iunlock(&rep);
	if(r != 0)
		kbdputc(nil, r);
}

/* Linux's key codes of a US keyboard: plain, then with shift */
static Rune keyplain[128] = {
[1]	Kesc, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b',
[15]	'\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n',
[30]	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
[43]	'\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
[55]	'*',
[57]	' ',
[59]	KF|1, KF|2, KF|3, KF|4, KF|5, KF|6, KF|7, KF|8, KF|9, KF|10,
[71]	'7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.',
[87]	KF|11, KF|12,
[96]	'\n',
[98]	'/',
[102]	Khome, Kup, Kpgup, Kleft, Kright, Kend, Kdown, Kpgdown, Kins, Kdel,
};

static Rune keyshift[128] = {
[1]	Kesc, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '\b',
[15]	'\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n',
[30]	'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~',
[43]	'|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?',
[55]	'*',
[57]	' ',
[59]	KF|1, KF|2, KF|3, KF|4, KF|5, KF|6, KF|7, KF|8, KF|9, KF|10,
[71]	'7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.',
[87]	KF|11, KF|12,
[96]	'\n',
[98]	'/',
[102]	Khome, Kup, Kpgup, Kleft, Kright, Kend, Kdown, Kpgdown, Kins, Kdel,
};

static void
key(Input *in, int code, int down)
{
	Rune r;

	switch(code){
	case Keylshift:
	case Keyrshift:
		in->shift = down;
		return;
	case Keyctl:
	case Keyrctl:
		in->ctl = down;
		return;
	case Keyalt:
		in->alt = down;
		if(down)
			kbdputc(nil, Kalt);	/* starts a compose sequence */
		return;
	case Keycaps:
		if(down)
			in->caps = !in->caps;
		return;
	}
	if(!down){
		ilock(&rep);
		if(rep.in == in && rep.code == code)
			rep.r = 0;
		iunlock(&rep);
		return;
	}
	if(code < 0 || code >= nelem(keyplain))
		return;
	r = in->shift? keyshift[code]: keyplain[code];
	if(r == 0)
		return;
	if(in->caps && r >= 'a' && r <= 'z')
		r += 'A' - 'a';
	else if(in->caps && in->shift && r >= 'A' && r <= 'Z')
		r += 'a' - 'A';
	if(in->ctl && r >= '@' && r < 0x7f)
		r &= 0x1f;
	ilock(&rep);
	rep.r = r;
	rep.code = code;
	rep.in = in;
	rep.at = TK2MS(sys->ticks) + Repdelay;
	iunlock(&rep);
	kbdputc(nil, r);
}

static void
button(Input *in, int b, int down)
{
	if(down)
		in->buttons |= b;
	else
		in->buttons &= ~b;
	in->moved = 1;
}

static void
event(Input *in, Vevent *e)
{
	int msec;
	Point p;

	switch(e->type){
	case Evkey:
		switch(e->code){
		case Btnleft:
			button(in, 1, e->value);
			break;
		case Btnmiddle:
			button(in, 2, e->value);
			break;
		case Btnright:
			button(in, 4, e->value);
			break;
		case Btnwheelup:
			button(in, 8, e->value);
			break;
		case Btnwheeldown:
			button(in, 16, e->value);
			break;
		default:
			key(in, e->code, e->value != 0);
			break;
		}
		break;
	case Evrel:
		if(e->code == Relx)
			in->dx += (int)e->value;
		else if(e->code == Rely)
			in->dy += (int)e->value;
		in->moved = 1;
		break;
	case Evabs:
		if(e->code == Absx)
			in->absx = e->value;
		else if(e->code == Absy)
			in->absy = e->value;
		in->isabs = in->moved = 1;
		break;
	case Evsyn:
		if(!in->moved || !conf.monitor)
			break;
		msec = TK2MS(sys->ticks);
		if(in->isabs && gscreen != nil){
			/* a place on the screen: the pointer has to get there */
			p = mousexy();
			in->dx = in->absx * Dx(gscreen->r) / (in->absmax[0]+1) - p.x;
			in->dy = in->absy * Dy(gscreen->r) / (in->absmax[1]+1) - p.y;
		}
		mousetrack(in->dx, in->dy, in->buttons, msec);
		in->dx = in->dy = 0;
		in->moved = 0;
		break;
	}
}

static Intrsvcret
inputintr(Ureg*, void *arg)
{
	int id;
	uint st, *u;
	Input *in;

	in = arg;
	st = RD(Intstatus);
	if(st == 0)
		return Intrnotforme;
	WR(Intack, st);
	while(in->used->idx != in->lastused){
		u = &in->used->ring[2*(in->lastused & (in->n - 1))];
		id = u[0];
		in->lastused++;
		if(id < 0 || id >= in->n)
			continue;
		event(in, &in->ev[id]);
		/* the buffer goes back as it is */
		in->avail->ring[in->avail->idx & (in->n - 1)] = id;
		coherence();
		in->avail->idx++;
		coherence();
	}
	WR(Queuenotify, 0);
	return Intrforme;
}

/*
 * How far a pointer's axis goes: the configuration is asked (what is
 * wanted is written a byte at a time, the answer's size and the answer
 * are read). QEMU's tablet says 0x7fff, the Kakao SOC's pointer the
 * size of its picture less one.
 */
static int
absmax(Input *in, int axis)
{
	uchar *c;
	int i, max;

	c = (uchar*)in->mmio + Config;
	c[0] = Cfgabsinfo;
	coherence();
	c[1] = axis;
	coherence();
	if(c[2] < 8)
		return Absmax;
	max = 0;
	for(i = 3; i >= 0; i--)
		max = max<<8 | c[8+4+i];
	if(max <= 0)
		return Absmax;
	return max;
}

static int
inputinit(Input *in)
{
	int i, n;
	uint f1;

	WR(Status, 0);
	WR(Status, Sack);
	WR(Status, Sack|Sdriver);
	WR(Devfeatsel, 1);
	f1 = RD(Devfeat);
	if((f1 & Fversion1) == 0){
		WR(Status, Sfailed);
		return -1;
	}
	WR(Drvfeatsel, 0);
	WR(Drvfeat, 0);
	WR(Drvfeatsel, 1);
	WR(Drvfeat, Fversion1);
	WR(Status, Sack|Sdriver|Sfeatok);
	if((RD(Status) & Sfeatok) == 0){
		WR(Status, Sfailed);
		return -1;
	}

	in->absmax[0] = absmax(in, 0);
	in->absmax[1] = absmax(in, 1);

	WR(Queuesel, 0);			/* the event queue */
	n = RD(Queuenummax);
	if(n == 0)
		return -1;
	if(n > Nev)
		n = Nev;
	while(!ispow2(n))
		n &= n - 1;
	in->n = n;
	in->desc = mallocalign(n * sizeof(Vdesc), PGSZ, 0, 0);
	in->avail = mallocalign(sizeof(Vavail), PGSZ, 0, 0);
	in->used = mallocalign(sizeof(Vused), PGSZ, 0, 0);
	in->ev = mallocalign(n * sizeof(Vevent), PGSZ, 0, 0);
	if(in->desc == nil || in->avail == nil || in->used == nil || in->ev == nil)
		return -1;
	for(i = 0; i < n; i++){
		in->desc[i].addr = PADDR(&in->ev[i]);
		in->desc[i].len = sizeof(Vevent);
		in->desc[i].flags = Dwrite;
		in->avail->ring[i] = i;
	}
	in->avail->idx = n;
	coherence();
	WR(Queuenum, n);
	WR(Queuedesc, (uint)PADDR(in->desc));
	WR(Queuedesc+4, (uvlong)PADDR(in->desc) >> 32);
	WR(Queuedriver, (uint)PADDR(in->avail));
	WR(Queuedriver+4, (uvlong)PADDR(in->avail) >> 32);
	WR(Queuedevice, (uint)PADDR(in->used));
	WR(Queuedevice+4, (uvlong)PADDR(in->used) >> 32);
	WR(Queueready, 1);
	intrenable(in->irq, inputintr, in, BUSUNKNOWN, "input");
	WR(Status, RD(Status) | Sdriverok);
	WR(Queuenotify, 0);
	return 0;
}

void
kkinputlink(void)
{
	int i;
	uint *mmio;
	Input *in;
	Vslot *s;

	for(i = 0; i < nkkvslot && ninput < Maxinput; i++){
		s = &kkvslots[i];
		mmio = vmap(s->pa, PGSZ);
		if(mmio == nil)
			continue;
		if(mmio[Magic>>2] != Magicvirt || mmio[Version>>2] != 2 ||
		    mmio[Deviceid>>2] != Devinput){
			vunmap(mmio, PGSZ);
			continue;
		}
		in = &inputs[ninput];
		in->mmio = mmio;
		in->pa = s->pa;
		in->irq = s->irq;
		if(inputinit(in) < 0){
			print("input: %#p: not a device this driver can use\n", s->pa);
			in->mmio = nil;
			vunmap(mmio, PGSZ);
			continue;
		}
		print("input: virtio regs %#p irq %d", s->pa, s->irq);
		if(in->absmax[0] != Absmax || in->absmax[1] != Absmax)
			print(": a pointer to %d, %d", in->absmax[0], in->absmax[1]);
		print("\n");
		ninput++;
	}
	if(ninput > 0)
		addclock0link(repclock, Reptick);
}
