/*
 * The menus. A bar on the screen's top line with menus dropping from
 * it, a list beside a menu where there is a choice of many, and
 * windows in the middle for what is only to be read. They are drawn
 * on the text mode's overlay (rtl/k_text.v): a second screen of cells
 * over the terminal's, in its own colours, so the terminal goes on
 * underneath and nothing of it has to be put back.
 *
 * kbd.c opens and closes them (a Super key alone, or Scroll Lock) and
 * hands the keys here while they are open:
 *
 *   Left, Right   the next menu (in a list: back to the menu)
 *   Up, Down      move
 *   Enter, Space  choose, or change
 *   Esc           back, and out
 *
 * The settings last until the power goes: saving them comes later.
 */

#include "iop.h"
#include "term.h"
#include "usbh.h"
#include "zkbd.h"

#ifndef K_CPU
#define K_CPU "kakao32, RV32IMA"
#endif
#ifndef K_BOARD
#define K_BOARD "Kakao"
#endif
#ifndef K_CLOCK
#define K_CLOCK "48 MHz"
#endif
#ifndef K_MEMORY
#define K_MEMORY "512 MB"
#endif

#ifdef TERM_HOST				/* built for the host (make test): hud_test.c */
uint32_t h_ovl[30 * 80], h_pal[32];
#define OVL    h_ovl
#define PAL    h_pal
#else
#define OVL    ((volatile uint32_t *)0x10030000)
#define PAL    ((volatile uint32_t *)0x10020080)
#endif
#define COLS   80
#define ROWS   25				/* the overlay's: the picture's first 25 */

/*
 * The menus use five of the overlay's sixteen colours, and a theme is
 * what those five are: the panel (6), its text and lines (15), what is
 * set (14), and the chosen line's ground (7) and text (0). The first
 * theme is the one after power-on.
 */
#define A_TEXT   0x6f
#define A_VALUE  0x6e
#define A_SEL    0x70

static const char *const theme_name[] = { "Slate", "Cocoa", "Blue", "Paper", "Night", "Moss" };
#define NTHEME 6
static const uint32_t theme_rgb[NTHEME][5] = {
	/* panel     text      set       chosen    its text */
	{ 0x2b3440, 0xe8ecf0, 0x7fc8ff, 0xd0d6dc, 0x10141a },	/* Slate */
	{ 0xaa5500, 0xffffff, 0xffff55, 0xaaaaaa, 0x000000 },	/* Cocoa: the PC's brown */
	{ 0x0000aa, 0xffffff, 0xffff55, 0x00aaaa, 0x000000 },	/* Blue */
	{ 0xe8e4d8, 0x202020, 0x8a3c00, 0x303030, 0xffffff },	/* Paper */
	{ 0x000000, 0xd0d0d0, 0xffffff, 0xd0d0d0, 0x000000 },	/* Night */
	{ 0x1f3a2a, 0xe6efe6, 0xb8e07a, 0xcfe0cf, 0x0c1a10 },	/* Moss */
};

/* the font's boxes */
#define B_H   0xc4
#define B_V   0xb3
#define B_UL  0xda
#define B_UR  0xbf
#define B_LL  0xc0
#define B_LR  0xd9

