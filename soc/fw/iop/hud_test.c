/*
 * The menus (hud.c) built for the host: keys are given on the command
 * line, and the overlay's cells and the colours are printed for
 * tests/hud.py to draw.
 *
 *   hud_test <key> ...     s: Super (open, close)  l r u d: the arrows
 *                          e: Enter  x: Esc  n: a note about USB
 */

#include <stdio.h>
#include "iop.h"
#include "term.h"
#include "usbh.h"
#include "zkbd.h"

extern uint32_t h_ovl[30 * 80], h_pal[32];

uint8_t kbd_layout, kbd_caps_ctrl, kbd_alt_esc = 1, kbd_bs_del = 1, kbd_rep_delay, kbd_rep_rate;
unsigned char term_cur_block, term_cur_steady;
unsigned term_ctrl_or;
int term_count(void) { return 4; }
int term_shown(void) { return 1; }
void term_ctrl(void) { }
int kbd_count(void) { return 1; }
uint32_t now_ticks(void) { return 732u * (12 * 60 + 41); }
int z_usbh_status(uint8_t *typ, int max) { typ[0] = Z_USBH_CLASS_HUB; typ[1] = Z_USBH_CLASS_HID; return 2; }

int main(int argc, char **argv)
{
	int i, r, c;

	hud_init();
	for (i = 1; i < argc; i++)
		switch (argv[i][0]) {
		case 's': hud_toggle(); break;
		case 'l': hud_key(Z_KEY_LEFT); break;
		case 'r': hud_key(Z_KEY_RIGHT); break;
		case 'u': hud_key(Z_KEY_UP); break;
		case 'd': hud_key(Z_KEY_DOWN); break;
		case 'e': hud_key(0x0d); break;
		case 'x': hud_key(0x1b); break;
		case 'n': hud_usb_note(1, 1, 0, 1, 7, 3); break;
		}
	printf("%u\n", term_ctrl_or);
	for (i = 0; i < 32; i++) printf("%06x\n", h_pal[i]);
	for (r = 0; r < 30; r++) {
		for (c = 0; c < 80; c++) printf("%04x ", h_ovl[r * 80 + c]);
		printf("\n");
	}
	return 0;
}
