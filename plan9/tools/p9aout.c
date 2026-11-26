/*
 * size and strip for Plan 9 executables, as host programs: the two
 * things the kernel's mkfiles ask of Plan 9's libmach.  Which one it is
 * depends on the name it is run under.
 *
 *	size file...
 *	strip [-o out] file...
 *
 * A Plan 9 a.out starts with eight big-endian words: magic, text, data,
 * bss, syms, entry, spsz, pcsz; a magic with HDR_MAGIC set is followed by
 * a 64 bit entry point.  Text and data follow, then the tables that strip
 * removes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { HDR_MAGIC = 0x8000 };

static unsigned long
get4(unsigned char *p)
{
	return (unsigned long)p[0]<<24 | p[1]<<16 | p[2]<<8 | p[3];
}

static int
ismagic(unsigned long m)
{
	unsigned long b;

	m &= ~(unsigned long)(HDR_MAGIC | 0x80000000UL);
	for(b = 8; b <= 36; b++)
		if(m == 4*b*b + 7)
			return 1;
	return 0;
}

static int
size(char *name)
{
	FILE *f;
	unsigned char h[32];
	unsigned long t, d, b;

	if((f = fopen(name, "rb")) == NULL || fread(h, 1, 32, f) != 32
	|| !ismagic(get4(h))){
		fprintf(stderr, "size: %s: not a Plan 9 executable\n", name);
		if(f != NULL)
			fclose(f);
		return 1;
	}
	fclose(f);
	t = get4(h+4); d = get4(h+8); b = get4(h+12);
	printf("%lut + %lud + %lub = %lu\t%s\n", t, d, b, t+d+b, name);
	return 0;
}

static int
strip(char *name, char *out)
{
	FILE *f;
	unsigned char *buf;
	unsigned long hlen, len;

	if((f = fopen(name, "rb")) == NULL){
		perror(name);
		return 1;
	}
	buf = malloc(40);
	if(fread(buf, 1, 32, f) != 32 || !ismagic(get4(buf))){
		fprintf(stderr, "strip: %s: not a Plan 9 executable\n", name);
		fclose(f);
		return 1;
	}
	hlen = get4(buf) & HDR_MAGIC? 40: 32;
	len = hlen + get4(buf+4) + get4(buf+8);
	buf = realloc(buf, len);
	if(fread(buf+32, 1, len-32, f) != len-32){
		fprintf(stderr, "strip: %s: short file\n", name);
		fclose(f);
		return 1;
	}
	fclose(f);
	memset(buf+16, 0, 4);		/* syms */
	memset(buf+24, 0, 8);		/* spsz, pcsz */
	if(out == NULL)
		out = name;
	if(strcmp(out, "/fd/1") == 0 || strcmp(out, "/dev/stdout") == 0)
		f = stdout;
	else if((f = fopen(out, "wb")) == NULL){
		perror(out);
		return 1;
	}
	if(fwrite(buf, 1, len, f) != len || fflush(f) != 0){
		perror(out);
		return 1;
	}
	if(f != stdout)
		fclose(f);
	free(buf);
	return 0;
}

int
main(int argc, char **argv)
{
	char *p, *out;
	int i, r, isstrip;

	p = strrchr(argv[0], '/');
	p = p != NULL? p+1: argv[0];
	isstrip = strcmp(p, "strip") == 0;
	out = NULL;
	i = 1;
	if(isstrip && i+1 < argc && strcmp(argv[i], "-o") == 0){
		out = argv[i+1];
		i += 2;
	}
	if(i >= argc){
		fprintf(stderr, isstrip? "usage: strip [-o out] file...\n":
			"usage: size file...\n");
		return 1;
	}
	r = 0;
	for(; i < argc; i++)
		r |= isstrip? strip(argv[i], out): size(argv[i]);
	return r;
}
