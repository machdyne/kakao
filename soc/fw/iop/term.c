/*
 * The terminal: the I/O processor's program (rtl/k_iop.v). Characters
 * from the host's console are drawn into the text mode (rtl/k_text.v)
 * as a VT100 would, as far as Linux's console and the usual programs
 * on it need: the cursor's moves, erasing, scrolling (also within a
 * region), inserting and deleting, colours, the line-drawing set and
 * UTF-8's boxes, and the reports a shell asks for.
 *
 * It is also built for the host (make test), where term_test.c feeds it
 * and prints the screen: so everything that touches the hardware goes
 * through the few functions at the top.
 *
 * No multiply, no divide (RV32I), no library.
 */

#include "term.h"

#define COLS 80
#define ROWS 30

#define TERMS_MAX 10
#define HIST_MAX 3			/* screens of scroll buffer the first terminal can have */
#define SCREEN (ROWS * COLS)	/* a terminal's cells */

#ifdef TERM_HOST
uint32_t t_cells[(TERMS_MAX + HIST_MAX) * SCREEN];
uint32_t t_regs[8];
#define CELLS t_cells
#define REGS  t_regs
#else
#define CELLS ((volatile uint32_t *)0x10000000)
#define REGS  ((volatile uint32_t *)0x10020000)
#endif
#define R_CTRL   0
#define R_CURSOR 1
#define R_START  2
#define R_BASE   4
#define R_END    5

enum { S_TEXT, S_ESC, S_CSI, S_OSC, S_OSC_ESC, S_SET };
#define NPAR 8

/* a terminal: there are as many as the machine has consoles, each with
   its own screen of cells (rtl/k_text.v); one of them is shown */
struct term {
	unsigned base;				/* its first cell */
	unsigned top;				/* the ring's row at the top of the screen */
	unsigned rows;				/* the ring's rows: ROWS, or more with a scroll buffer */
	unsigned hist;				/* rows above the screen that hold what scrolled off */
	unsigned back;				/* rows the picture is scrolled back by (0: the screen) */
	int cx, cy;					/* the cursor; cx == COLS: about to wrap */
	int sv_x, sv_y;
	unsigned char sv_fg, sv_bg, sv_bold, sv_rev, sv_gfx;
	int r_top, r_bot;			/* the scrolling region, inclusive */
	unsigned char fg, bg, bold, rev;
	unsigned attr;				/* what those make: a cell's bits 15..8 */
	unsigned blank;				/* an erased cell: a space in the colours alone */
	unsigned char gfx;			/* the line-drawing set is selected */
	unsigned char cur_on, wrap_on;
	unsigned char appkeys;		/* the cursor keys send ESC O, not ESC [ */
	unsigned char brackets;		/* pasted text goes between ESC [ 200 ~ and ESC [ 201 ~ */
	unsigned char st;
	unsigned char priv;			/* '?' or '>' after the CSI */
	unsigned short par[NPAR];
	unsigned char npar;
	unsigned char u_left;		/* UTF-8: bytes still to come */
	unsigned u_code;
};

static struct term terms[TERMS_MAX];
static struct term *T = &terms[0];		/* the one characters are for */
static unsigned char cur, shown, count = 1;

unsigned char term_cur_block, term_cur_steady;	/* the cursor's look */
unsigned term_ctrl_or;			/* the overlay's bits of CTRL (hud.c) */

/* the text mode's CTRL: the terminal shown has the cursor */
void term_ctrl(void)
{
	REGS[R_CTRL] = 1 | (terms[shown].cur_on ? 2 : 0) | (term_cur_steady ? 0 : 4) |
		(term_cur_block ? 8 : 0) | term_ctrl_or;
}

