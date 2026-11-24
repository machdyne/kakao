/*
 * The keyboard. Zeitlos's USB host controller keeps the last report of
 * up to two boot-protocol keyboards in its two "HID blocks" (the
 * driver in usbh.c sets that up when one is plugged in, behind a hub
 * or not): the modifiers and up to four keys held. Here those are
 * compared with what they were, and what changed becomes key presses;
 * a press becomes a character of the layout (Zeitlos's zkbd.c and its
 * tables) and that the bytes a terminal sends: UTF-8, and the escape
 * sequences Linux's console and xterm have for the named keys.
 *
 * Two keys never reach the host. Either Super (Windows) key, pressed
 * and let go alone, and Scroll Lock open and close the menus (hud.c):
 * neither has a byte to send on a terminal, so nothing on the host can
 * be waiting for them.
 */

#include "iop.h"
#include "term.h"
#include "usbh.h"
#include "usbh_hw.h"
#include "zkbd.h"

uint8_t kbd_layout;
uint8_t kbd_caps_ctrl;
uint8_t kbd_alt_esc = 1;
uint8_t kbd_bs_del = 1;
uint8_t kbd_rep_delay = 183;			/* 250 ms */
uint8_t kbd_rep_rate = 24;				/* 30 a second */

#define U_CAPS    0x39
#define U_SCROLL  0x47
#define U_NUM     0x53
#define U_LGUI    0xe3
#define U_RGUI    0xe7

static struct {
	uint8_t mods;
	uint8_t keys[4];
	uint8_t is_kbd;
	uint8_t is_mouse;
} blk[2];

static uint8_t locks;
static uint8_t caps_held;				/* Caps Lock, as a Control key, is down */
static uint8_t gui_alone;				/* a Super key went down and nothing since */
static uint8_t gui_down;				/* Super keys held */
static uint32_t dead;					/* a dead key waits for its letter */

static uint8_t rep_usage;				/* the key that repeats, 0: none */
static uint32_t rep_at;

int kbd_count(void)
{
	return blk[0].is_kbd + blk[1].is_kbd;
}

static uint8_t mods_now(void)
{
	uint8_t m = blk[0].mods | blk[1].mods;
	if (caps_held) m |= Z_KBD_MOD_LCTRL;
	return m;
}

static void put_utf8(uint32_t c)
{
	if (c < 0x80) host_put((unsigned char)c);
	else if (c < 0x800) {
		host_put((unsigned char)(0xc0 | (c >> 6)));
		host_put((unsigned char)(0x80 | (c & 0x3f)));
	} else {
		host_put((unsigned char)(0xe0 | (c >> 12)));
		host_put((unsigned char)(0x80 | ((c >> 6) & 0x3f)));
		host_put((unsigned char)(0x80 | (c & 0x3f)));
	}
}

static void put_str(const char *s)
{
	while (*s) host_put((unsigned char)*s++);
}

/* a named key, as xterm and Linux's console send it */
static void put_named(uint32_t k, uint8_t mods)
{
	static const char *const tilde[] = {
		"1", "4", "5", "6", "2", "3"		/* Home End PgUp PgDn Insert Delete */
	};
	static const char *const fkey[] = {
		"15", "17", "18", "19", "20", "21", "23", "24"	/* F5..F12 */
	};

	if (k >= Z_KEY_UP && k <= Z_KEY_RIGHT) {
		host_put(0x1b);
		host_put(term_appkeys() ? 'O' : '[');
		host_put("ABDC"[k - Z_KEY_UP]);
	} else if (k >= Z_KEY_HOME && k <= Z_KEY_DELETE) {
		host_put(0x1b); host_put('[');
		put_str(tilde[k - Z_KEY_HOME]);
		host_put('~');
	} else if (k >= Z_KEY_F1 && k <= Z_KEY_F4) {
		host_put(0x1b); host_put('O');
		host_put((unsigned char)('P' + (k - Z_KEY_F1)));
	} else if (k >= Z_KEY_F5 && k <= Z_KEY_F12) {
		host_put(0x1b); host_put('[');
		put_str(fkey[k - Z_KEY_F5]);
		host_put('~');
	}
	(void)mods;
}

