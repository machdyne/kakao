/*
 * Zeitlos's RMII MAC (ext/zeitlos/rtl/ethmac_rmii.v) at the board's
 * 0x4000_2000: frames are received into and sent from its own buffers,
 * so nothing is copied here.
 */

#include "nic.h"

#define MAC_STATUS  (*(volatile uint32_t *)0x40002000)
#define MAC_RX_LEN  (*(volatile uint32_t *)0x40002004)
#define MAC_RX_CTRL (*(volatile uint32_t *)0x40002008)
#define MAC_TX_LEN  (*(volatile uint32_t *)0x4000200c)
#define MAC_TX_CTRL (*(volatile uint32_t *)0x40002010)
#define MAC_RX_BUF  ((volatile uint32_t *)0x40002100)
#define MAC_TX_BUF  ((volatile uint32_t *)0x40002a00)
#define ST_RX_READY 4u
#define ST_TX_BUSY  8u

int nic_init(void)
{
	/* (the MAC says how many frames it can hold; nothing there reads zero) */
	return ((MAC_STATUS >> 12) & 15) != 0;
}

const volatile uint32_t *nic_rx(unsigned *len)
{
	if (!(MAC_STATUS & ST_RX_READY)) { *len = 0; return 0; }
	*len = MAC_RX_LEN & 0x7ff;
	return MAC_RX_BUF;
}

void nic_rx_done(void)
{
	MAC_RX_CTRL = 1;
}

volatile uint32_t *nic_tx_buf(void)
{
	return (MAC_STATUS & ST_TX_BUSY) ? 0 : MAC_TX_BUF;
}

void nic_tx(unsigned len)
{
	/* (60 bytes at least: the words after a short frame's end are
	   zeroed; its last word's own tail is the caller's zeroes) */
	unsigned i;
	for (i = (len + 3) >> 2; i < 15; i++) MAC_TX_BUF[i] = 0;
	if (len < 60) len = 60;
	MAC_TX_LEN = len;
	MAC_TX_CTRL = 1;
}