/* (the code below was written for one terminal: its names are T's) */
#define top     (T->top)
#define cx      (T->cx)
#define cy      (T->cy)
#define sv_x    (T->sv_x)
#define sv_y    (T->sv_y)
#define sv_fg   (T->sv_fg)
#define sv_bg   (T->sv_bg)
#define sv_bold (T->sv_bold)
#define sv_rev  (T->sv_rev)
#define sv_gfx  (T->sv_gfx)
#define r_top   (T->r_top)
#define r_bot   (T->r_bot)
#define fg      (T->fg)
#define bg      (T->bg)
#define bold    (T->bold)
#define rev     (T->rev)
#define attr    (T->attr)
#define blank   (T->blank)
#define gfx     (T->gfx)
#define cur_on  (T->cur_on)
#define wrap_on (T->wrap_on)
#define st      (T->st)
#define priv    (T->priv)
#define par     (T->par)
#define npar    (T->npar)
#define u_left  (T->u_left)
#define u_code  (T->u_code)

/* ANSI's colour numbers as the text mode's (blue, green, red) */
static const unsigned char pc_col[8] = { 0, 4, 2, 6, 1, 5, 3, 7 };

/* the cell at a row and column of T's screen: its rows are a ring of
   ROWS, 80 cells each, from top on */
static unsigned cell_of(int r, int c)
{
	/* (r may be above the screen, down to -hist: the scroll buffer) */
	unsigned t = top + T->rows + (unsigned)r;
	while (t >= T->rows) t -= T->rows;
	return T->base + (t << 6) + (t << 4) + (unsigned)c;
}
#define CELL(r, c) CELLS[cell_of(r, c)]

static void set_attr(void)
{
	unsigned f = pc_col[fg & 7] | ((fg & 8) || bold ? 8 : 0);
	unsigned b = pc_col[bg & 7] | (bg & 8);
	attr = rev ? ((f & 7) << 4 | b) : (b << 4 | f);
	/* as Linux's own console erases: the colours, not bold or reverse */
	blank = (b << 4 | pc_col[fg & 7] | (fg & 8)) << 8 | ' ';
}

/* where the picture starts, when T is the terminal shown */
static void show_start(void)
{
	if (cur == shown) REGS[R_START] = cell_of(-(int)T->back, 0);
}

static void show_cursor(void)
{
	if (cur == shown) REGS[R_CURSOR] = cell_of(cy, cx < COLS ? cx : COLS - 1);
}

/* cells c0..c1 of a row become spaces in the background's colour */
static void erase(int r, int c0, int c1)
{
	unsigned v = blank;
	for (; c0 <= c1; c0++) CELL(r, c0) = v;
}

static void copy_row(int dst, int src)
{
	int c;
	for (c = 0; c < COLS; c++) CELL(dst, c) = CELL(src, c);
}

/* the region moves up a row; a new empty one at its bottom */
static void scroll_up(void)
{
	int r;
	if (r_top == 0 && r_bot == ROWS - 1) {
		/* the whole screen: turn the ring */
		top = top == T->rows - 1 ? 0 : top + 1;
		/* what went off the top is kept, as far as the ring has room;
		   a picture that is scrolled back stays on the rows it shows */
		if (T->hist < T->rows - ROWS) T->hist++;
		if (T->back && T->back < T->hist) T->back++;
		erase(ROWS - 1, 0, COLS - 1);
		show_start();
	} else {
		for (r = r_top; r < r_bot; r++) copy_row(r, r + 1);
		erase(r_bot, 0, COLS - 1);
	}
}

static void scroll_down(void)
{
	int r;
	if (r_top == 0 && r_bot == ROWS - 1) {
		top = top ? top - 1 : T->rows - 1;
		if (T->hist) T->hist--;
		if (T->back > T->hist) T->back = T->hist;
		erase(0, 0, COLS - 1);
		show_start();
	} else {
		for (r = r_bot; r > r_top; r--) copy_row(r, r - 1);
		erase(r_top, 0, COLS - 1);
	}
}