static const char *const scheme_name[] = { "VGA", "Cocoa", "Paper", "Amber", "Green", "Grey" };
#define NSCHEME 6
/* by the PC's colour numbers: [0] blue, [1] green, [2] red, [3] bright */
static const uint32_t scheme_rgb[NSCHEME][16] = {
	{ 0x000000, 0x0000aa, 0x00aa00, 0x00aaaa, 0xaa0000, 0xaa00aa, 0xaa5500, 0xaaaaaa,
	  0x555555, 0x5555ff, 0x55ff55, 0x55ffff, 0xff5555, 0xff55ff, 0xffff55, 0xffffff },	/* VGA */
	{ 0x1b1109, 0x5f7fae, 0x8fa860, 0x6fa8a0, 0xc0563c, 0xa8708c, 0xc08a3c, 0xd9c7a8,
	  0x6b5644, 0x8fb0e0, 0xb8d080, 0x98d0c8, 0xe87858, 0xd098b8, 0xf0c060, 0xfff4dc },	/* Cocoa */
	{ 0xf4f1e8, 0x1f3fb0, 0x1f7a2f, 0x0f7f86, 0xb0241f, 0x8a2f8f, 0x8a5a00, 0x2a2a2a,
	  0x8a8a8a, 0x3355dd, 0x2f9a3f, 0x1f9aa0, 0xd83a30, 0xb040b8, 0xa87000, 0x000000 },	/* Paper */
	{ 0x000000, 0x4d3500, 0x8a5f00, 0x996900, 0x664600, 0x745000, 0x8b6000, 0xbf8400,
	  0x7f5800, 0x8d6100, 0xca8b00, 0xd89500, 0xa57200, 0xb37c00, 0xf0a600, 0xffb000 },	/* Amber */
	{ 0x000000, 0x134d18, 0x228a2b, 0x269930, 0x196620, 0x1d7424, 0x238b2b, 0x30bf3c,
	  0x207f28, 0x238d2c, 0x32ca3f, 0x36d844, 0x29a534, 0x2db338, 0x3cf04b, 0x40ff50 },	/* Green */
	{ 0x000000, 0x4d4d4d, 0x8a8a8a, 0x999999, 0x666666, 0x747474, 0x8b8b8b, 0xbfbfbf,
	  0x7f7f7f, 0x8d8d8d, 0xcacaca, 0xd8d8d8, 0xa5a5a5, 0xb3b3b3, 0xf0f0f0, 0xffffff },	/* Grey */
};

/* -- what there is to choose -- */

enum { M_SYSTEM, M_KEYBOARD, M_DISPLAY, M_HELP, NMENU };
static const char *const menu_name[NMENU] = { "System", "Keyboard", "Display", "Help" };

enum {
	I_INFO, I_RESET,
	I_LAYOUT, I_CAPS, I_ALT, I_BS, I_DELAY, I_RATE,
	I_COLOURS, I_THEME, I_CURSOR, I_BLINK,
	I_KEYS, I_ABOUT
};

static const struct {
	uint8_t menu, id;
	const char *label;
} items[] = {
	{ M_SYSTEM,   I_INFO,    "About this machine" },
	{ M_SYSTEM,   I_RESET,   "Reset..." },
	{ M_KEYBOARD, I_LAYOUT,  "Layout" },
	{ M_KEYBOARD, I_CAPS,    "Caps Lock is" },
	{ M_KEYBOARD, I_ALT,     "Alt sends" },
	{ M_KEYBOARD, I_BS,      "Backspace sends" },
	{ M_KEYBOARD, I_DELAY,   "Repeat after" },
	{ M_KEYBOARD, I_RATE,    "Repeat rate" },
	{ M_DISPLAY,  I_COLOURS, "Colours" },
	{ M_DISPLAY,  I_THEME,   "Menus" },
	{ M_DISPLAY,  I_CURSOR,  "Cursor" },
	{ M_DISPLAY,  I_BLINK,   "Cursor blinks" },
	{ M_HELP,     I_KEYS,    "Keys" },
	{ M_HELP,     I_ABOUT,   "About the terminal" },
};
#define NITEMS ((int)(sizeof items / sizeof items[0]))

/* repeat: ticks of 1/732 s */
static const uint8_t delay_ticks[3] = { 183, 255, 110 };
static const char *const delay_name[3] = { "250 ms", "350 ms", "150 ms" };
static const uint8_t rate_ticks[3] = { 24, 37, 73 };
static const char *const rate_name[3] = { "30 a second", "20 a second", "10 a second" };

static uint8_t scheme, theme, delay_i, rate_i;

/* -- where we are -- */

enum { CLOSED, MENU, LIST, WINDOW, ASK };
static uint8_t state;
static uint8_t menu;			/* the menu that is down */
static uint8_t sel;				/* the item in it, counted within the menu */
static uint8_t list_id;			/* LIST: the item whose choices are shown */
static uint8_t list_sel;
static uint8_t win_id;			/* WINDOW: which */
static uint32_t shown_sec;
static uint8_t note_on;			/* a note is on the top line (the menus closed) */
static uint32_t note_until;

/* -- drawing -- */

static int used;				/* rows of the overlay with something in them */

static void put(int r, int c, unsigned ch, unsigned attr)
{
	if (r >= 0 && r < ROWS && c >= 0 && c < COLS) {
		OVL[(r << 6) + (r << 4) + c] = attr << 8 | ch;
		if (r >= used) used = r + 1;
	}
}

static int text(int r, int c, const char *s, unsigned attr)
{
	while (*s) put(r, c++, (unsigned char)*s++, attr);
	return c;
}

