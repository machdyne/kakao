/*
 * The screen of Kakao Plan 9: a framebuffer in memory with a cursor
 * drawn by software, and the kernel's messages on it until a window
 * system takes it.
 *
 * This is ../../9/bcm/screen.c (the Raspberry Pi's, Plan 9 Foundation,
 * MIT licence) with the Pi's framebuffer taken out and kkfbinit, below,
 * put in.  Where the pixels are comes from the device tree (kkfdt.c):
 * a simple-framebuffer node, or QEMU's ramfb, which is told through
 * fw_cfg which memory to show.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

#define	Image	IMAGE
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"
#include "kkfdt.h"

enum {
	Tabstop		= 4,
	Scroll		= 8,
	Wid		= 1024,
	Ht		= 768,
	Depth		= 16,
};

Cursor	arrow = {
	{ -1, -1 },
	{ 0xFF, 0xFF, 0x80, 0x01, 0x80, 0x02, 0x80, 0x0C,
	  0x80, 0x10, 0x80, 0x10, 0x80, 0x08, 0x80, 0x04,
	  0x80, 0x02, 0x80, 0x01, 0x80, 0x02, 0x8C, 0x04,
	  0x92, 0x08, 0x91, 0x10, 0xA0, 0xA0, 0xC0, 0x40,
	},
	{ 0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFC, 0x7F, 0xF0,
	  0x7F, 0xE0, 0x7F, 0xE0, 0x7F, 0xF0, 0x7F, 0xF8,
	  0x7F, 0xFC, 0x7F, 0xFE, 0x7F, 0xFC, 0x73, 0xF8,
	  0x61, 0xF0, 0x60, 0xE0, 0x40, 0x40, 0x00, 0x00,
	},
};

Memimage *gscreen;

static Memdata xgdata;

Rectangle physgscreenr;

/*static*/ Memimage xgscreen =
{
	{ 0, 0, Wid, Ht },	/* r */
	{ 0, 0, Wid, Ht },	/* clipr */
	Depth,			/* depth */
	3,			/* nchan */
	RGB16,			/* chan */
	nil,			/* cmap */
	&xgdata,		/* data */
	0,			/* zero */
	0, 			/* width in words of a single scan line */
	0,			/* layer */
	0,			/* flags */
};

static Memimage *conscol;
static Memimage *back;
static Memsubfont *memdefont;

static Lock screenlock;

static Point	curpos;
static int	h, w;
static Rectangle window;

static void myscreenputs(char *s, int n);
static void screenputc(char *buf);
static void screenwin(void);

/*
 * Software cursor. 
 */
static int	swvisible;	/* is the cursor visible? */
static int	swenabled;	/* is the cursor supposed to be on the screen? */
static Memimage *swback;	/* screen under cursor */
static Memimage *swimg;		/* cursor image */
static Memimage *swmask;	/* cursor mask */
static Memimage *swimg1;
static Memimage *swmask1;

static Point	swoffset;
static Rectangle swrect;	/* screen rectangle in swback */
static Point	swpt;		/* desired cursor location */
static Point	swvispt;	/* actual cursor location */
static int	swvers;		/* incremented each time cursor image changes */
static int	swvisvers;	/* the version on the screen */

/*
 * called with drawlock locked for us, most of the time.
 * kernel prints at inopportune times might mean we don't
 * hold the lock, but memimagedraw is now reentrant so
 * that should be okay: worst case we get cursor droppings.
 */
static void
swcursorhide(void)
{
	if(swvisible == 0)
		return;
	if(swback == nil)
		return;
	swvisible = 0;
	memimagedraw(gscreen, swrect, swback, ZP, memopaque, ZP, S);
	flushmemscreen(swrect);
}

static void
swcursoravoid(Rectangle r)
{
	if(swvisible && rectXrect(r, swrect))
		swcursorhide();
}