/* rows from..r_bot move down (n > 0) or up by one, within the region */
static void insert_line(int from)
{
	int r;
	for (r = r_bot; r > from; r--) copy_row(r, r - 1);
	erase(from, 0, COLS - 1);
}

static void delete_line(int from)
{
	int r;
	for (r = from; r < r_bot; r++) copy_row(r, r + 1);
	erase(r_bot, 0, COLS - 1);
}

static void save(void)
{
	sv_x = cx < COLS ? cx : COLS - 1; sv_y = cy;
	sv_fg = fg; sv_bg = bg; sv_bold = bold; sv_rev = rev; sv_gfx = gfx;
}

static void restore(void)
{
	cx = sv_x; cy = sv_y;
	fg = sv_fg; bg = sv_bg; bold = sv_bold; rev = sv_rev; gfx = sv_gfx;
	set_attr();
}

/* (any move of the cursor takes it off the edge it was about to wrap at) */
static void line_feed(void)
{
	if (cx >= COLS) cx = COLS - 1;
	if (cy == r_bot) scroll_up();
	else if (cy < ROWS - 1) cy++;
}

static void reverse_feed(void)
{
	if (cx >= COLS) cx = COLS - 1;
	if (cy == r_top) scroll_down();
	else if (cy > 0) cy--;
}

static void clamp(void)
{
	if (cx < 0) cx = 0;
	if (cx > COLS - 1) cx = COLS - 1;
	if (cy < 0) cy = 0;
	if (cy > ROWS - 1) cy = ROWS - 1;
}

static void reset(void)
{
	int r;
	top = 0; cx = 0; cy = 0;
	T->hist = 0; T->back = 0;
	r_top = 0; r_bot = ROWS - 1;
	fg = 7; bg = 0; bold = 0; rev = 0; gfx = 0;
	cur_on = 1; wrap_on = 1;
	st = S_TEXT; u_left = 0;
	set_attr();
	save();
	for (r = 0; r < ROWS; r++) erase(r, 0, COLS - 1);
	T->appkeys = 0;
	T->brackets = 0;
	show_start();
	if (cur == shown) term_ctrl();		/* on, the cursor shown */
}

static void draw(unsigned ch)
{
	if (cx >= COLS) {
		if (wrap_on) { cx = 0; line_feed(); }
		else cx = COLS - 1;
	}
	CELL(cy, cx) = attr << 8 | ch;
	cx++;
}

/* -- characters that are not ASCII -- */

static const unsigned char dec_gfx[] = {	/* from '`' */
	0x7f, 0xb1, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f,	/* ` a b c d e f g */
	0x7f, 0x7f, 0xd9, 0xbf, 0xda, 0xc0, 0xc5, 0xc4,	/* h i j k l m n o */
	0xc4, 0xc4, 0xc4, 0xc4, 0xc3, 0xb4, 0xc1, 0xc2,	/* p q r s t u v w */
	0xb3, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f		/* x y z { | } ~ */
};

