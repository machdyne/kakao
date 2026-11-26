/*
 * The device tree, as far as this port needs it: the timebase and the
 * virtio-mmio slots with their interrupts, how much memory there is, and
where a screen might be: a simple-framebuffer, or QEMU's fw_cfg.  QEMU's virt machine and the
 * Kakao SOC have the same devices at the same addresses, but the SOC's
 * clock counts at another rate and its virtio slots are on other PLIC
 * sources; both say so here.
 *
 * OpenSBI enters the kernel with the tree's physical address in a1,
 * which start.s keeps in bootfdtpa.  fdtconf is called from low(), with
 * paging off and before the kernel has allocated anything: it must not
 * print, allocate or keep pointers, and it reads the tree where it lies.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "kkfdt.h"

enum {
	Fdtmagic	= 0xd00dfeed,
	Beginnode	= 1,
	Endnode		= 2,
	Prop		= 3,
	Nop		= 4,
	End		= 9,

	Maxdepth	= 8,
	Maxfdt		= 1*MB,		/* sanity */
};

typedef struct Node Node;
struct Node {
	int	acells;		/* #address-cells, for the node's children */
	int	scells;		/* #size-cells, likewise */
	int	isvirtio;
	int	ismem;
	int	isfwcfg;
	int	isfb;
	uint	fbw, fbh, fbstride, fbdepth, fbctrl;
	uintptr	size;
	int	havereg;
	uintptr	reg;
	int	irq;
};

extern uintptr bootfdtpa;	/* start.s */

/*
 * These are set before bss is cleared, so all of them have initialisers,
 * which keeps them in the data segment.  The slots start out as QEMU's
 * virt machine has them, for want of a tree to say otherwise.
 */
Vslot	kkvslots[Maxvslot] = {
	0x10001000, 1,	0x10002000, 2,	0x10003000, 3,	0x10004000, 4,
	0x10005000, 5,	0x10006000, 6,	0x10007000, 7,	0x10008000, 8,
};
int	nkkvslot = Maxvslot;
int	kkfdtok = 0;
uintptr	kkfdtpa = 0;		/* where the tree was, to report */
uintptr	kkfwcfg = 0;		/* QEMU's fw_cfg, through which its ramfb is set up */
Kkfb	kkfb = { 0 };		/* a simple-framebuffer, if the tree has one */

static uint
be32(uchar *p)
{
	return p[0]<<24 | p[1]<<16 | p[2]<<8 | p[3];
}

static uvlong
becells(uchar *p, int cells)
{
	uvlong v;

	v = 0;
	while(cells-- > 0){
		v = v<<32 | be32(p);
		p += 4;
	}
	return v;
}

static int
streq(char *a, char *b)
{
	while(*a != 0 && *a == *b)
		a++, b++;
	return *a == *b;
}

/* is s one of the strings of the list at p? */
static int
inlist(uchar *p, int len, char *s)
{
	uchar *e;

	for(e = p + len; p < e; p++){
		if(streq((char*)p, s))
			return 1;
		while(p < e && *p != 0)
			p++;
	}
	return 0;
}

