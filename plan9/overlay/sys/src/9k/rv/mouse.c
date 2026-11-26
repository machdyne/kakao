/*
 * What the mouse device asks of the port.  The mouse is a virtio input
 * device (kkinput.c) and has nothing to be told.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#define	Image	IMAGE
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

Kkconf conf;

void
mousectl(Cmdbuf*)
{
	error(Ebadctl);
}
