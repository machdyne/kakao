/*
 * The USB keyboard and mouse as two virtio input devices of the host's
 * ("Virtual I/O Device (VIRTIO) Version 1.1", 5.8), in the third and
 * fourth virtio slots: what Linux's virtio_input driver and Plan 9's
 * kkinput.c take. Built with INPUT.
 *
 * They are the host's while the graphics screen is chosen (Super with
 * 0; Super with another digit is a terminal again). Until then, and
 * while the menus are open, the keyboard types into a terminal and the
 * mouse selects text there, as without this. The Super keys and Scroll
 * Lock stay here always, and the host never sees them.
 *
 * A device sends events of eight bytes, type, code and value, as Linux
 * has them, each in a buffer of the driver's (queue 0), and takes the
 * same from the driver (queue 1: the keyboard's lights).
 *
 *   the keyboard   EV_KEY with Linux's key code, 1 down and 0 up, then
 *                  EV_SYN. No repeats: the host makes its own.
 *   the mouse      a pointer with a place, not a movement, since the
 *                  USB controller keeps the pointer's place itself:
 *                  EV_ABS X and Y in pixels of the picture, EV_KEY
 *                  BTN_LEFT, BTN_RIGHT and BTN_MIDDLE, then EV_SYN.
 *
 * The configuration is asked, not read: the driver writes what it
 * wants to know (select, subsel) and reads the answer's size and
 * bytes. The answers are made when asked.
 */

#include "iop.h"
#include "virtio.h"
#include "usbh.h"
#include "zkbd.h"

#define VIRTIO_ID_INPUT  18

#define EV_SYN  0
#define EV_KEY  1
#define EV_ABS  3
#define EV_LED  0x11
#define EV_REP  0x14

#define BTN_LEFT    0x110
#define BTN_RIGHT   0x111
#define BTN_MIDDLE  0x112

/* what the configuration is asked for */
#define CFG_ID_NAME    0x01
#define CFG_EV_BITS    0x11
#define CFG_ABS_INFO   0x12

/* the picture the pointer's place is in */
#ifndef K_FB_W
#define K_FB_W 640
#define K_FB_H 480
#endif

/*
 * A USB keyboard's usages (the keyboard page) as Linux's key codes: the
 * table of Linux's own USB keyboard driver, as far as a keyboard's
 * keys go. 0: not a key the host is told of.
 */
static const uint8_t keycode[0x68] = {
	  0,  0,  0,  0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38,
	 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,  2,  3,
	  4,  5,  6,  7,  8,  9, 10, 11, 28,  1, 14, 15, 57, 12, 13, 26,
	 27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64,
	 65, 66, 67, 68, 87, 88, 99,  0,119,110,102,104,111,107,109,106,
	105,108,103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71,
	 72, 73, 82, 83, 86,127,116,117,
};
/* ...and its modifiers, usages 0xe0 to 0xe7; the Super keys are ours */
static const uint8_t modcode[8] = { 29, 42, 56, 0, 97, 54, 100, 0 };

struct vinput {
	struct vdev dev;
	uint8_t  sel, subsel;
	uint8_t  is_mouse;
};

static struct vinput kbd_dev, mouse_dev;

/* the answer to what was asked last, and of which device: there is
   room for one (the I/O processor's memory is nearly full), and it is
   made again when the other device is read */
static uint8_t ans[36], ans_size;		/* (the longest: the pointer's buttons, 35 bytes) */
static struct vinput *ans_of;

static uint8_t gfx;				/* the graphics screen is chosen */
static uint8_t held[16];		/* key codes the host has been told are down (all below 128) */
static uint16_t m_x = 0xffff, m_y;
static uint8_t m_btn;

/* events on their way: a device's driver may have no buffer just now.
   Packed small, the I/O processor's memory being nearly full: whose it
   is, its type (five bits) and its code (ten), and a value that is a
   place in the picture at the most. */
#define EVQ 16
#define EV_MOUSE 0x8000
static struct { uint16_t tc, value; } evq[EVQ];
static uint8_t ev_in, ev_out;

static unsigned code_of(unsigned usage)
{
	if (usage >= 0xe0 && usage <= 0xe7) return modcode[usage - 0xe0];
	return usage < sizeof keycode ? keycode[usage] : 0;
}