void
fdtconf(void)
{
	int depth, len, nvs;
	uint tok, size;
	uintptr memend;
	uchar *fdt, *p, *e, *strs, *val;
	char *name;
	Node nodes[Maxdepth], *n, *pn;

	fdt = (uchar*)bootfdtpa;
	if(fdt == nil || (bootfdtpa & 3) != 0 || bootfdtpa < PHYSMEM ||
	    be32(fdt) != Fdtmagic)
		return;
	size = be32(fdt + 4);
	if(size > Maxfdt)
		return;
	kkfdtpa = bootfdtpa;
	nvs = 0;
	memend = 0;
	p = fdt + be32(fdt + 8);		/* the structure block */
	e = fdt + size;
	strs = fdt + be32(fdt + 12);

	depth = 0;
	n = &nodes[0];
	n->acells = n->scells = 2;
	for(;;){
		if(p + 4 > e)
			break;
		tok = be32(p);
		p += 4;
		if(tok == Beginnode){
			while(p < e && *p != 0)		/* the node's name */
				p++;
			p = fdt + ROUNDUP(p + 1 - fdt, 4);
			if(++depth >= Maxdepth)
				break;
			n = &nodes[depth];
			n->acells = n->scells = 2;
			n->isvirtio = n->ismem = n->havereg = 0;
			n->isfwcfg = n->isfb = 0;
			n->fbw = n->fbh = n->fbstride = n->fbdepth = n->fbctrl = 0;
			n->reg = n->size = 0;
			n->irq = 0;
		}else if(tok == Endnode){
			if(n->isvirtio && n->havereg && nvs < Maxvslot){
				kkvslots[nvs].pa = n->reg;
				kkvslots[nvs].irq = n->irq;
				nvs++;
			}
			if(n->isfwcfg && n->havereg)
				kkfwcfg = n->reg;
			if(n->isfb && n->havereg && n->fbw != 0 && n->fbh != 0){
				kkfb.pa = n->reg;
				kkfb.width = n->fbw;
				kkfb.height = n->fbh;
				kkfb.stride = n->fbstride;
				kkfb.depth = n->fbdepth;
				kkfb.ctrl = n->fbctrl;
			}
			/* the bank the kernel is in */
			if(n->ismem && n->havereg && n->reg <= PHYSMEM &&
			    n->reg + n->size > PHYSMEM)
				memend = n->reg + n->size;
			if(--depth < 0)
				break;
			n = &nodes[depth];
		}else if(tok == Prop){
			if(p + 8 > e)
				break;
			len = be32(p);
			name = (char*)strs + be32(p + 4);
			val = p + 8;
			p = fdt + ROUNDUP(val + len - fdt, 4);
			if(p > e || depth < 1)
				continue;
			if(streq(name, "#address-cells") && len == 4)
				n->acells = be32(val);
			else if(streq(name, "#size-cells") && len == 4)
				n->scells = be32(val);
			else if(streq(name, "device_type")){
				if(streq((char*)val, "memory"))
					n->ismem = 1;
			}else if(streq(name, "compatible")){
				if(inlist(val, len, "virtio,mmio"))
					n->isvirtio = 1;
				if(inlist(val, len, "qemu,fw-cfg-mmio"))
					n->isfwcfg = 1;
				if(inlist(val, len, "simple-framebuffer"))
					n->isfb = 1;
			}else if(streq(name, "width") && len == 4)
				n->fbw = be32(val);
			else if(streq(name, "height") && len == 4)
				n->fbh = be32(val);
			else if(streq(name, "stride") && len == 4)
				n->fbstride = be32(val);
			else if(streq(name, "kakao,ctrl") && len == 4)
				n->fbctrl = be32(val);
			else if(streq(name, "format")){
				/* the two this kernel draws in */
				if(streq((char*)val, "r5g6b5"))
					n->fbdepth = 16;
				else if(streq((char*)val, "x8r8g8b8") ||
				    streq((char*)val, "a8r8g8b8"))
					n->fbdepth = 32;
			}else if(streq(name, "reg")){
				pn = &nodes[depth-1];
				if(len >= 4*pn->acells){
					n->reg = becells(val, pn->acells);
					n->havereg = 1;
				}
				if(len >= 4*(pn->acells + pn->scells))
					n->size = becells(val + 4*pn->acells,
						pn->scells);
			}else if(streq(name, "interrupts") && len >= 4)
				n->irq = be32(val);
			else if(streq(name, "timebase-frequency") &&
			    (len == 4 || len == 8) && becells(val, len/4) >= MHZ)
				timebase = becells(val, len/4);
		}else if(tok == Nop)
			continue;
		else				/* End, or not a tree */
			break;
	}
	if(nvs > 0)
		nkkvslot = nvs;
	/*
	 * Use the memory there is, but not past the tree if the firmware
	 * put it at the top: the kernel keeps Sys in the bank's last MB and
	 * clears it, and the firmware may want its tree again.
	 */
	if(memend != 0){
		if(bootfdtpa > PHYSMEM && bootfdtpa < memend &&
		    memend - bootfdtpa <= 4*MB)
			memend = bootfdtpa & ~(uintptr)(MB-1);
		if(memend >= PHYSMEM + 16*MB)
			membanks[0].size = memend - PHYSMEM;
	}
	kkfdtok = 1;
}