static void fill(int r, int c, int w, unsigned attr)
{
	while (w-- > 0) put(r, c++, ' ', attr);
}

static void box(int r, int c, int h, int w)
{
	int i;
	for (i = 0; i < h; i++) fill(r + i, c, w, A_TEXT);
	for (i = 1; i < w - 1; i++) { put(r, c + i, B_H, A_TEXT); put(r + h - 1, c + i, B_H, A_TEXT); }
	for (i = 1; i < h - 1; i++) { put(r + i, c, B_V, A_TEXT); put(r + i, c + w - 1, B_V, A_TEXT); }
	put(r, c, B_UL, A_TEXT); put(r, c + w - 1, B_UR, A_TEXT);
	put(r + h - 1, c, B_LL, A_TEXT); put(r + h - 1, c + w - 1, B_LR, A_TEXT);
}

static int len(const char *s)
{
	int n = 0;
	while (s[n]) n++;
	return n;
}

static void clear(void)
{
	int r, c;
	for (r = 0; r < used; r++)
		for (c = 0; c < COLS; c++) OVL[(r << 6) + (r << 4) + c] = 0;
	used = 0;
}

/* a number, in decimal, at least two digits if pad: into s, its end back */
static char *num(char *s, unsigned n, int pad)
{
	char t[10];
	int i = 0;
	do { t[i++] = (char)('0' + n % 10); n /= 10; } while (n);
	if (pad && i < 2) t[i++] = '0';
	while (i) *s++ = t[--i];
	*s = 0;
	return s;
}

static uint32_t seconds(void)
{
	return now_ticks() / 732;
}

static void uptime(char *s)
{
	uint32_t t = seconds();
	s = num(s, t / 3600, 0); *s++ = ':';
	s = num(s, (t / 60) % 60, 1); *s++ = ':';
	num(s, t % 60, 1);
}

/* -- the settings -- */

static void set_scheme(int n)
{
	int i;
	scheme = (uint8_t)n;
	for (i = 0; i < 16; i++) PAL[i] = scheme_rgb[n][i];
}

static void set_theme(int n)
{
	static const uint8_t at[5] = { 6, 15, 14, 7, 0 };
	int i;
	theme = (uint8_t)n;
	for (i = 0; i < 5; i++) PAL[16 + at[i]] = theme_rgb[n][i];
}

static const char *value(int id)
{
	switch (id) {
	case I_LAYOUT:  return z_kbd_layout_info(kbd_layout)->name;
	case I_CAPS:    return kbd_caps_ctrl ? "Control" : "Caps Lock";
	case I_ALT:     return kbd_alt_esc ? "Esc, then the key" : "nothing";
	case I_BS:      return kbd_bs_del ? "DEL (^?)" : "BS (^H)";
	case I_DELAY:   return delay_name[delay_i];
	case I_RATE:    return rate_name[rate_i];
	case I_COLOURS: return scheme_name[scheme];
	case I_THEME:   return theme_name[theme];
	case I_CURSOR:  return term_cur_block ? "block" : "underline";
	case I_BLINK:   return term_cur_steady ? "no" : "yes";
	}
	return "";
}

/* Enter on an item of a menu */
static void choose(int id)
{
	switch (id) {
	case I_LAYOUT:  state = LIST; list_id = I_LAYOUT; list_sel = kbd_layout; break;
	case I_COLOURS: state = LIST; list_id = I_COLOURS; list_sel = scheme; break;
	case I_THEME:   state = LIST; list_id = I_THEME; list_sel = theme; break;
	case I_CAPS:    kbd_caps_ctrl = !kbd_caps_ctrl; break;
	case I_ALT:     kbd_alt_esc = !kbd_alt_esc; break;
	case I_BS:      kbd_bs_del = !kbd_bs_del; break;
	case I_DELAY:
		delay_i = delay_i == 2 ? 0 : delay_i + 1;
		kbd_rep_delay = delay_ticks[delay_i];
		break;
	case I_RATE:
		rate_i = rate_i == 2 ? 0 : rate_i + 1;
		kbd_rep_rate = rate_ticks[rate_i];
		break;
	case I_CURSOR:  term_cur_block = !term_cur_block; term_ctrl(); break;
	case I_BLINK:   term_cur_steady = !term_cur_steady; term_ctrl(); break;
	case I_INFO: case I_KEYS: case I_ABOUT:
		state = WINDOW; win_id = (uint8_t)id; break;
	case I_RESET:
		state = ASK; win_id = (uint8_t)id; break;
	}
}