static unsigned from_unicode(unsigned u)
{
	/* Latin-1 is in the font where the boxes leave room, and the euro
	   sign: tools/mkfont.py's slot() */
	if (u >= 0xa0 && u <= 0xff)
		return u < 0xd0 ? u - 0x20 : u < 0xf0 ? u + 0x10 : u - 0xe0;
	if (u == 0x20ac) return 0x01;
	if (u >= 0x2500 && u < 0x2580) {
		/* the boxes: light and heavy and double lines all as one */
		switch (u) {
		case 0x2500: case 0x2501: case 0x2550: return 0xc4;
		case 0x2502: case 0x2503: case 0x2551: return 0xb3;
		case 0x250c: case 0x250f: case 0x2554: case 0x256d: return 0xda;
		case 0x2510: case 0x2513: case 0x2557: case 0x256e: return 0xbf;
		case 0x2514: case 0x2517: case 0x255a: case 0x2570: return 0xc0;
		case 0x2518: case 0x251b: case 0x255d: case 0x256f: return 0xd9;
		case 0x251c: case 0x2523: case 0x2560: return 0xc3;
		case 0x2524: case 0x252b: case 0x2563: return 0xb4;
		case 0x252c: case 0x2533: case 0x2566: return 0xc2;
		case 0x2534: case 0x253b: case 0x2569: return 0xc1;
		case 0x253c: case 0x254b: case 0x256c: return 0xc5;
		}
		return 0x7f;
	}
	switch (u) {
	case 0x2588: return 0xdb;
	case 0x2584: return 0xdc;
	case 0x2580: return 0xdf;
	case 0x258c: return 0xdd;
	case 0x2590: return 0xde;
	case 0x2591: return 0xb0;
	case 0x2592: return 0xb1;
	case 0x2593: return 0xb2;
	case 0x2018: case 0x2019: return '\'';
	case 0x201c: case 0x201d: return '"';
	case 0x2013: case 0x2014: return '-';
	case 0x2022: return '*';
	}
	return 0x7f;
}

/* -- answers to the host -- */

static void reply(const char *s)
{
	while (*s) term_send((unsigned char)*s++);
}

static void reply_num(unsigned n)
{
	char b[6];
	int i = 0;
	unsigned d;
	/* (no divide) */
	for (d = 0; n >= 100; n -= 100) d++;
	if (d) b[i++] = '0' + (d > 9 ? 9 : d);
	{
		unsigned t;
		for (t = 0; n >= 10; n -= 10) t++;
		if (d || t) b[i++] = '0' + t;
	}
	b[i++] = '0' + n;
	b[i] = 0;
	reply(b);
}

/* -- the sequences -- */

static void sgr(void)
{
	int i;
	if (npar == 0) { par[0] = 0; npar = 1; }
	for (i = 0; i < npar; i++) {
		unsigned p = par[i];
		if (p == 0) { fg = 7; bg = 0; bold = 0; rev = 0; }
		else if (p == 1) bold = 1;
		else if (p == 2 || p == 22) bold = 0;
		else if (p == 7) rev = 1;
		else if (p == 27) rev = 0;
		else if (p >= 30 && p <= 37) fg = p - 30;
		else if (p == 39) fg = 7;
		else if (p >= 40 && p <= 47) bg = p - 40;
		else if (p == 49) bg = 0;
		else if (p >= 90 && p <= 97) fg = (p - 90) | 8;
		else if (p >= 100 && p <= 107) bg = (p - 100) | 8;
		else if (p == 38 || p == 48) {
			/* 38;5;n and 38;2;r;g;b: the first sixteen as they are,
			   the rest as white or black */
			unsigned c = 7;
			if (i + 2 < npar && par[i + 1] == 5) {
				c = par[i + 2];
				c = (c < 16) ? c : (c >= 232 && c < 244) ? 0 : 7;
				i += 2;
			} else if (i + 1 < npar && par[i + 1] == 2) {
				i += 4;
			}
			if (p == 38) fg = c; else bg = c;
		}
	}
	set_attr();
}