static void
swcursordraw(void)
{
	int dounlock;

	if(swvisible)
		return;
	if(swenabled == 0)
		return;
	if(swback == nil || swimg1 == nil || swmask1 == nil)
		return;
	dounlock = canqlock(&drawlock);
	swvispt = swpt;
	swvisvers = swvers;
	swrect = rectaddpt(Rect(0,0,16,16), swvispt);
	memimagedraw(swback, swback->r, gscreen, swpt, memopaque, ZP, S);
	memimagedraw(gscreen, swrect, swimg1, ZP, swmask1, ZP, SoverD);
	flushmemscreen(swrect);
	swvisible = 1;
	if(dounlock)
		qunlock(&drawlock);
}

int
cursoron(int dolock)
{
	int retry;

	if (dolock)
		lock(&cursor);
	if (canqlock(&drawlock)) {
		retry = 0;
		swcursorhide();
		swcursordraw();
		qunlock(&drawlock);
	} else
		retry = 1;
	if (dolock)
		unlock(&cursor);
	return retry;
}

void
cursoroff(int dolock)
{
	if (dolock)
		lock(&cursor);
	swcursorhide();
	if (dolock)
		unlock(&cursor);
}

static void
swload(Cursor *curs)
{
	uchar *ip, *mp;
	int i, j, set, clr;

	if(!swimg || !swmask || !swimg1 || !swmask1)
		return;
	/*
	 * Build cursor image and mask.
	 * Image is just the usual cursor image
	 * but mask is a transparent alpha mask.
	 * 
	 * The 16x16x8 memimages do not have
	 * padding at the end of their scan lines.
	 */
	ip = byteaddr(swimg, ZP);
	mp = byteaddr(swmask, ZP);
	for(i=0; i<32; i++){
		set = curs->set[i];
		clr = curs->clr[i];
		for(j=0x80; j; j>>=1){
			*ip++ = set&j ? 0x00 : 0xFF;
			*mp++ = (clr|set)&j ? 0xFF : 0x00;
		}
	}
	swoffset = curs->offset;
	swvers++;
	memimagedraw(swimg1,  swimg1->r,  swimg,  ZP, memopaque, ZP, S);
	memimagedraw(swmask1, swmask1->r, swmask, ZP, memopaque, ZP, S);
}

/* called from devmouse */
void
setcursor(Cursor* curs)
{
	cursoroff(0);
	swload(curs);
	cursoron(0);
}

static int
swmove(Point p)
{
	swpt = addpt(p, swoffset);
	return 0;
}

static void
swcursorclock(void)
{
	int x;

	if(!swenabled)
		return;
	swmove(mousexy());
	if(swvisible && eqpt(swpt, swvispt) && swvers==swvisvers)
		return;

	x = splhi();
	if(swenabled)
	if(!swvisible || !eqpt(swpt, swvispt) || swvers!=swvisvers)
	if(canqlock(&drawlock)){
		swcursorhide();
		swcursordraw();
		qunlock(&drawlock);
	}
	splx(x);
}

void
swcursorinit(void)
{
	static int init;

	if(!init){
		init = 1;
		addclock0link(swcursorclock, 10);
		swenabled = 1;
	}
	if(swback){
		freememimage(swback);
		freememimage(swmask);
		freememimage(swmask1);
		freememimage(swimg);
		freememimage(swimg1);
	}

	swback  = allocmemimage(Rect(0,0,32,32), gscreen->chan);
	swmask  = allocmemimage(Rect(0,0,16,16), GREY8);
	swmask1 = allocmemimage(Rect(0,0,16,16), GREY1);
	swimg   = allocmemimage(Rect(0,0,16,16), GREY8);
	swimg1  = allocmemimage(Rect(0,0,16,16), GREY1);
	if(swback==nil || swmask==nil || swmask1==nil || swimg==nil || swimg1 == nil){
		print("software cursor: allocmemimage fails\n");
		return;
	}

	memfillcolor(swmask, DOpaque);
	memfillcolor(swmask1, DOpaque);
	memfillcolor(swimg, DBlack);
	memfillcolor(swimg1, DBlack);
}

