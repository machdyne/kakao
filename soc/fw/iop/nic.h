/*
 * The network interface behind the virtio network device (vnet.c): a
 * frame at a time, each in a buffer of whole words, without the
 * checksum at its end. One back end is built in: nic_rmii.c, Zeitlos's
 * RMII MAC. Another (an SPI controller, a USB adapter) gives the same
 * five functions, with buffers of its own where the MAC's are here.
 */
#ifndef NIC_H
#define NIC_H
#include <stdint.h>
int nic_init(void);						/* 1: there is one on this board */
/* a frame has come in: its words (the first byte lowest) and its
   length, 0 if none; nic_rx_done() when it has been taken */
const volatile uint32_t *nic_rx(unsigned *len);
void nic_rx_done(void);
/* the buffer for a frame to send, 0 while the last is still going
   out; then nic_tx(len), which pads a short one */
volatile uint32_t *nic_tx_buf(void);
void nic_tx(unsigned len);
#endif
