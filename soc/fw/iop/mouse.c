/*
 * The mouse: a pointer on the screen, text selected with the left
 * button held, Super-C to keep it and Super-V to type it into the
 * terminal shown. The host knows nothing of it (built with INPUT, the
 * mouse is also a device of the host's while the graphics screen is
 * chosen: vinput.c).
 *
 * The pointer is a cell with its colours exchanged, and so are the
 * cells selected (the text mode's POINTER and SELECT). A selection is
 * a run of the picture's cells, from one to another through the ends
 * of the rows between, as text is read. It goes when the terminal
 * writes anything or another is shown, since what it marked may have
 * moved.
 *
 * What is kept is text: the rows' trailing blanks left out, a carriage
 * return between rows (what Enter sends), as UTF-8. When pasted it is
 * typed as a keyboard would type it, in the brackets the host asked
 * for if it did (ESC [ 200 ~ ... ESC [ 201 ~).
 */

#include "iop.h"
#include "term.h"

#define COLS 80
#define ROWS 30
#ifdef INPUT
#define CLIP_MAX 2112			/* (INPUT=1: memory is short; 26 full lines of ASCII) */
#else
#define CLIP_MAX 2440			/* a screen of ASCII and its row ends */
#endif

#ifdef TERM_HOST
#define REGS t_regs
#else
#define REGS ((volatile uint32_t *)0x10020000)
#endif
#define R_POINTER 6
#define R_SELECT  7

static unsigned char clip[CLIP_MAX];
static uint16_t clip_n;
static uint16_t paste_at;		/* what of it is still to be typed */
static uint8_t  pasting;		/* 1 the opening bracket, 2 the text, 3 the closing one */
static uint8_t  paste_i;

static uint16_t ptr = 0xffff;	/* the pointer's cell (none yet) */
static uint8_t  ptr_on, down;
static uint16_t anchor;			/* where the button went down */
static uint16_t sel_a, sel_b;
static uint8_t  sel_on, moved;
static uint32_t seen_at;		/* when it last moved: it goes away after a while */

uint8_t mouse_sel_on;			/* (for term.c: there is a selection to take away) */

static void show(void)
{
	REGS[R_POINTER] = ptr_on ? 0x8000u | ptr : 0;
	REGS[R_SELECT] = sel_on ? 0x80000000u | (uint32_t)sel_b << 16 | sel_a : 0;
	mouse_sel_on = sel_on;
}

void mouse_clear(void)
{
	if (!sel_on) return;
	sel_on = 0;
	show();
}

/* where the mouse is, in pixels of the 640 by 480 picture, and its
   buttons (bit 0 the left one) */
void mouse_at(int x, int y, int buttons)
{
	uint16_t at = (uint16_t)((y >> 4) * COLS + (x >> 3));
	int left = buttons & 1;

	if (at >= ROWS * COLS) return;
	if (hud_active()) {				/* the menus are the keyboard's */
		if (ptr_on) { ptr_on = 0; show(); }
		down = 0;
		return;
	}
	/* (where it was, as it was: nothing to do -- also when the pointer
	   has gone away since. It comes back when the mouse moves, not with
	   the next report from where it lies: that made it flash.) */
	if (at == ptr && left == down) return;
	seen_at = now_ticks();
	ptr = at;
	ptr_on = 1;

	if (left && !down) {
		/* pressed: a new selection begins here, once it moves */
		anchor = at; moved = 0; sel_on = 0;
	} else if (left && at != anchor) moved = 1;
	if (left && moved) {
		sel_a = at < anchor ? at : anchor;
		sel_b = at < anchor ? anchor : at;
		sel_on = 1;
	}
	down = (uint8_t)left;
	show();
}

void mouse_gone(void)
{
	if (!ptr_on && !down) return;
	ptr_on = 0; down = 0;
	show();
}

/* the pointer goes away when the mouse has lain still for two seconds */
void mouse_tick(void)
{
	if (ptr_on && !down && now_ticks() - seen_at > 2 * 732) { ptr_on = 0; show(); }
}

static void keep(unsigned u)
{
	if (u < 0x80) {
		if (clip_n < CLIP_MAX) clip[clip_n++] = (unsigned char)u;
	} else if (u < 0x800) {
		if (clip_n + 2 <= CLIP_MAX) {
			clip[clip_n++] = (unsigned char)(0xc0 | u >> 6);
			clip[clip_n++] = (unsigned char)(0x80 | (u & 0x3f));
		}
	} else if (clip_n + 3 <= CLIP_MAX) {
		clip[clip_n++] = (unsigned char)(0xe0 | u >> 12);
		clip[clip_n++] = (unsigned char)(0x80 | ((u >> 6) & 0x3f));
		clip[clip_n++] = (unsigned char)(0x80 | (u & 0x3f));
	}
}

/* Super-C: what is selected is kept */
void mouse_copy(void)
{
	int r, c, r0, r1;

	if (!sel_on) { hud_note("Nothing is selected"); return; }
	clip_n = 0;
	r0 = sel_a / COLS; r1 = sel_b / COLS;
	for (r = r0; r <= r1; r++) {
		int c0 = r == r0 ? sel_a % COLS : 0, c1 = r == r1 ? sel_b % COLS : COLS - 1;
		while (c1 >= c0 && (term_cell(r, c1) & 0xff) == ' ') c1--;
		for (c = c0; c <= c1; c++) keep(term_unicode(term_cell(r, c) & 0xff));
		if (r != r1) keep('\r');
	}
	hud_note(clip_n ? "Copied" : "Nothing but blanks is selected");
}

/* Super-V: what was kept is typed, as fast as the host takes it (mouse_pump) */
void mouse_paste(void)
{
	if (!clip_n) { hud_note("Nothing has been copied"); return; }
	if (pasting) return;
	paste_at = 0; paste_i = 0;
	pasting = term_paste_brackets() ? 1 : 2;
}

void mouse_pump(void)
{
	static const char open[] = "\033[200~", close[] = "\033[201~";

	while (pasting && host_room()) {
		if (pasting == 2) {
			if (paste_at < clip_n) host_put(clip[paste_at++]);
			else pasting = paste_i ? 3 : 0, paste_i = 0;
		} else {
			const char *b = pasting == 1 ? open : close;
			if (b[paste_i]) host_put((unsigned char)b[paste_i++]);
			else if (pasting == 1) pasting = 2;		/* (paste_i stays: there are brackets) */
			else pasting = 0, paste_i = 0;
		}
	}
}

#ifdef TERM_HOST
const unsigned char *mouse_clip(unsigned *n) { *n = clip_n; return clip; }
#endif
