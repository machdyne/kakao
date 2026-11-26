/*
 * libmemdraw takes the memory of its images from a pool, imagmem, which
 * the kernels of ../../9 have (../port/alloc.c) and this one, with
 * qmalloc, has not.  Here is as much of a pool as the library uses:
 * the kernel's own allocator under the pool's two calls.  Images are
 * never moved (compaction is the pool allocator's), which the library
 * allows.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/* the kernel has panic as a macro, and a Pool has a member of that name */
#undef panic
#include <pool.h>

static Pool kkimagmem = {
	.name	= "kkimage",
};
Pool *imagmem = &kkimagmem;

void*
poolalloc(Pool*, uintptr n)
{
	return malloc(n);
}

void
poolfree(Pool*, void *v)
{
	free(v);
}
