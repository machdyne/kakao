/*
 * Start the screen, if there is one (screen.c), when the kernel's
 * drivers are linked in: before the input devices, which ask it where
 * the pointer can go.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

void	screeninit(void);

void
kkscreenlink(void)
{
	screeninit();
}