static int list_count(void)
{
	return list_id == I_LAYOUT ? z_kbd_layout_count : list_id == I_THEME ? NTHEME : NSCHEME;
}

static const char *list_name(int i)
{
	return list_id == I_LAYOUT ? z_kbd_layout_info(i)->desc :
		list_id == I_THEME ? theme_name[i] : scheme_name[i];
}

static void list_take(int i)
{
	if (list_id == I_LAYOUT) kbd_layout = (uint8_t)i;
	else if (list_id == I_THEME) set_theme(i);
	else set_scheme(i);
}

/* -- the picture -- */

static int menu_col(int m)
{
	int i, c = 8;
	for (i = 0; i < m; i++) c += len(menu_name[i]) + 2;
	return c;
}

/* the items of the menu that is down: the n-th's index in items[], or -1 */
static int item_of(int n)
{
	int i;
	for (i = 0; i < NITEMS; i++)
		if (items[i].menu == menu && n-- == 0) return i;
	return -1;
}

static int item_count(void)
{
	int i, n = 0;
	for (i = 0; i < NITEMS; i++) n += (items[i].menu == menu);
	return n;
}

static void draw_status(void)
{
	char t[16];
	const char *l = z_kbd_layout_info(kbd_layout)->label;
	int c;

	uptime(t);
	c = COLS - 1 - len(t);
	fill(0, COLS - 24, 24, A_TEXT);
	text(0, c, t, A_VALUE);
	c = c - 2 - len(l);
	text(0, c, l, A_VALUE);
	if (term_count() > 1) {
		/* which terminal is shown, of how many */
		char n[8], *q = num(n, (unsigned)term_shown() + 1, 0);
		*q++ = '/'; num(q, (unsigned)term_count(), 0);
		text(0, c - 2 - len(n), n, A_VALUE);
	}
	shown_sec = seconds();
}

static void draw_bar(void)
{
	int m;
	fill(0, 0, COLS, A_TEXT);
	text(0, 1, "Kakao", A_VALUE);
	for (m = 0; m < NMENU; m++) {
		unsigned a = (m == menu) ? A_SEL : A_TEXT;
		int c = menu_col(m);
		put(0, c, ' ', a);
		c = text(0, c + 1, menu_name[m], a);
		put(0, c, ' ', a);
	}
	draw_status();
}

#define MENU_W 36

static void draw_menu(void)
{
	int n = item_count(), c0 = menu_col(menu), i;

	box(1, c0, n + 2, MENU_W);
	for (i = 0; i < n; i++) {
		int it = item_of(i);
		const char *v = value(items[it].id);
		int on = (i == sel);
		if (on) fill(2 + i, c0 + 1, MENU_W - 2, A_SEL);
		text(2 + i, c0 + 2, items[it].label, on ? A_SEL : A_TEXT);
		text(2 + i, c0 + MENU_W - 2 - len(v), v, on ? A_SEL : A_VALUE);
	}
}

static void draw_list(void)
{
	int n = list_count(), c0 = menu_col(menu) + MENU_W - 1, r0 = 2 + sel, i;
	int rows = n, first = 0, LIST_W = 0;

	/* as wide as its longest, beside the menu if it fits there */
	for (i = 0; i < n; i++)
		if (len(list_name(i)) > LIST_W) LIST_W = len(list_name(i));
	LIST_W += 6;
	if (LIST_W > COLS) LIST_W = COLS;
	if (c0 + LIST_W > COLS) c0 = COLS - LIST_W;
	if (rows > ROWS - 4) rows = ROWS - 4;
	if (r0 + rows + 2 > ROWS) r0 = ROWS - rows - 2;
	if (list_sel >= rows) first = list_sel - rows + 1;

	box(r0, c0, rows + 2, LIST_W);
	for (i = 0; i < rows; i++) {
		int k = first + i;
		int on = (k == list_sel);
		int cur = k == (list_id == I_LAYOUT ? kbd_layout : list_id == I_THEME ? theme : scheme);
		if (on) fill(r0 + 1 + i, c0 + 1, LIST_W - 2, A_SEL);
		if (cur) put(r0 + 1 + i, c0 + 2, '*', on ? A_SEL : A_VALUE);
		text(r0 + 1 + i, c0 + 4, list_name(k), on ? A_SEL : A_TEXT);
	}
}