int
hwdraw(Memdrawparam *par)
{
	Memimage *dst, *src, *mask;

	if((dst=par->dst) == nil || dst->data == nil)
		return 0;
	if((src=par->src) == nil || src->data == nil)
		return 0;
	if((mask=par->mask) == nil || mask->data == nil)
		return 0;

	if(dst->data->bdata == xgdata.bdata)
		swcursoravoid(par->r);
	if(src->data->bdata == xgdata.bdata)
		swcursoravoid(par->sr);
	if(mask->data->bdata == xgdata.bdata)
		swcursoravoid(par->mr);


	return 0;
}

/*
 * QEMU's fw_cfg, as far as ramfb needs it ("docs/specs/fw_cfg" in QEMU):
 * a selector, a data register read a byte at a time, and a DMA register
 * given the address of a request.  Everything in it is big-endian.
 */
enum {
	Fwdata		= 0x00,
	Fwsel		= 0x08,
	Fwdma		= 0x10,

	Fwfiledir	= 0x19,
	Dmaerror	= 1<<0,
	Dmaselect	= 1<<3,
	Dmawrite	= 1<<4,

	Fbwidth		= 1024,		/* what is asked of ramfb */
	Fbheight	= 768,
	Fbdepth		= 32,
};

static uchar	*fwcfg;

static void
put32(uchar *p, ulong v)
{
	p[0] = v>>24;
	p[1] = v>>16;
	p[2] = v>>8;
	p[3] = v;
}

static void
put64(uchar *p, uvlong v)
{
	put32(p, v>>32);
	put32(p+4, v);
}

static void
fwsel(int sel)
{
	*(ushort*)(fwcfg+Fwsel) = (sel&0xff)<<8 | (sel>>8)&0xff;
	coherence();
}

static void
fwread(void *a, int n)
{
	uchar *p;

	for(p = a; n > 0; n--)
		*p++ = *(uchar*)(fwcfg+Fwdata);
}

/* the selector of a file, or -1 */
static int
fwfile(char *name)
{
	int i, n;
	uchar b[4], e[64];

	fwsel(Fwfiledir);
	fwread(b, 4);
	n = b[0]<<24 | b[1]<<16 | b[2]<<8 | b[3];
	if(n > 512)
		return -1;
	for(i = 0; i < n; i++){
		fwread(e, sizeof e);	/* size[4] select[2] reserved[2] name[56] */
		e[63] = 0;
		if(strcmp((char*)e+8, name) == 0)
			return e[4]<<8 | e[5];
	}
	return -1;
}

static int
fwwrite(int sel, void *a, int n)
{
	int i;
	static uchar dma[16];		/* control[4] length[4] address[8] */
	static uvlong addr[1];

	put32(dma, sel<<16 | Dmaselect | Dmawrite);
	put32(dma+4, n);
	put64(dma+8, PADDR(a));
	coherence();
	/* the register is written whole, the address big-endian in it */
	put64((uchar*)addr, PADDR(dma));
	*(uvlong*)(fwcfg+Fwdma) = *(uvlong*)addr;
	coherence();
	for(i = 0; i < 1000; i++){
		if((dma[0]|dma[1]|dma[2]|dma[3]) == 0)
			return 0;
		if(dma[3] & Dmaerror)
			break;
		microdelay(10);
	}
	return -1;
}