/* a character or a named key on its way to the host */
static void emit(uint32_t sym, uint8_t mods, uint8_t usage)
{
	if (hud_active()) { hud_key(sym); return; }

	if (Z_KEY_IS_NAMED(sym)) { put_named(sym, mods); return; }

	if (mods & Z_KBD_MOD_CTRL) {
		/* what Control does to the rest of ASCII, as on any terminal */
		if (sym == ' ' || sym == '2' || sym == '@') sym = 0;
		else if (sym >= 0x40 && sym <= 0x5f) sym &= 0x1f;
		else if (sym >= 0x60 && sym <= 0x7e) sym &= 0x1f;
		else if (sym == '?' || sym == '8') sym = 0x7f;
		else if (sym >= '3' && sym <= '7') sym = 0x1b + (sym - '3');
		else if (sym == '/') sym = 0x1f;
	}
	if (usage == 0x2a && !kbd_bs_del) sym = 0x08;
	if (usage == 0x2b && (mods & Z_KBD_MOD_SHIFT)) { put_str("\033[Z"); return; }
	if (kbd_alt_esc && (mods & Z_KBD_MOD_ALT)) host_put(0x1b);
	put_utf8(sym);
}

/* a key went down (or repeats) */
static void press(uint8_t usage)
{
	uint8_t mo;
	uint32_t sym = z_kbd_translate(kbd_layout, usage, mods_now(), locks, &mo);

	if (sym == Z_KEY_NONE) return;

	if (Z_KEY_IS_DEAD(sym)) {
		if (dead == sym) {				/* twice: the accent itself */
			uint32_t sp = z_kbd_dead_spacing_of(sym);
			dead = 0;
			if (sp) emit(sp, 0, 0);
		} else
			dead = sym;
		return;
	}
	if (dead && !Z_KEY_IS_NAMED(sym) && sym >= 0x20) {
		uint32_t c = z_kbd_compose(dead, sym);
		uint32_t sp = z_kbd_dead_spacing_of(dead);
		dead = 0;
		if (c) { emit(c, 0, 0); return; }
		/* nothing to compose: the accent, then the key (a space: only it) */
		if (sp) emit(sp, 0, 0);
		if (sym == ' ') return;
	}
	dead = 0;
	emit(sym, mo, usage);
}

/* another terminal on the screen; the keys go where it goes */
static void show(int n)
{
	int c = term_count();
	if (n < 0) n = c - 1;
	if (n >= c) n = (n == c) ? 0 : -1;		/* past the last: round; no such one: nothing */
	if (n < 0 || n == term_shown()) return;
	rep_usage = 0;
	dead = 0;
	term_show(n);
	hud_term_note();
}

static void key_event(uint8_t usage, int down)
{
	if (usage == U_LGUI || usage == U_RGUI) {
		if (down) { gui_alone = 1; gui_down++; }
		else {
			if (gui_down) gui_down--;
			if (gui_alone) { gui_alone = 0; hud_toggle(); }
		}
		return;
	}
	if (down) gui_alone = 0;

	/* with Super held nothing is typed: a digit is a terminal (1 the
	   first, 0 the tenth), Left and Right the one before and the next,
	   C and V (where they are on a US keyboard) copy and paste, the
	   cursor and page keys move through what scrolled off the screen */
	if (gui_down && usage < 0xe0) {
		if (!down) return;
		if (usage >= 0x1e && usage <= 0x27) show(usage - 0x1e);
		else if (usage == 0x50) show(term_shown() - 1);
		else if (usage == 0x4f) show(term_shown() + 1 == term_count() ? 0 : term_shown() + 1);
		/* Up, Down, Page Up, Page Down: the scroll buffer */
		else if (usage == 0x52) term_scroll(1);
		else if (usage == 0x51) term_scroll(-1);
		else if (usage == 0x4b) term_scroll(25);
		else if (usage == 0x4e) term_scroll(-25);
		else if (usage == 0x06) mouse_copy();		/* C */
		else if (usage == 0x19) mouse_paste();		/* V */
		return;
	}

	if (usage == U_CAPS && kbd_caps_ctrl) { caps_held = (uint8_t)down; return; }
	if (usage >= 0xe0) return;			/* the other modifiers: only their bits */
	/* a key typed: back to the screen itself */
	if (down && term_scrolled()) term_scroll(0);

	if (!down) {
		if (rep_usage == usage) rep_usage = 0;
		return;
	}

	switch (usage) {
	case U_SCROLL:
		hud_toggle();
		return;
	case U_CAPS:
		locks ^= Z_KBD_LOCK_CAPS;
		z_usbh_kbd_leds(locks);
		return;
	case U_NUM:
		locks ^= Z_KBD_LOCK_NUM;
		z_usbh_kbd_leds(locks);
		return;
	}

	rep_usage = usage;
	rep_at = now_ticks() + kbd_rep_delay;
	press(usage);
}

