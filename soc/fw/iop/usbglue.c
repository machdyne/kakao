/*
 * Zeitlos's USB host stack (ext/zeitlos/sw/apps/usb: usbh.c, the hub
 * driver and the HID driver, as they are) in the I/O processor: what
 * it asks of its surroundings. There is no console to print on, and of
 * its drivers only the hub's and the keyboard's are here: storage,
 * serial and ethernet devices enumerate and are left alone.
 */

#include <stdio.h>
#include <string.h>
#include "usbh.h"
#include "usbh_msc.h"
#include "usbh_cdc.h"
#include "usbh_ecm.h"
#include "usbh_int.h"

int usb_printf(const char *fmt, ...) { (void)fmt; return 0; }
int usb_puts(const char *s) { (void)s; return 0; }
int usb_putchar(int c) { return c; }
int snprintf(char *s, size_t n, const char *fmt, ...) { (void)fmt; if (n) *s = 0; return 0; }

void usbh_notify(int what) { (void)what; }

/* the drivers that are not here: nothing is theirs */
int z_usbh_msc_bind(uint8_t addr, uint8_t xa_flags, uint8_t port,
	uint8_t mps0, const uint8_t *cfg, int cfg_len) { return 0; }
void z_usbh_msc_unbind(void) { }
int z_usbh_cdc_bind(uint8_t addr, uint8_t xa_flags, uint8_t port,
	const z_usbh_ser_t *s) { return 0; }
void z_usbh_cdc_unbind(void) { }
int z_usbh_ecm_probe(int dev, const uint8_t *cfg, int n) { return -1; }
void z_usbh_ecm_ids(uint8_t *imac, uint8_t *data, uint8_t *alt) { *imac = *data = *alt = 0; }
void z_usbh_ecm_mac(uint32_t addr) { }
uint16_t z_usbh_ecm_filter(void) { return 0; }
void z_usbh_ecm_bind(int dev, uint8_t addr, uint8_t xa_flags, uint8_t port) { }
void z_usbh_ecm_forget(int dev) { }
void z_usbh_ecm_dump(const char *pre) { }
int z_usbh_ser_probe(uint16_t vid, uint16_t pid, const uint8_t *cfg, int n,
	z_usbh_ser_t *s) { return 0; }
int z_usbh_ser_setup(const z_usbh_ser_t *s, int step, z_usbh_ser_req_t *r) { return 0; }
const char *z_usbh_ser_name(int kind) { return ""; }

void *memset(void *d, int c, size_t n)
{
	unsigned char *p = d;
	while (n--) *p++ = (unsigned char)c;
	return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
	unsigned char *p = d;
	const unsigned char *q = s;
	while (n--) *p++ = *q++;
	return d;
}

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
	while (n && *a && *a == *b) { a++; b++; n--; }
	return n ? (unsigned char)*a - (unsigned char)*b : 0;
}