static uchar*
ramfbinit(int *wp, int *hp, int *dp)
{
	int sel;
	uchar *fb;
	static uchar cfg[28];	/* addr[8] fourcc[4] flags[4] width[4] height[4] stride[4] */

	fwcfg = vmap(kkfwcfg, PGSZ);
	if(fwcfg == nil)
		return nil;
	sel = fwfile("etc/ramfb");
	if(sel < 0)
		return nil;		/* QEMU without -device ramfb */
	fb = mallocalign(Fbwidth*Fbheight*(Fbdepth/8), PGSZ, 0, 0);
	if(fb == nil)
		return nil;
	put64(cfg, PADDR(fb));
	put32(cfg+8, 'X' | 'R'<<8 | '2'<<16 | '4'<<24);	/* x8r8g8b8 */
	put32(cfg+12, 0);
	put32(cfg+16, Fbwidth);
	put32(cfg+20, Fbheight);
	put32(cfg+24, Fbwidth*(Fbdepth/8));
	if(fwwrite(sel, cfg, sizeof cfg) < 0){
		print("screen: ramfb did not take its configuration\n");
		free(fb);
		return nil;
	}
	*wp = Fbwidth;
	*hp = Fbheight;
	*dp = Fbdepth;
	return fb;
}

/*
 * The Kakao SOC's framebuffer (soc/rtl/k_fb.v) is main memory that the
 * CPU's cache is kept out of, which makes every access to it one of the
 * memory's own: slow to draw in, and slower to read.  So the screen that
 * is drawn in is a copy in ordinary memory, and what has changed is
 * written to the real one by flushmemscreen, eight bytes at a store,
 * never read.  The SOC shows 16 bits a pixel, or 8 through a map of 256
 * colours: half the bytes to draw and half to write, and Plan 9's own
 * colours, so that is what is used; KKFBDEPTH=16 at compile time has
 * the other.
 */
enum {
	Fbdeep8	= 1<<0,		/* word 0 of the registers */
	Fbpal	= 0x400/4,	/* the colours: 0x00rrggbb */
};

#ifndef KKFBDEPTH
#define KKFBDEPTH 8
#endif

static uchar	*hardfb;	/* the SOC's; nil where the screen is drawn in directly */
static int	hardbpl;	/* bytes a line, both of them */
static u32int	*fbregs;

/*
 * A kernel address for a device's.  Below main memory vmap adds KZERO
 * and that is all.  From main memory up (a framebuffer in memory the
 * device tree keeps from the system) the kernel's own map of memory
 * has it already, in pages that reach past what it was told is there;
 * vmap would make a new mapping, and the page tables for that are
 * taken as they are while the kernel starts -- by now from under
 * malloc's feet: the clock's timer was the first thing lost.
 */
static void*
kkmap(uintptr pa, usize size)
{
	if(pa >= PHYSMEM)
		return KADDR(pa);
	return vmap(pa, size);
}

static uchar*
kakaofbinit(int *wp, int *hp, int *dp)
{
	int i, depth;
	uchar *fb, *soft;

	depth = KKFBDEPTH;
	fbregs = kkmap(kkfb.ctrl, PGSZ);
	fb = kkmap(kkfb.pa, kkfb.stride*kkfb.height);
	if(fbregs == nil || fb == nil)
		return nil;
	hardbpl = kkfb.width*(depth/8);
	if(hardbpl & 7)
		return nil;
	soft = malloc(hardbpl*kkfb.height);	/* (aligned for uvlongs) */
	if(soft == nil)
		return nil;
	memset(soft, 0, hardbpl*kkfb.height);
	if(depth == 8){
		for(i = 0; i < 256; i++)
			fbregs[Fbpal + i] = cmap2rgb(i);
		fbregs[0] = Fbdeep8;
	}else
		fbregs[0] = 0;
	hardfb = fb;
	*wp = kkfb.width;
	*hp = kkfb.height;
	*dp = depth;
	return soft;
}

/*
 * Where the pixels are: a simple-framebuffer of the device tree, in
 * memory the firmware set aside or in a device's; else QEMU's ramfb.
 */