static void csi(unsigned char f)
{
	int n = par[0] ? par[0] : 1;		/* most take "0 means 1" */
	int i;

	if (priv == '?') {
		if (f == 'h' || f == 'l') {
			int on = (f == 'h');
			for (i = 0; i < npar; i++) {
				if (par[i] == 25) cur_on = on;
				else if (par[i] == 1) T->appkeys = on;
				else if (par[i] == 2004) T->brackets = on;
				else if (par[i] == 7) wrap_on = on;
				else if (par[i] == 1049 || par[i] == 1047 || par[i] == 47) {
					/* the other screen: there is none, so a clean one */
					int r;
					for (r = 0; r < ROWS; r++) erase(r, 0, COLS - 1);
					cx = 0; cy = 0;
				}
			}
			if (cur == shown) term_ctrl();
		}
		return;
	}
	if (priv) {
		if (priv == '>' && f == 'c') reply("\033[>0;10;0c");
		return;
	}

	switch (f) {
	/* up and down stop at the region's edge, coming from inside it */
	case 'A': case 'F':
		i = (cy >= r_top) ? r_top : 0;
		cy = (cy - n < i) ? i : cy - n;
		if (f == 'F') cx = 0;
		clamp();
		break;
	case 'B': case 'e': case 'E':
		i = (cy <= r_bot) ? r_bot : ROWS - 1;
		cy = (cy + n > i) ? i : cy + n;
		if (f == 'E') cx = 0;
		clamp();
		break;
	case 'C': case 'a': cx += n; clamp(); break;
	case 'D': if (cx >= COLS) cx = COLS - 1; cx -= n; clamp(); break;
	case 'G': case '`': cx = n - 1; clamp(); break;
	case 'd': cy = n - 1; clamp(); break;
	case 'H': case 'f':
		cy = n - 1;
		cx = (npar > 1 && par[1]) ? par[1] - 1 : 0;
		clamp();
		break;
	case 'J':
		if (cx >= COLS) cx = COLS - 1;
		if (par[0] == 0) {
			erase(cy, cx, COLS - 1);
			for (i = cy + 1; i < ROWS; i++) erase(i, 0, COLS - 1);
		} else if (par[0] == 1) {
			for (i = 0; i < cy; i++) erase(i, 0, COLS - 1);
			erase(cy, 0, cx);
		} else {
			for (i = 0; i < ROWS; i++) erase(i, 0, COLS - 1);
		}
		break;
	case 'K':
		if (cx >= COLS) cx = COLS - 1;
		if (par[0] == 0) erase(cy, cx, COLS - 1);
		else if (par[0] == 1) erase(cy, 0, cx);
		else erase(cy, 0, COLS - 1);
		break;
	case 'L':
		if (cy >= r_top && cy <= r_bot)
			while (n-- > 0) insert_line(cy);
		break;
	case 'M':
		if (cy >= r_top && cy <= r_bot)
			while (n-- > 0) delete_line(cy);
		break;
	case 'S': while (n-- > 0) scroll_up(); break;
	case 'T': while (n-- > 0) scroll_down(); break;
	case '@':
		if (cx >= COLS) cx = COLS - 1;
		if (n > COLS - cx) n = COLS - cx;
		for (i = COLS - 1; i >= cx + n; i--) CELL(cy, i) = CELL(cy, i - n);
		erase(cy, cx, cx + n - 1);
		break;
	case 'P':
		if (cx >= COLS) cx = COLS - 1;
		if (n > COLS - cx) n = COLS - cx;
		for (i = cx; i < COLS - n; i++) CELL(cy, i) = CELL(cy, i + n);
		erase(cy, COLS - n, COLS - 1);
		break;
	case 'X':
		if (cx >= COLS) cx = COLS - 1;
		if (n > COLS - cx) n = COLS - cx;
		erase(cy, cx, cx + n - 1);
		break;
	case 'm': sgr(); break;
	case 'r': {
		int t = par[0] ? par[0] : 1;
		int b = (npar > 1 && par[1]) ? par[1] : ROWS;
		if (b > ROWS) b = ROWS;
		if (t < b) { r_top = t - 1; r_bot = b - 1; cx = 0; cy = 0; }
		break;
	}
	case 's': save(); break;
	case 'u': restore(); break;
	case 'n':
		if (par[0] == 5) reply("\033[0n");
		else if (par[0] == 6) {
			reply("\033[");
			reply_num(cy + 1);
			reply(";");
			reply_num((cx < COLS ? cx : COLS - 1) + 1);
			reply("R");
		}
		break;
	case 'c': if (par[0] == 0) reply("\033[?6c"); break;
	}
}

/* (mouse.c: what is selected on the screen may move when it is written to) */
extern unsigned char mouse_sel_on;
void mouse_clear(void);

