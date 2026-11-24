/* What Zeitlos's sources ask of <stdio.h>, for the I/O processor:
   nothing is printed here. */
#ifndef K_SHIM_STDIO_H
#define K_SHIM_STDIO_H
#include <stddef.h>
int printf(const char *fmt, ...);
int snprintf(char *s, size_t n, const char *fmt, ...);
int puts(const char *s);
int putchar(int c);
#endif
