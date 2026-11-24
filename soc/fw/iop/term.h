/* The terminal (term.c), and what it needs from where it runs. */
#ifndef TERM_H
#define TERM_H

#include <stdint.h>

/* There are as many terminals as the machine has consoles (at most
   ten), each with its own screen; one is shown. Characters go to the
   terminal chosen with term_use(). */
void term_init(int n, int hist);		/* n terminals; screens of scroll buffer for the first */
void term_scroll(int n);				/* the picture n rows back (n < 0: forward; 0: the screen) */
int term_scrolled(void);
void term_use(int n);					/* the next characters are for terminal n */
void term_char(unsigned char c);		/* a character from the host */
void term_update(void);					/* the cursor, after some characters */
void term_puts(const char *s);
void term_show(int n);					/* terminal n's screen on the monitor */
int term_current(void);
int term_shown(void);
int term_count(void);

/* the text mode's CTRL, written again: after one of these changes */
void term_ctrl(void);
extern unsigned char term_cur_block, term_cur_steady;
extern unsigned term_ctrl_or;			/* bits 4 and 5: the overlay's (hud.c) */

/* the host (of the terminal shown) asked for the cursor keys' other
   set (ESC O A, not ESC [ A) */
int term_appkeys(void);

/* the terminal shown: the cell at a row and column of the picture; a
   character of the font as Unicode; whether its host asked for pasted
   text in brackets */
unsigned term_cell(int r, int c);
unsigned term_unicode(unsigned ch);
int term_paste_brackets(void);

/* provided: a character back to the host of the terminal in use (an
   answer) */
void term_send(unsigned char c);

#ifdef TERM_HOST
extern uint32_t t_cells[13 * 2400];
extern uint32_t t_regs[8];
#endif

#endif