/* a window in the middle: a title, and lines of a name and what it is */
static int w_row, w_col, w_mid;
static int up_row;				/* "About this machine": the row of its clock */

static void window(const char *title, int h, int w, int mid)
{
	int r = (ROWS - h) / 2, c = (COLS - w) / 2;
	const char *hint = " Esc: back ";
	box(r, c, h, w);
	put(r, c + 2, ' ', A_TEXT);
	put(r, text(r, c + 3, title, A_VALUE), ' ', A_TEXT);
	text(r + h - 1, c + w - 2 - len(hint), hint, A_TEXT);
	w_row = r + 2; w_col = c + 3; w_mid = mid;
}

static void line(const char *name, const char *what)
{
	text(w_row, w_col, name, A_TEXT);
	text(w_row, w_col + w_mid, what, A_VALUE);
	w_row++;
}

static void draw_window(void)
{
	char t[24];

	switch (win_id) {
	case I_INFO: {
		uint8_t typ[8];
		int n = z_usbh_status(typ, 8), hubs = 0, i;
		char *p;
		for (i = 0; i < n; i++) hubs += (typ[i] == Z_USBH_CLASS_HUB);
		window("About this machine", 16, 52, 14);
		line("Machine", K_BOARD);
		line("Processor", K_CPU);
		line("Clock", K_CLOCK);
		line("Memory", K_MEMORY);
		line("Screen", "80 by 30, 640 by 480");
		num(t, (unsigned)term_count(), 0);
		line("Terminals", t);
		w_row++;
		p = num(t, (unsigned)kbd_count(), 0);
		line("Keyboards", t);
		p = num(t, (unsigned)(n - hubs), 0);
		if (hubs) { *p++ = ','; *p++ = ' '; p = num(p, (unsigned)hubs, 0); *p++ = ' '; *p++ = 'h'; *p++ = 'u'; *p++ = 'b'; if (hubs > 1) *p++ = 's'; *p = 0; }
		line("USB devices", t);
		line("Layout", z_kbd_layout_info(kbd_layout)->desc);
		w_row++;
		uptime(t);
		up_row = w_row;
		line("Running for", t);
		break;
	}
	case I_KEYS:
		window("Keys", 22, 66, 29);
		line("Super (Windows key), alone", "these menus, and out of them");
		line("Scroll Lock", "the same");
		w_row++;
		line("Super with 1 to 9, or 0", "that terminal (0: the tenth)");
		line("Super with Left or Right", "the terminal before, the next");
		w_row++;
		line("Mouse, left button held", "select text");
		line("Super with C", "copy what is selected");
		line("Super with V", "type what was copied");
		w_row++;
		line("In the menus:", "");
		line("  Left, Right", "the next menu");
		line("  Up, Down", "move");
		line("  Enter, Space", "choose or change");
		line("  Esc", "back");
		w_row++;
		line("None of this is passed on to Linux.", "");
		break;
	case I_RESET:
		/* (asked first: Enter does it) */
		window("Reset the machine?", 9, 62, 14);
		line("Linux is not asked. What it has not yet written to the", "");
		line("disk is lost: better type \"reboot\" at a prompt.", "");
		w_row++;
		line("Enter", "reset now");
		break;
	case I_ABOUT:
		window("About the terminal", 12, 60, 14);
		line("Kakao's terminal: the I/O processor's program.", "");
		w_row++;
		line("Built", __DATE__);
		line("USB", "Zeitlos's host controller and driver");
		line("Layouts", "Zeitlos's, from xkeyboard-config");
		line("Font", "Zeitlos's 8 by 16");
		break;
	}
}

static void draw(void)
{
	clear();
	if (state == CLOSED) return;
	draw_bar();
	if (state == WINDOW || state == ASK) { draw_window(); return; }
	draw_menu();
	if (state == LIST) draw_list();
}

/* -- the keys -- */

int hud_active(void)
{
	return state != CLOSED;
}

void hud_toggle(void)
{
	if (state == CLOSED) {
		note_on = 0;
		state = MENU;
		term_ctrl_or = 0x10;			/* the overlay on */
	} else {
		state = CLOSED;
		term_ctrl_or = 0;
	}
	draw();
	term_ctrl();
}

