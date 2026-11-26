/*
 * ChaCha stream cipher (RFC 7539), as the 9k kernel's ../port/random.c
 * uses it: a 256 (or 128) bit key, a 96 bit nonce, a 32 bit block counter.
 * Written for the Kakao port; the kernel's own libsec was not part of
 * the distribution.
 */
#include <u.h>
#include <libc.h>
#include <libsec.h>

#define ROTL(v, n)	(((v) << (n)) | ((v) >> (32 - (n))))
#define QR(a, b, c, d) \
	a += b; d ^= a; d = ROTL(d, 16); \
	c += d; b ^= c; b = ROTL(b, 12); \
	a += b; d ^= a; d = ROTL(d, 8); \
	c += d; b ^= c; b = ROTL(b, 7);

static u32int
get32(uchar *p)
{
	return p[0] | p[1]<<8 | p[2]<<16 | (u32int)p[3]<<24;
}

static void
block(Chachastate *s, uchar *out)
{
	int i;
	u32int x[16], *in;

	in = s->input;
	for(i = 0; i < 16; i++)
		x[i] = in[i];
	for(i = s->rounds; i > 0; i -= 2){
		QR(x[0], x[4], x[8], x[12])
		QR(x[1], x[5], x[9], x[13])
		QR(x[2], x[6], x[10], x[14])
		QR(x[3], x[7], x[11], x[15])
		QR(x[0], x[5], x[10], x[15])
		QR(x[1], x[6], x[11], x[12])
		QR(x[2], x[7], x[8], x[13])
		QR(x[3], x[4], x[9], x[14])
	}
	for(i = 0; i < 16; i++){
		x[i] += in[i];
		out[4*i+0] = x[i];
		out[4*i+1] = x[i] >> 8;
		out[4*i+2] = x[i] >> 16;
		out[4*i+3] = x[i] >> 24;
	}
	s->counter++;
}

/* iv is 12 bytes, or nil for zeros; keylen is 32 or 16 */
void
setupChachastate(Chachastate *s, uchar *key, ulong keylen, uchar *iv, int rounds)
{
	int i;
	static char sigma[] = "expand 32-byte k";
	static char tau[] = "expand 16-byte k";
	char *c;

	if(keylen != 32 && keylen != 16)
		sysfatal("invalid chacha key length");
	c = keylen == 32? sigma: tau;
	for(i = 0; i < 4; i++)
		s->constant[i] = get32((uchar*)c + 4*i);
	for(i = 0; i < 4; i++)
		s->key[i] = get32(key + 4*i);
	if(keylen == 32)
		key += 16;
	for(i = 0; i < 4; i++)
		s->key[4+i] = get32(key + 4*i);
	s->counter = 0;
	for(i = 0; i < 3; i++)
		s->iv[i] = iv != nil? get32(iv + 4*i): 0;
	s->rounds = rounds != 0? rounds: 20;
}

void
chacha_setblock(Chachastate *s, u32int blockno)
{
	s->counter = blockno;
}

void
chacha_encrypt2(uchar *src, uchar *dst, ulong bytes, Chachastate *s)
{
	int i, n;
	uchar buf[ChachaBsize];

	while(bytes > 0){
		block(s, buf);
		n = bytes < ChachaBsize? bytes: ChachaBsize;
		for(i = 0; i < n; i++)
			dst[i] = src[i] ^ buf[i];
		src += n;
		dst += n;
		bytes -= n;
	}
	memset(buf, 0, sizeof buf);
}

void
chacha_encrypt(uchar *buf, ulong bytes, Chachastate *s)
{
	chacha_encrypt2(buf, buf, bytes, s);
}