static uchar*
kkfbinit(int *wp, int *hp, int *dp)
{
	uchar *fb;

	if(kkfb.pa != 0 && kkfb.ctrl != 0)
		return kakaofbinit(wp, hp, dp);
	if(kkfb.pa != 0){
		if(kkfb.depth == 0 || kkfb.stride != kkfb.width*(kkfb.depth/8) ||
		    (kkfb.stride & 3) != 0){
			print("screen: a framebuffer this kernel cannot draw in\n");
			return nil;
		}
		fb = kkmap(kkfb.pa, PGROUND(kkfb.stride*kkfb.height));
		if(fb == nil)
			return nil;
		*wp = kkfb.width;
		*hp = kkfb.height;
		*dp = kkfb.depth;
		return fb;
	}
	if(kkfwcfg != 0)
		return ramfbinit(wp, hp, dp);
	return nil;
}

void
screeninit(void)
{
	uchar *fb;
	ulong chan;

	fb = kkfbinit(&xgscreen.r.max.x, &xgscreen.r.max.y, &xgscreen.depth);
	if(fb == nil)
		return;			/* no screen: a machine with a console */
	xgscreen.clipr = xgscreen.r;
	switch(xgscreen.depth){
	default:
		print("unsupported screen depth %d\n", xgscreen.depth);
		xgscreen.depth = 16;
		/* fall through */
	case 8:
		chan = CMAP8;
		break;
	case 16:
		chan = RGB16;
		break;
	case 24:
		chan = BGR24;
		break;
	case 32:
		chan = XRGB32;
		break;
	}
	memsetchan(&xgscreen, chan);
	conf.monitor = 1;
	xgdata.bdata = fb;
	xgdata.ref = 1;
	gscreen = &xgscreen;
	gscreen->width = wordsperline(gscreen->r, gscreen->depth);

	memimageinit();
	memdefont = getmemdefont();
	screenwin();
	addconsdev(nil, myscreenputs, -1, 0);
	swcursorinit();
	print("screen: %dx%dx%d at %#p\n", Dx(xgscreen.r), Dy(xgscreen.r),
		xgscreen.depth, fb);
}

void
flushmemscreen(Rectangle r)
{
	int y, n, bpp;
	uvlong *s, *d, *e;

	if(hardfb == nil || !rectclip(&r, gscreen->r))
		return;
	bpp = gscreen->depth/8;
	r.min.x = r.min.x*bpp & ~7;
	r.max.x = (r.max.x*bpp + 7) & ~7;
	n = (r.max.x - r.min.x)/8;
	for(y = r.min.y; y < r.max.y; y++){
		s = (uvlong*)(gscreen->data->bdata + y*hardbpl + r.min.x);
		d = (uvlong*)(hardfb + y*hardbpl + r.min.x);
		for(e = s + n; s < e; )
			*d++ = *s++;
	}
}

uchar*
attachscreen(Rectangle *r, ulong *chan, int* d, int *width, int *softscreen)
{
	*r = gscreen->r;
	*d = gscreen->depth;
	*chan = gscreen->chan;
	*width = gscreen->width;
	*softscreen = hardfb != nil;

	return gscreen->data->bdata;
}

void
getcolor(ulong p, ulong *pr, ulong *pg, ulong *pb)
{
	ulong v;

	v = cmap2rgb(p & 0xff);
	*pr = (v>>16 & 0xff) * 0x01010101;
	*pg = (v>>8 & 0xff) * 0x01010101;
	*pb = (v & 0xff) * 0x01010101;
}

int
setcolor(ulong p, ulong r, ulong g, ulong b)
{
	USED(p, r, g, b);
	return 0;
}

void
blankscreen(int blank)
{
	USED(blank);
}

static void
myscreenputs(char *s, int n)
{
	int i;
	Rune r;
	char buf[4];

	if(!islo()) {
		/* don't deadlock trying to print in interrupt */
		if(!canlock(&screenlock))
			return;	
	}
	else
		lock(&screenlock);

	while(n > 0){
		i = chartorune(&r, s);
		if(i == 0){
			s++;
			--n;
			continue;
		}
		memmove(buf, s, i);
		buf[i] = 0;
		n -= i;
		s += i;
		screenputc(buf);
	}
	unlock(&screenlock);
}