void hud_key(uint32_t sym)
{
	int n;

	switch (state) {
	case MENU:
		n = item_count();
		if (sym == Z_KEY_LEFT) { menu = menu ? menu - 1 : NMENU - 1; sel = 0; }
		else if (sym == Z_KEY_RIGHT) { menu = menu == NMENU - 1 ? 0 : menu + 1; sel = 0; }
		else if (sym == Z_KEY_UP) sel = sel ? sel - 1 : (uint8_t)(n - 1);
		else if (sym == Z_KEY_DOWN) sel = sel == n - 1 ? 0 : sel + 1;
		else if (sym == 0x0d || sym == ' ') choose(items[item_of(sel)].id);
		else if (sym == 0x1b) { hud_toggle(); return; }
		else return;
		break;
	case LIST:
		n = list_count();
		if (sym == Z_KEY_UP) list_sel = list_sel ? list_sel - 1 : (uint8_t)(n - 1);
		else if (sym == Z_KEY_DOWN) list_sel = list_sel == n - 1 ? 0 : list_sel + 1;
		else if (sym == 0x0d || sym == ' ') { list_take(list_sel); state = MENU; }
		else if (sym == 0x1b || sym == Z_KEY_LEFT) state = MENU;
		else return;
		break;
	case WINDOW:
		if (sym == 0x1b || sym == 0x0d || sym == ' ') state = MENU;
		else return;
		break;
	case ASK:
		if (sym == 0x0d) {
#ifndef TERM_HOST
			*(volatile uint32_t *)0x20000014 = 0x52535421;	/* all of it, this too */
#endif
			state = CLOSED;
		}
		else if (sym == 0x1b) state = MENU;
		else return;
		break;
	default:
		return;
	}
	draw();
}

/* the clock in the bar, and in the window that shows it */
void hud_tick(void)
{
	if (state == CLOSED) {
		if (note_on && (int32_t)(now_ticks() - note_until) >= 0) {
			note_on = 0;
			clear();
			term_ctrl_or = 0;
			term_ctrl();
		}
		return;
	}
	if (seconds() == shown_sec) return;
	if (state == WINDOW && win_id == I_INFO) {
		/* only the clock's own cells: drawing it all again flickers */
		char t[16];
		uptime(t);
		text(up_row, w_col + w_mid, t, A_VALUE);
	}
	draw_status();
}

/*
 * A note at the right of the top line for a few seconds, the menus
 * closed: what is on the USB ports, whenever that changes. Without it
 * a keyboard that is not recognised could not be told from one that is
 * not seen at all -- there would be no key to open the menus with.
 */
static char *add(char *p, const char *s)
{
	while (*s) *p++ = *s++;
	*p = 0;
	return p;
}

static char *count(char *p, int n, const char *what, int *any)
{
	if (!n) return p;
	if (*any) p = add(p, ", ");
	*any = 1;
	p = num(p, (unsigned)n, 0);
	p = add(p, what);
	if (n > 1) p = add(p, "s");
	return p;
}

/* a line of text at the right of the top line, for a few seconds */
void hud_note(const char *t)
{
	int n = len(t);
	if (state != CLOSED) return;
	clear();
	fill(0, COLS - n - 2, n + 2, A_TEXT);
	text(0, COLS - n - 1, t, A_VALUE);
	note_on = 1;
	note_until = now_ticks() + 3 * 732;
	term_ctrl_or = 0x10;
	term_ctrl();
}

void hud_usb_note(int keyboards, int hubs, int others, int failed, int step, int status)
{
	char t[72], *p;
	int any = 0;

	p = add(t, "USB: ");
	p = count(p, keyboards, " keyboard", &any);
	p = count(p, hubs, " hub", &any);
	p = count(p, others, " other", &any);
	if (failed) {
		/* where the driver gave up (its E_ and Z_USBH_ST_ numbers) */
		p = count(p, failed, " not working", &any);
		p = add(p, " (step "); p = num(p, (unsigned)step, 0);
		p = add(p, ", "); p = num(p, (unsigned)status, 0); p = add(p, ")");
	}
	if (!any) p = add(p, "nothing");
	hud_note(t);
}

/* the terminal shown changed: say which, or redraw the bar's count */
void hud_term_note(void)
{
	char t[24], *p;
	if (state != CLOSED) { draw_status(); return; }
	p = add(t, "Terminal ");
	p = num(p, (unsigned)term_shown() + 1, 0);
	hud_note(t);
}

void hud_init(void)
{
	state = CLOSED;
	set_theme(0);
	used = ROWS;
	clear();
}