static void put(int mouse, unsigned type, unsigned code, uint32_t value)
{
	uint8_t n = (uint8_t)((ev_in + 1) % EVQ);
	if (n == ev_out) return;		/* full: the host is not listening */
	evq[ev_in].tc = (uint16_t)(type << 10 | code | (mouse ? EV_MOUSE : 0));
	evq[ev_in].value = (uint16_t)value;
	ev_in = n;
}

/* ------------------------------------------------------------------
 * the configuration
 * ------------------------------------------------------------------ */

static void bit(unsigned n)
{
	ans[n >> 3] |= (uint8_t)(1u << (n & 7));
	if (ans_size < (n >> 3) + 1) ans_size = (uint8_t)((n >> 3) + 1);
}

static void str(const char *s)
{
	while (*s) ans[ans_size++] = (uint8_t)*s++;
}

static void answer(struct vinput *v)
{
	unsigned i;

	for (i = 0; i < sizeof ans; i++) ans[i] = 0;
	ans_size = 0;
	ans_of = v;
	switch (v->sel) {
	case CFG_ID_NAME:
		str(v->is_mouse ? "Kakao pointer" : "Kakao keyboard");
		break;
	/* (no serial number and no bus, vendor and product: a driver takes
	   those as none and zeros, and the I/O processor's memory is
	   nearly full) */
	case CFG_EV_BITS:
		if (v->is_mouse) {
			if (v->subsel == EV_KEY) { bit(BTN_LEFT); bit(BTN_RIGHT); bit(BTN_MIDDLE); }
			else if (v->subsel == EV_ABS) { bit(0); bit(1); }
		} else {
			if (v->subsel == EV_KEY) {
				for (i = 4; i < sizeof keycode; i++) if (keycode[i]) bit(keycode[i]);
				for (i = 0; i < 8; i++) if (modcode[i]) bit(modcode[i]);
			} else if (v->subsel == EV_LED) { bit(0); bit(1); bit(2); }
			else if (v->subsel == EV_REP) { bit(0); bit(1); }
		}
		break;
	case CFG_ABS_INFO:
		/* least, most, fuzz, flat, resolution */
		if (v->is_mouse && v->subsel < 2) {
			unsigned max = v->subsel ? K_FB_H - 1 : K_FB_W - 1;
			ans[4] = (uint8_t)max; ans[5] = (uint8_t)(max >> 8);
			ans_size = 20;
		}
		break;
	}
}

/* select, subsel, size, five bytes of nothing, then the answer */
static uint32_t cfg_read(struct vdev *d, uint32_t off)
{
	struct vinput *v = (struct vinput *)d;
	uint32_t w = 0;
	unsigned i, a;

	if (ans_of != v) answer(v);
	off &= ~3u;
	if (off == 0) return (uint32_t)v->sel | (uint32_t)v->subsel << 8 | (uint32_t)ans_size << 16;
	for (i = 0; i < 4; i++) {
		a = off + i;
		if (a >= 8 && a - 8 < sizeof ans) w |= (uint32_t)ans[a - 8] << (8 * i);
	}
	return w;
}

static void cfg_write(struct vdev *d, uint32_t off, uint32_t val, uint32_t lanes)
{
	struct vinput *v = (struct vinput *)d;

	if ((off & ~3u) != 0) return;
	if (lanes & 1) v->sel = (uint8_t)val;
	if (lanes & 2) v->subsel = (uint8_t)(val >> 8);
	answer(v);
}

static void dev_reset(struct vdev *d)
{
	struct vinput *v = (struct vinput *)d;
	v->sel = v->subsel = 0;
	ans_of = 0;
}

/* ------------------------------------------------------------------
 * what kbd.c tells us
 * ------------------------------------------------------------------ */

int vinput_active(void)
{
	return gfx;
}

/* a key went down or up; 1: it was the host's, and is not to be typed */
int vinput_key(unsigned usage, int down)
{
	unsigned c;

	if (!gfx) return 0;
	c = code_of(usage);
	if (!c) return 1;
	if (down) held[c >> 3] |= (uint8_t)(1u << (c & 7));
	else {
		if (!(held[c >> 3] & (1u << (c & 7)))) return 1;	/* it went down elsewhere */
		held[c >> 3] &= (uint8_t)~(1u << (c & 7));
	}
	put(0, EV_KEY, c, down ? 1 : 0);
	put(0, EV_SYN, 0, 0);
	return 1;
}

/* where the pointer is, in pixels, and the buttons (bit 0 the left,
   1 the right, 2 the middle, as a USB mouse has them) */
