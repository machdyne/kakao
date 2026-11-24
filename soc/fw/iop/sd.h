/* The SD card, on the board's SPI master (Zeitlos's rtl/spim.v). */
#ifndef SD_H
#define SD_H
#include <stdint.h>
uint32_t sd_init(void);						/* its size in sectors, 0: no card */
int sd_read(uint32_t lba, uint32_t *to);	/* a sector, 128 words */
int sd_write(uint32_t lba, const uint32_t *from);	/* ...written, but the card may be busy with it yet */
int sd_busy(void);							/* it is, after a write */
#endif