void term_char(unsigned char c)
{
	if (mouse_sel_on && cur == shown) mouse_clear();
	switch (st) {
	case S_TEXT:
		if (c == 0x1b) { st = S_ESC; u_left = 0; break; }
		if (c < 0x20) {
			u_left = 0;
			switch (c) {
			case '\r': cx = 0; break;
			case '\n': case 0x0b: case 0x0c: line_feed(); break;
			case '\b': if (cx >= COLS) cx = COLS - 1; if (cx > 0) cx--; break;
			case '\t':
				if (cx >= COLS) cx = COLS - 1;
				cx = (cx | 7) + 1;
				if (cx > COLS - 1) cx = COLS - 1;
				break;
			case 0x0e: gfx = 1; break;
			case 0x0f: gfx = 0; break;
			}
			break;
		}
		if (c == 0x7f) break;
		if (c < 0x80) {
			u_left = 0;
			if (gfx && c >= 0x60) draw(dec_gfx[c - 0x60]);
			else draw(c);
		} else if (c >= 0xc0) {
			/* the first of several */
			if (c < 0xe0) { u_left = 1; u_code = c & 0x1f; }
			else if (c < 0xf0) { u_left = 2; u_code = c & 0x0f; }
			else { u_left = 3; u_code = c & 0x07; }
		} else if (u_left) {
			u_code = u_code << 6 | (c & 0x3f);
			if (--u_left == 0) draw(from_unicode(u_code));
		} else {
			draw(0x7f);
		}
		break;

	case S_ESC:
		st = S_TEXT;
		switch (c) {
		case '[': st = S_CSI; npar = 0; par[0] = 0; par[1] = 0; priv = 0; break;
		case ']': case 'P': case '^': case '_': st = S_OSC; break;
		case '(': case ')': case '*': case '+': case '#': case '%':
			st = S_SET; priv = c; break;
		case '7': save(); break;
		case '8': restore(); break;
		case 'D': line_feed(); break;
		case 'E': cx = 0; line_feed(); break;
		case 'M': reverse_feed(); break;
		case 'c': reset(); break;
		}
		break;

	case S_SET:
		/* ESC ( 0 is the line-drawing set, ESC ( B the usual one */
		if (priv == '(') gfx = (c == '0');
		st = S_TEXT;
		break;

	case S_CSI:
		if (c >= '0' && c <= '9') {
			if (npar == 0) npar = 1;
			if (npar <= NPAR) {
				unsigned v = par[npar - 1];
				v = (v << 3) + (v << 1) + (c - '0');
				par[npar - 1] = v > 9999 ? 9999 : v;
			}
		} else if (c == ';') {
			if (npar == 0) npar = 1;
			if (npar < NPAR) par[npar++] = 0;
			else npar = NPAR + 1;			/* too many: the rest are dropped */
		} else if (c == '?' || c == '>' || c == '=' || c == '<') {
			priv = c;
		} else if (c >= 0x40 && c <= 0x7e) {
			if (npar > NPAR) npar = NPAR;
			st = S_TEXT;
			csi(c);
		} else if (c == 0x1b) {
			st = S_ESC;
		} else if (c < 0x20) {
			/* a control character inside a sequence acts as itself */
			st = S_TEXT; term_char(c); st = S_CSI;
		}
		/* (space .. '/': intermediates, ignored) */
		break;

	case S_OSC:
		if (c == 0x07) st = S_TEXT;
		else if (c == 0x1b) st = S_OSC_ESC;
		break;
	case S_OSC_ESC:
		st = (c == '\\') ? S_TEXT : (c == 0x1b) ? S_OSC_ESC : S_OSC;
		break;
	}
}

void term_update(void)
{
	show_cursor();
}

/* the terminal the next characters are for */
void term_use(int n)
{
	if (n >= count) n = 0;
	cur = (unsigned char)n;
	T = &terms[n];
}

