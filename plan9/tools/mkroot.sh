#!/bin/sh
# Put together the Plan 9 source root the kernel is built in: the Fourth
# Edition's sources, the 9k distribution over them, this directory's
# overlay and patches over that, and the host's tools where Plan 9's
# mkfiles and scripts look for them.  tools/p9run runs commands in it.
#
# usage: mkroot.sh P9SRC DIST P9P HOSTBIN PLAN9DIR ROOT
set -e
P9SRC=$1 DIST=$2 P9P=$3 HOSTBIN=$4 HERE=$5 R=$6
[ -n "$R" ] || { echo "usage: $0 P9SRC DIST P9P HOSTBIN PLAN9DIR ROOT" >&2; exit 2; }

rm -rf "$R"
mkdir -p "$R/bin/aux" "$R/tmp" "$R/n" "$R/dev" "$R/host" "$R/p9p/bin" "$R/p9p/lib"

# 1. the sources.  Not the Fourth Edition's binaries or its other ports.
(cd "$P9SRC" && tar cf - --exclude=.git sys/src sys/include sys/lib rc lib/ndb \
	cfg adm 386/mkfile 386/include amd64/mkfile amd64/include) | (cd "$R" && tar xf -)
(cd "$DIST" && tar cf - .) | (cd "$R" && tar xf -)
(cd "$HERE/overlay" && tar cf - .) | (cd "$R" && tar xf -)
mkdir -p "$R/riscv64/lib/ape" "$R/riscv64/bin/auth" "$R/riscv64/bin/ip" \
	"$R/riscv64/bin/aux" "$R/riscv64/bin/ndb"

# 2. the distribution's headers go with library sources it does not
# include.  Where the Fourth Edition's sources disagree with them:
#   mp.h      the Fourth Edition's own (the distribution's wants an _mpfree)
#   the rest  small changes to the sources, in patches/
cp "$P9SRC/sys/include/mp.h" "$R/sys/include/mp.h"
for p in "$HERE"/patches/*.patch; do
	(cd "$R" && patch -s -p1 < "$p")
done

# 3. Plan 9 builds 9k with ../9's directories bound over its own.  There
# are no name spaces here, so the unions are made with links: what 9k
# has wins, as a bind -a would have it.
cd "$R/sys/src/9k"
for d in ip boot pc; do
	[ -e $d ] || ln -s ../9/$d $d
done
for f in ../9/port/*; do
	b=$(basename "$f")
	[ -e "port/$b" ] || ln -s "../../9/port/$b" "port/$b"
done
cd "$R"

# 4. the tools.  The compilers are static; plan9port's and the host's
# own programs are dynamic, so the libraries they need come too.
cp "$HOSTBIN"/jc "$HOSTBIN"/jl "$HOSTBIN"/ja "$HOSTBIN"/ic "$HOSTBIN"/il \
	"$HOSTBIN"/ia "$HOSTBIN"/ar "$HOSTBIN"/size "$HOSTBIN"/strip "$R/bin/"
cp "$HOSTBIN/data2s" "$R/bin/aux/data2s"
cp "$P9P/rcmain" "$R/p9p/"
cp "$P9P/lib/yaccpar" "$P9P/lib/yaccpars" "$R/p9p/lib/"
for t in rc mk awk sed grep cat echo test date xd dd tr sort uniq basename \
	cmp diff touch wc tail tee sleep yacc ed read seq join fmt cleanname \
	mkdir ls rm p hoc bc strings; do
	if [ -x "$P9P/bin/$t" ]; then
		cp "$P9P/bin/$t" "$R/p9p/bin/"
		ln -s "/p9p/bin/$t" "$R/bin/$t"
	fi
done
for t in cp mv gzip sh ln chmod env pwd; do
	p=$(command -v $t)
	[ -x "$p" ] || p=/bin/$t	# pwd: the shell answers with its own
	cp "$p" "$R/host/"
	[ -e "$R/bin/$t" ] || ln -s "/host/$t" "$R/bin/$t"
done
for b in "$R"/p9p/bin/* "$R"/host/*; do
	ldd "$b" 2>/dev/null | awk '/=> \//{print $3} /^\t\/lib/{print $1}'
done | sort -u | while read l; do
	mkdir -p "$R$(dirname "$l")"
	cp -L "$l" "$R$l"
done

# 5. three programs Plan 9 has and the host has not
cat > "$R/bin/bind" <<'X'
#!/bin/rc
# no name spaces here: tools/mkroot.sh has made the unions with links
exit 0
X
cat > "$R/bin/cpdiffers" <<'X'
#!/bin/rc
# cpdiffers from to - copy from to to unless they are the same already,
# so that what depends on to is not rebuilt for nothing
if (! cmp -s $1 $2)
	cp $1 $2
exit 0
X
cat > "$R/bin/file" <<'X'
#!/bin/rc
# file - enough of file(1) for the kernel's mkrootall, which strips what
# file calls an executable: size(1) knows a Plan 9 executable
for(f){
	if(size $f >/dev/null >[2=1])
		echo $f: plan 9 executable
	if not
		echo $f: data
}
X
chmod +x "$R/bin/bind" "$R/bin/cpdiffers" "$R/bin/file"
echo "root: $R ($(du -sh "$R" | cut -f1))"