void vinput_mouse(int x, int y, int buttons)
{
	static const uint16_t btn[3] = { BTN_LEFT, BTN_RIGHT, BTN_MIDDLE };
	int i, any = 0;

	/* (the USB controller keeps the pointer within the picture) */
	if ((uint16_t)x != m_x) { m_x = (uint16_t)x; put(1, EV_ABS, 0, (uint32_t)x); any = 1; }
	if ((uint16_t)y != m_y) { m_y = (uint16_t)y; put(1, EV_ABS, 1, (uint32_t)y); any = 1; }
	for (i = 0; i < 3; i++)
		if ((buttons ^ m_btn) & (1 << i)) { put(1, EV_KEY, btn[i], (buttons >> i) & 1); any = 1; }
	m_btn = (uint8_t)(buttons & 7);
	if (any) put(1, EV_SYN, 0, 0);
}

/* the graphics screen is chosen, or a terminal again: what the host
   thinks is held down is let go */
void vinput_show(int on)
{
	unsigned c;

	if (on == gfx) return;
	if (!on) {
		for (c = 0; c < 128; c++)
			if (held[c >> 3] & (1u << (c & 7))) {
				held[c >> 3] &= (uint8_t)~(1u << (c & 7));
				put(0, EV_KEY, c, 0);
				put(0, EV_SYN, 0, 0);
			}
		if (m_btn) vinput_mouse(m_x, m_y, 0);
	}
	gfx = (uint8_t)on;
	/* the screen: the framebuffer, or the terminals (k_text.v's GRAPHICS;
	   without a framebuffer, FB=0, nothing changes) */
	*(volatile uint32_t *)0x10020020 = (uint32_t)on;
	if (on) { mouse_gone(); hud_note("Graphics"); }
}

/* ------------------------------------------------------------------
 * the queues
 * ------------------------------------------------------------------ */

static void lights(void)
{
	struct vq *q = &kbd_dev.dev.q[1];
	const struct vdesc *d;
	static uint8_t leds;
	int head;

	while ((head = vq_take(q)) >= 0) {
		d = vq_desc(q, (unsigned)head);
		if (d && d->len >= 8) {
			const volatile uint16_t *e = (const volatile uint16_t *)d->addr;
			/* Linux's lights, 0 Num, 1 Caps, 2 Scroll, are the keyboard's own bits */
			if (e[0] == EV_LED && e[1] < 3) {
				leds &= (uint8_t)~(1u << e[1]);
				if (e[2] | e[3]) leds |= (uint8_t)(1u << e[1]);
				z_usbh_kbd_leds(leds);
			}
		}
		vq_done(&kbd_dev.dev, q, (unsigned)head, 0);
	}
}

void vinput_poll(void)
{
	struct vinput *v;
	const struct vdesc *d;
	int head;

	/* (the pointer's status queue is never looked at: it has no lights) */
	if (kbd_dev.dev.status & 4) lights();

	while (ev_out != ev_in) {
		v = (evq[ev_out].tc & EV_MOUSE) ? &mouse_dev : &kbd_dev;
		if (v->dev.status & 4) {
			head = vq_take(&v->dev.q[0]);
			if (head < 0) return;			/* no buffer: it waits */
			d = vq_desc(&v->dev.q[0], (unsigned)head);
			if (d && (d->flags & VD_WRITE) && d->len >= 8) {
				volatile uint16_t *e = (volatile uint16_t *)d->addr;
				e[0] = (evq[ev_out].tc >> 10) & 31;
				e[1] = evq[ev_out].tc & 0x3ff;
				*(volatile uint32_t *)(d->addr + 4) = evq[ev_out].value;
				vq_done(&v->dev, &v->dev.q[0], (unsigned)head, 8);
			} else
				vq_done(&v->dev, &v->dev.q[0], (unsigned)head, 0);
		}
		/* (a device nobody drives: its events are dropped) */
		ev_out = (uint8_t)((ev_out + 1) % EVQ);
	}
}

static void one(struct vinput *v, int slot, int is_mouse)
{
	v->is_mouse = (uint8_t)is_mouse;
	v->dev.id = VIRTIO_ID_INPUT;
	v->dev.feat = 0;
	v->dev.nq = 2;
	v->dev.qmax = 64;
	v->dev.cfg_read = cfg_read;
	v->dev.cfg_write = cfg_write;
	v->dev.reset = dev_reset;
	virtio_add(&v->dev, slot);
}

void vinput_init(void)
{
	one(&kbd_dev, 2, 0);
	one(&mouse_dev, 3, 1);
}