static int held(const uint8_t *keys, uint8_t u)
{
	return keys[0] == u || keys[1] == u || keys[2] == u || keys[3] == u;
}

static void block(int b)
{
	uint32_t ia = b ? Z_USBH_HID1_INFO : Z_USBH_HID0_INFO;
	uint32_t ka = b ? Z_USBH_HID1_KEYS : Z_USBH_HID0_KEYS;
	uint32_t info, k;
	uint8_t mods, keys[4];
	int i;

	/* the report changes under us: the same twice */
	do {
		info = z_usbh_rd(ia);
		k = z_usbh_rd(ka);
	} while (z_usbh_rd(ia) != info || z_usbh_rd(ka) != k);

	/* a mouse: where the controller has its pointer, and its buttons */
	if (((info >> 24) & 3) == Z_USBH_TYP_MOUSE) {
		uint32_t cu = z_usbh_rd(b ? Z_USBH_HID1_CURSOR : Z_USBH_HID0_CURSOR);
		blk[b].is_mouse = 1;
		mouse_at((int)((cu & 0x3ff) | ((cu >> 18) & 0x400)), (int)((cu >> 10) & 0x3ff), (int)((cu >> 20) & 0xff));
	} else if (blk[b].is_mouse) {
		blk[b].is_mouse = 0;
		mouse_gone();
	}
	blk[b].is_kbd = (((info >> 24) & 3) == Z_USBH_TYP_KBD);
	if (!blk[b].is_kbd) { info = 0; k = 0; }	/* gone: all its keys up */
	mods = (uint8_t)info;
	keys[0] = (uint8_t)(k >> 24); keys[1] = (uint8_t)(k >> 16);
	keys[2] = (uint8_t)(k >> 8);  keys[3] = (uint8_t)k;

	/* too many keys at once: the keyboard says so in every slot */
	if (keys[0] == 1) return;

	for (i = 0; i < 8; i++)
		if ((mods ^ blk[b].mods) & (1u << i)) {
			blk[b].mods ^= (uint8_t)(1u << i);
			key_event((uint8_t)(0xe0 + i), (mods >> i) & 1);
		}
	for (i = 0; i < 4; i++) {
		uint8_t u = blk[b].keys[i];
		if (u > 3 && !held(keys, u)) key_event(u, 0);
	}
	for (i = 0; i < 4; i++) {
		uint8_t u = keys[i];
		if (u > 3 && !held(blk[b].keys, u)) key_event(u, 1);
	}
	for (i = 0; i < 4; i++) blk[b].keys[i] = keys[i];
}

void kbd_poll(void)
{
	block(0);
	block(1);

	if (rep_usage && (int32_t)(now_ticks() - rep_at) >= 0) {
		rep_at = now_ticks() + kbd_rep_rate;
		press(rep_usage);
	}
}

void kbd_init(void)
{
	locks = 0;
	z_usbh_kbd_leds(0);
}
