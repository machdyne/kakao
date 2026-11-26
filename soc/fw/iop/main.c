/*
 * The I/O processor's program (rtl/k_iop.v): the terminal. Characters
 * from the host's console are drawn (term.c); the keys of a USB
 * keyboard (Zeitlos's host stack, usbglue.c; kbd.c) and the terminal's
 * answers go back to the host as if typed; and its own menus (hud.c).
 * It is also the host's virtio devices (virtio.c): the SD card as a
 * disk (vblk.c), the network (vnet.c).
 */

#include "iop.h"
#include "term.h"
#include "virtio.h"
#include "usbh.h"
#include "usbh_hw.h"
#include "usbh_int.h"

#define CON   (*(volatile uint32_t *)0x20000000)
#define KEY   (*(volatile uint32_t *)0x20000004)

#define NTERM (*(volatile uint32_t *)0x20000010)

/* to the hosts: a queue of characters, each with its console's number
   above it, emptied as the consoles take them */
#ifdef INPUT
#define QN 128			/* (INPUT=1: memory is short, and the stack needs it) */
#else
#define QN 256
#endif
static unsigned short q[QN];
static unsigned char q_in, q_out;

void host_put_to(int con, unsigned char c)
{
	unsigned char n = (unsigned char)((q_in + 1) & (QN - 1));
	if (n != q_out) { q[q_in] = (unsigned short)(con << 8 | c); q_in = n; }
}

int host_room(void)
{
	return (unsigned char)((q_in + 1) & (QN - 1)) != q_out;
}

/* what is typed goes to the terminal on the screen */
void host_put(unsigned char c)
{
	host_put_to(term_shown(), c);
}

/*
 * A terminal's answers (where the cursor is, what it is) go to its host
 * only while a keyboard is plugged in here. Without one, whoever types
 * sits at the serial port with a terminal that answers the same
 * questions, and two answers are one too many.
 */
void term_send(unsigned char c)
{
	if (kbd_count()) host_put_to(term_current(), c);
}

uint32_t now_ticks(void)
{
	return usbh_ticks();
}

/* what is on the USB ports, said on the screen when it changes */
static void usb_watch(void)
{
	static uint32_t seen;
	int i, kb = kbd_count(), hubs = 0, run = 0, failed = 0, step = 0, status = 0;
	uint32_t sig;

	for (i = 0; i < Z_USBH_MAX_DEVS; i++) {
		const z_usbh_dev_t *dv = &usbh_devs[i];
		if (dv->state == E_RUNNING) {
			if (dv->cls == Z_USBH_CLASS_HUB) hubs++; else run++;
		} else if (dv->state == E_FAILED && dv->retries >= 3) {
			failed++; step = dv->fail_state; status = dv->fail_status;
		}
	}
	if (run < kb) run = kb;
#ifdef UDEBUG
	{
		/* (to the simulation's log: the driver's first two devices, as
		   they change and now and then: state, control state, how long
		   its next step is put off; the controller's transaction status
		   and the time) */
		volatile uint32_t *out = (volatile uint32_t *)0x2000000c;
		static const char hex[] = "0123456789abcdef";
		static uint32_t dseen, dat;
		uint32_t h = 0, v[8], t = now_ticks();
		int k;
		for (i = 0; i < 2; i++) {
			v[3 * i] = usbh_devs[i].state; v[3 * i + 1] = usbh_devs[i].ctrl_state;
			v[3 * i + 2] = usbh_devs[i].ctrl_delay_until - t;
			h = (h << 7 | h >> 25) ^ v[3 * i] ^ v[3 * i + 1] << 8;
		}
		v[6] = z_usbh_rd(Z_USBH_XACT_S);
		v[7] = t;
		if (h != dseen || t - dat > 20) {
			dseen = h; dat = t;
			*out = 'U';
			for (i = 0; i < 8; i++) {
				*out = ' ';
				for (k = 28; k >= 0; k -= 4) *out = (uint32_t)hex[(v[i] >> k) & 15];
			}
			*out = '\n';
		}
	}
#endif
	sig = (uint32_t)kb | (uint32_t)hubs << 4 | (uint32_t)run << 8 | (uint32_t)failed << 12 |
		(uint32_t)step << 16 | (uint32_t)status << 24;
	if (sig != seen) {
		seen = sig;
		hud_usb_note(kb, hubs, run - kb, failed, step, status);
	}
}

int main(void)
{
	uint32_t usb_at = 0;
	int n;

	/* (bits 15..8: screens of scroll buffer for the first terminal) */
	n = (int)(NTERM & 15);
	term_init(n ? n : 1, (int)(NTERM >> 8 & 15));
	hud_init();
	term_use(0);
	term_puts("Kakao terminal\r\n");
	z_usbh_init();
	kbd_init();
	vblk_init();
	vnet_init();
#ifdef INPUT
	vinput_init();
#endif

	for (;;) {
		uint32_t c = CON;
		if (c & 0x100) {
			/* those that are waiting (not for ever: the keys too), each
			   for its console's terminal; then the cursor */
			n = 256;
			for (;;) {
				term_use((int)((c >> 12) & 15));
				term_char(c & 0xff);
				if (term_current() == term_shown()) term_update();
				if (!--n) break;
				c = CON;
				if (!(c & 0x100)) break;
			}
		}
		if (q_out != q_in && !(KEY & (1u << (q[q_out] >> 8)))) {
			KEY = q[q_out];
			q_out = (unsigned char)((q_out + 1) & (QN - 1));
		}

		if (z_usbh_present()) {
			/* the driver's step: when the controller has something to
			   say, at the pace the driver asks for while it waits, and
			   now and then anyway (the keyboard's lights) */
			uint32_t w = z_usbh_wait_ticks(), t = now_ticks();
			if (!w || w > 16) w = 16;
			if ((z_usbh_rd(Z_USBH_IRQSTAT) & z_usbh_rd(Z_USBH_IRQEN)) ||
			    t - usb_at >= w) {
				usb_at = t;
				z_usbh_poll();
			}
			kbd_poll();
			mouse_tick();
			usb_watch();
		}
		hud_tick();
		mouse_pump();

		virtio_poll();
		virtio_notified();		/* (the queues are looked at every turn) */
		vblk_poll();
		vnet_poll();
#ifdef INPUT
		vinput_poll();
#endif
	}
}
