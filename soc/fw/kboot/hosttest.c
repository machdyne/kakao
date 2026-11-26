/*
 * kboot's FAT code (sdboot.c) on the host, with a file as the card:
 *
 *   hosttest <image> [<path>]
 *
 * prints what kboot would print when it cannot boot from that card,
 * or, when it can find <path> (boot.json by default), the file's size.
 * `make hosttest` makes cards and runs it on them.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define SD_HOST
#define SD_SAYS
#define MEM_MAIN 0x80000000u
#define DTB_ADDR 0x81f00000u

static FILE *img;
static void print(const char *s) { fputs(s, stdout); }
static void putc_(char c) { putchar(c); }
#define UART_LSR 0x40
static void print_hex(uint32_t v, int digits) { printf("%0*x", digits, v); }
static int sd_init(void) { return img != 0; }
static int sd_read(uint32_t lba, uint32_t *to) {
	if (fseeko(img, (off_t)lba * 512, SEEK_SET)) return 0;
	return fread(to, 1, 512, img) == 512;
}

#include "sdboot.c"

int main(int argc, char **argv) {
	uint32_t clu, size;
	const char *path = argc > 2 ? argv[2] : "boot.json";
	if (argc < 2 || !(img = fopen(argv[1], "rb"))) { fprintf(stderr, "hosttest <image> [<path>]\n"); return 2; }
	if (fat_mount() && (os_choose(), fat_open(path, (int)strlen(path), &clu, &size))) {
		say_fs();
		printf("found: %s, %u bytes, cluster %u\n", path, size, clu);
		return 0;
	}
	/* as kboot would: it stops before it loads anything (a card it
	   could boot from is not given to it here: it would load) */
	sd_boot();
	return 1;
}
