/* The I/O processor's program: what its parts ask of each other. */
#ifndef IOP_H
#define IOP_H

#include <stdint.h>

/* main.c */
void host_put(unsigned char c);			/* a byte to the host of the terminal shown, as if typed */
void host_put_to(int con, unsigned char c);	/* ...or of another */
uint32_t now_ticks(void);				/* 732 a second (the USB driver's clock) */

/* kbd.c: the keyboard, from the USB host's two keyboard blocks */
void kbd_init(void);
void kbd_poll(void);
extern uint8_t kbd_layout;				/* index into the layouts built in */
extern uint8_t kbd_caps_ctrl;			/* Caps Lock is a Control key */
extern uint8_t kbd_alt_esc;				/* Alt sends ESC before the key */
extern uint8_t kbd_bs_del;				/* Backspace sends DEL (else BS) */
extern uint8_t kbd_rep_delay;			/* before a held key repeats, ticks */
extern uint8_t kbd_rep_rate;			/* ...and between repeats, ticks */
int kbd_count(void);					/* keyboards attached */

/* mouse.c: the pointer, selecting, Super-C and Super-V */
void mouse_at(int x, int y, int buttons);	/* where it is (pixels), its buttons */
void mouse_gone(void);					/* there is none any more */
void mouse_tick(void);
void mouse_clear(void);					/* the selection goes */
void mouse_copy(void);
void mouse_paste(void);
void mouse_pump(void);					/* what is being pasted, on its way */
extern uint8_t mouse_sel_on;
int host_room(void);					/* main.c: the queue to the hosts takes another */

/* hud.c: the menus, on the text mode's overlay */
void hud_init(void);
void hud_toggle(void);
int hud_active(void);
void hud_key(uint32_t sym);				/* a keysym (zkbd.h) while it is open */
void hud_tick(void);
/* a note on the top line: what is on the USB ports */
void hud_usb_note(int keyboards, int hubs, int others, int failed, int step, int status);
void hud_note(const char *t);
void hud_term_note(void);			/* ...and which terminal is shown, when that changes */

#endif
