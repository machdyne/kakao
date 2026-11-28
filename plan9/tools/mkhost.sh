#!/bin/sh
# Build the Plan 9 RISC-V compilers (jc, jl, ja) and the archiver (ar) as
# Linux programs, from the sources in the 9k distribution.
#
# They are built as 32 bit programs (gcc -m32): the compilers are written
# for Plan 9's C, where long is 32 bits, and loop or miscompile where it
# is 64.  They are linked statically so that they run inside the Plan 9
# root (tools/p9run) with nothing of the host's beside them.
#
# usage: mkhost.sh DIST P9SRC P9P P9P32 OUT
#   DIST   the unpacked 9k distribution
#   P9SRC  the Plan 9 source tree (for 8l/elf.c, ar.c, libmach)
#   P9P    plan9port, built (yacc)
#   P9P32  plan9port's lib9 and libbio, built with -m32
#   OUT    where the work is done; the programs end up in OUT/bin
set -e
DIST=$1 P9SRC=$2 P9P=$3 P9P32=$4 OUT=$5
[ -n "$OUT" ] || { echo "usage: $0 DIST P9SRC P9P P9P32 OUT" >&2; exit 2; }
CMD=$DIST/sys/src/cmd
TOOLS=$(cd "$(dirname "$0")" && pwd)
YACC=$P9P/bin/yacc
export PLAN9=$P9P

rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/8l"
cp -r "$CMD/cc" "$CMD/ic" "$CMD/il" "$CMD/ia" "$OUT/"
cp "$P9SRC/sys/src/cmd/8l/elf.c" "$P9SRC/sys/src/cmd/8l/elf.h" "$OUT/8l/"
mkdir "$OUT/libmach"
cp "$DIST/sys/src/libmach/obj.c" "$DIST/sys/src/libmach/iobj.c" "$OUT/libmach/"
cp "$P9SRC/sys/src/libmach/obj.h" "$P9SRC/sys/src/libmach/swap.c" "$OUT/libmach/"
cp "$P9SRC/sys/src/cmd/ar.c" "$P9SRC/sys/include/ar.h" "$OUT/libmach/"
cp "$DIST/sys/include/mach.h" "$DIST/sys/include/a.out.h" "$OUT/libmach/"
cp "$DIST/sys/include/a.out.h" "$OUT/il/"

# Names that are functions of the host's C library, with other types.
sed -i -E 's/\bround\(/ccround(/g; s/\blog2\(/cclog2(/g' \
	"$OUT"/cc/*.[chy] "$OUT"/ic/*.[ch] "$OUT"/il/*.[ch] "$OUT"/ia/*.[chy]
sed -i -E 's/\bselect\(/arselect(/g' "$OUT/libmach/ar.c"
# qsort's comparison function, as the host declares it
sed -i 's/^int\tswcmp(void\*, void\*);/int\tswcmp(const void*, const void*);/' "$OUT/ic/gc.h"
# plan9port declares the allocator's functions with ulong, the distribution
# with uintptr; in a 32 bit program they are the same size
sed -i -E 's/\buintptr\b/ulong/g' "$OUT/cc/compat.c" "$OUT/il/compat.c"
# plan9port's USED takes one argument
sed -i 's/USED(v, pc);/USED(v); USED(pc);/' "$OUT/il/compat.c"

hcc() {	# compile one file of Plan 9 C for the host
	gcc -m32 -std=gnu17 -c -O1 -fcommon -fno-builtin -fno-strict-aliasing -fwrapv -w \
		-DRunemask=0x1FFFFF -I. "$@" -I"$P9P32/include"
}
hld() {	# link: hld target objects...
	t=$1; shift
	gcc -m32 -static -o "$t" "$@" "$P9P32/lib/libbio.a" "$P9P32/lib/lib9.a" -lm
}

echo '== cc (the compilers'"'"' common part)'
cd "$OUT/cc"
$YACC -d cc.y
for f in y.tab mac dcl acid pickle bits com scon funct sub com64 compat dpchk omachcap; do
	hcc $f.c
done
# plan9port's lib9 has the real main and calls p9main; the compiler's
# front end (cc/lex.c) is entered from ic/txt.c as ccmain.
hcc -Dp9main=ccmain -o lex.o lex.c
ar rcs cc.a y.tab.o mac.o dcl.o acid.o pickle.o bits.o com.o scon.o funct.o \
	sub.o com64.o compat.o dpchk.o omachcap.o lex.o

echo '== jc'
cd "$OUT/ic"
for f in cgen enam list mul peep reg sgen swt txt machcap; do hcc -I../cc $f.c; done
for f in pgen pswt; do hcc -I../cc ../cc/$f.c; done
hld "$OUT/bin/jc" cgen.o enam.o list.o mul.o peep.o pgen.o pswt.o reg.o sgen.o \
	swt.o txt.o machcap.o ../cc/cc.a

echo '== jl'
cd "$OUT/il"
for f in asm compress list noop obj optab pass span compat; do hcc -I../ic $f.c; done
hcc -o enam.o ../ic/enam.c
hcc -I../8l -o elf.o ../8l/elf.c
hld "$OUT/bin/jl" asm.o compress.o list.o noop.o obj.o optab.o pass.o span.o \
	compat.o enam.o elf.o

echo '== ja'
cd "$OUT/ia"
$YACC -d a.y
for f in y.tab lex; do hcc -I../ic -I../cc $f.c; done
hld "$OUT/bin/ja" y.tab.o lex.o

echo '== ar'
cd "$OUT/libmach"
cat > objstubs.c <<'X'
/* host build: only RISC-V objects are recognised */
#include <u.h>
#include <libc.h>
#include <bio.h>
#include <mach.h>
#include "obj.h"
#define STUB(is, rd) \
	int is(char *t){ USED(t); return 0; } \
	int rd(Biobuf *b, Prog *p){ USED(b); USED(p); return 0; }
STUB(_is2,_read2) STUB(_is6,_read6) STUB(_is5,_read5) STUB(_is7a,_read7a)
STUB(_is7,_read7) STUB(_is8,_read8) STUB(_isk,_readk) STUB(_isq,_readq)
STUB(_isv,_readv) STUB(_isu,_readu) STUB(_is9,_read9)
X
for f in obj iobj objstubs swap ar; do hcc -I.. $f.c; done
hld "$OUT/bin/ar" ar.o obj.o iobj.o objstubs.o swap.o

echo '== data2s, size, strip'
mkdir -p "$OUT/aux"; cd "$OUT/aux"
cp "$P9SRC/sys/src/cmd/aux/data2s.c" .
hcc data2s.c
hld "$OUT/bin/data2s" data2s.o
gcc -m32 -static -O1 -Wall -o "$OUT/bin/size" "$TOOLS/p9aout.c"
cp "$OUT/bin/size" "$OUT/bin/strip"

# the 32 bit compilers are the same programs under other names
cp "$OUT/bin/jc" "$OUT/bin/ic"; cp "$OUT/bin/jl" "$OUT/bin/il"; cp "$OUT/bin/ja" "$OUT/bin/ia"
ls -l "$OUT/bin"