int term_current(void) { return cur; }
int term_shown(void) { return shown; }
int term_count(void) { return count; }
int term_appkeys(void) { return terms[shown].appkeys; }
int term_paste_brackets(void) { return terms[shown].brackets; }

unsigned term_cell(int r, int c)
{
	struct term *was = T;
	unsigned v;
	T = &terms[shown];
	v = CELLS[cell_of(r - (int)T->back, c)];		/* (of the picture, scrolled back or not) */
	T = was;
	return v;
}

/* The picture of the terminal shown moves back into what scrolled off
   (n > 0) or forward again; 0: to the screen itself. Only the first
   terminal has anything there, and only if the machine gave it room. */
void term_scroll(int n)
{
	struct term *was = T;
	unsigned char was_cur = cur;
	int b;

	cur = shown; T = &terms[shown];
	b = n ? (int)T->back + n : 0;
	if (b < 0) b = 0;
	if (b > (int)T->hist) b = (int)T->hist;
	if ((unsigned)b != T->back) {
		if (mouse_sel_on) mouse_clear();
		T->back = (unsigned)b;
		show_start();
	}
	cur = was_cur; T = was;
}

int term_scrolled(void) { return terms[shown].back != 0; }

/* (from_unicode()'s way back, for what is in the font twice: the
   first; the boxes as light lines) */
unsigned term_unicode(unsigned ch)
{
	static const unsigned short box[] = {
		0xb0, 0x2591, 0xb1, 0x2592, 0xb2, 0x2593, 0xb3, 0x2502, 0xb4, 0x2524, 0xbf, 0x2510,
		0xc0, 0x2514, 0xc1, 0x2534, 0xc2, 0x252c, 0xc3, 0x251c, 0xc4, 0x2500, 0xc5, 0x253c,
		0xd9, 0x2518, 0xda, 0x250c, 0xdb, 0x2588, 0xdc, 0x2584, 0xdd, 0x258c, 0xde, 0x2590,
		0xdf, 0x2580
	};
	unsigned i;
	if (ch >= 0x20 && ch < 0x7f) return ch;
	if (ch >= 0x80 && ch <= 0xaf) return ch + 0x20;
	if (ch >= 0xe0) return ch - 0x10;
	if (ch >= 0x10 && ch <= 0x1f) return ch + 0xe0;
	if (ch == 0x01) return 0x20ac;
	for (i = 0; i < sizeof box / sizeof box[0]; i += 2)
		if (box[i] == ch) return box[i + 1];
	return ' ';
}

/* another terminal's screen on the monitor: nothing is copied */
void term_show(int n)
{
	struct term *was = T;
	unsigned char was_cur = cur;

	if (n < 0 || n >= count) return;
	if (mouse_sel_on) mouse_clear();
	shown = (unsigned char)n;
	cur = shown; T = &terms[shown];
	REGS[R_BASE] = T->base;
	REGS[R_END] = T->base + T->rows * COLS;
	show_start();
	show_cursor();
	term_ctrl();
	cur = was_cur; T = was;
}

/* n terminals, all empty, the first shown; the first has hist screens
   more of cells for what scrolls off its top */
void term_init(int n, int hist)
{
	int i;
	if (n < 1) n = 1;
	if (n > TERMS_MAX) n = TERMS_MAX;
	if (hist < 0) hist = 0;
	if (hist > HIST_MAX) hist = HIST_MAX;
	count = (unsigned char)n;
	shown = 0;
	for (i = n - 1; i >= 0; i--) {
		term_use(i);
		T->base = i ? (unsigned)(i + hist) * SCREEN : 0;
		T->rows = i ? ROWS : (unsigned)(1 + hist) * ROWS;
		reset();
	}
	term_show(0);
}

void term_puts(const char *s)
{
	while (*s) term_char((unsigned char)*s++);
	show_cursor();
}