static void
screenwin(void)
{
	char *greet;
	Memimage *orange;
	Point p, q;
	Rectangle r;

	back = memwhite;
	conscol = memblack;

	orange = allocmemimage(Rect(0, 0, 1, 1), RGB16);
	orange->flags |= Frepl;
	orange->clipr = gscreen->r;
	orange->data->bdata[0] = 0x40;		/* magic: colour? */
	orange->data->bdata[1] = 0xfd;		/* magic: colour? */

	w = memdefont->info[' '].width;
	h = memdefont->height;

	r = insetrect(gscreen->r, 4);

	memimagedraw(gscreen, r, memblack, ZP, memopaque, ZP, S);
	window = insetrect(r, 4);
	memimagedraw(gscreen, window, memwhite, ZP, memopaque, ZP, S);

	memimagedraw(gscreen, Rect(window.min.x, window.min.y,
		window.max.x, window.min.y + h + 5 + 6), orange, ZP, nil, ZP, S);
	freememimage(orange);
	window = insetrect(window, 5);

	greet = " Plan 9 Console ";
	p = addpt(window.min, Pt(10, 0));
	q = memsubfontwidth(memdefont, greet);
	memimagestring(gscreen, p, conscol, ZP, memdefont, greet);
	flushmemscreen(r);
	window.min.y += h + 6;
	curpos = window.min;
	window.max.y = window.min.y + ((window.max.y - window.min.y) / h) * h;
}

static void
scroll(void)
{
	int o;
	Point p;
	Rectangle r;

	o = Scroll*h;
	r = Rpt(window.min, Pt(window.max.x, window.max.y-o));
	p = Pt(window.min.x, window.min.y+o);
	memimagedraw(gscreen, r, gscreen, p, nil, p, S);
	flushmemscreen(r);
	r = Rpt(Pt(window.min.x, window.max.y-o), window.max);
	memimagedraw(gscreen, r, back, ZP, nil, ZP, S);
	flushmemscreen(r);

	curpos.y -= o;
}

static void
screenputc(char *buf)
{
	int w;
	uint pos;
	Point p;
	Rectangle r;
	static int *xp;
	static int xbuf[256];

	if (xp < xbuf || xp >= &xbuf[sizeof(xbuf)])
		xp = xbuf;

	switch (buf[0]) {
	case '\n':
		if (curpos.y + h >= window.max.y)
			scroll();
		curpos.y += h;
		screenputc("\r");
		break;
	case '\r':
		xp = xbuf;
		curpos.x = window.min.x;
		break;
	case '\t':
		p = memsubfontwidth(memdefont, " ");
		w = p.x;
		if (curpos.x >= window.max.x - Tabstop * w)
			screenputc("\n");

		pos = (curpos.x - window.min.x) / w;
		pos = Tabstop - pos % Tabstop;
		*xp++ = curpos.x;
		r = Rect(curpos.x, curpos.y, curpos.x + pos * w, curpos.y + h);
		memimagedraw(gscreen, r, back, back->r.min, nil, back->r.min, S);
		flushmemscreen(r);
		curpos.x += pos * w;
		break;
	case '\b':
		if (xp <= xbuf)
			break;
		xp--;
		r = Rect(*xp, curpos.y, curpos.x, curpos.y + h);
		memimagedraw(gscreen, r, back, back->r.min, nil, back->r.min, S);
		flushmemscreen(r);
		curpos.x = *xp;
		break;
	case '\0':
		break;
	default:
		p = memsubfontwidth(memdefont, buf);
		w = p.x;

		if (curpos.x >= window.max.x - w)
			screenputc("\n");

		*xp++ = curpos.x;
		r = Rect(curpos.x, curpos.y, curpos.x + w, curpos.y + h);
		memimagedraw(gscreen, r, back, back->r.min, nil, back->r.min, S);
		memimagestring(gscreen, curpos, conscol, ZP, memdefont, buf);
		flushmemscreen(r);
		curpos.x += w;
		break;
	}
}
