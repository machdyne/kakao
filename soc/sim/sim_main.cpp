// Runs sim_top or (built with -DSOC) sim_soc: loads binaries into its memory, prints what the UARTs
// send, and types a script at them.
//
//   sim [+load=<file>@<hex address>]... [+max=<cycles>] [+type=<file>]
//
// +type's file is typed, a line at a time, each line once the output
// has gone quiet at a prompt: text ending in "# ", "$ " or "login: ". The simulation ends at +max cycles, or
// when the guest powers off, or a little after the script's last line
// has been answered.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vsim_top.h"
#include "Vsim_top___024root.h"
#ifdef SOC
#include "Vsim_top_sim_soc.h"
#define MOD sim_soc
#ifdef CPU64
#define MINSTRET __PVT__soc__DOT__c64__DOT__cpu__DOT__minstret
#else
#define MINSTRET __PVT__soc__DOT__c32__DOT__cpu__DOT__minstret
#endif
#else
#include "Vsim_top_sim_top.h"
#define MOD sim_top
#define MINSTRET __PVT__cpu__DOT__minstret
#endif
#include "verilated.h"
#ifdef SIMSD
#include "Vsim_top_sd_card.h"
#endif
#ifdef SIMSD
// (a build with VIRTIO: sd_card.v's contents and counts)
#define SIMSD     sd__DOT__card->img
#define SIMSD_RD  sd__DOT__card->n_rd
#define SIMSD_WR  sd__DOT__card->n_wr
#define SIMSD_ERR sd__DOT__card->errors
#endif
#ifdef SIMKEYS
// (a build with more than one terminal: k_vcon's receivers)
#define SIMKEYS_V __PVT__soc__DOT__term__DOT__vcon__DOT__vcon_i__DOT__rbr_v
#define SIMKEYS_D __PVT__soc__DOT__term__DOT__vcon__DOT__vcon_i__DOT__rbr
#endif

#ifdef SIMNET
// (a build with the network: rmii_peer.v's frame to the MAC)
#include "Vsim_top_rmii_peer.h"
#include <deque>
// The other end of the cable: 10.0.0.1, 02:00:00:00:00:01. It answers
// ARP for its address and pings to it, and says what it saw.
static const unsigned char peer_mac[6] = { 2, 0, 0, 0, 0, 1 }, peer_ip[4] = { 10, 0, 0, 1 };
static std::deque<std::vector<unsigned char>> net_out;
static unsigned net_seen, net_arp, net_ping;

static unsigned crc32(const unsigned char *p, size_t n) {
	unsigned c = 0xffffffffu;
	for (size_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & -(c & 1));
	}
	return ~c;
}
static unsigned short csum(const unsigned char *p, size_t n) {
	unsigned s = 0;
	for (size_t i = 0; i + 1 < n; i += 2) s += p[i] << 8 | p[i + 1];
	if (n & 1) s += p[n - 1] << 8;
	while (s >> 16) s = (s & 0xffff) + (s >> 16);
	return (unsigned short)~s;
}
static void net_send(std::vector<unsigned char> f) {
	while (f.size() < 60) f.push_back(0);
	unsigned c = crc32(f.data(), f.size());
	for (int i = 0; i < 4; i++) f.push_back((unsigned char)(c >> (8 * i)));
	net_out.push_back(f);
}
// a frame from the MAC, with its checksum
static void net_frame(std::vector<unsigned char> &f) {
	net_seen++;
	if (f.size() < 64 || crc32(f.data(), f.size() - 4) !=
			(unsigned)(f[f.size() - 4] | f[f.size() - 3] << 8 | f[f.size() - 2] << 16 | (unsigned)f[f.size() - 1] << 24)) {
		fprintf(stderr, "\n[net] a frame of %zu bytes with a WRONG checksum\n", f.size());
		return;
	}
	f.resize(f.size() - 4);
	unsigned type = f[12] << 8 | f[13];
	if (type == 0x0806 && f[21] == 1 && !memcmp(&f[38], peer_ip, 4)) {
		std::vector<unsigned char> r(42);
		memcpy(&r[0], &f[6], 6); memcpy(&r[6], peer_mac, 6);
		r[12] = 8; r[13] = 6; r[14] = 0; r[15] = 1; r[16] = 8; r[17] = 0; r[18] = 6; r[19] = 4; r[20] = 0; r[21] = 2;
		memcpy(&r[22], peer_mac, 6); memcpy(&r[28], peer_ip, 4);
		memcpy(&r[32], &f[22], 6); memcpy(&r[38], &f[28], 4);
		net_send(r); net_arp++;
		fprintf(stderr, "\n[net] ARP for 10.0.0.1 from %d.%d.%d.%d, answered\n", f[28], f[29], f[30], f[31]);
	} else if (type == 0x0800 && f[23] == 1 && !memcmp(&f[30], peer_ip, 4) && f[34] == 8) {
		std::vector<unsigned char> r(f);
		size_t ihl = (f[14] & 15) * 4, tot = f[16] << 8 | f[17];
		r.resize(14 + tot);
		memcpy(&r[0], &f[6], 6); memcpy(&r[6], peer_mac, 6);
		memcpy(&r[26], &f[30], 4); memcpy(&r[30], &f[26], 4);
		r[24] = r[25] = 0;
		unsigned short c = csum(&r[14], ihl); r[24] = c >> 8; r[25] = c & 255;
		r[14 + ihl] = 0; r[14 + ihl + 2] = r[14 + ihl + 3] = 0;
		c = csum(&r[14 + ihl], tot - ihl); r[14 + ihl + 2] = c >> 8; r[14 + ihl + 3] = c & 255;
		net_send(r); net_ping++;
		fprintf(stderr, "\n[net] ping of %zu bytes from %d.%d.%d.%d, answered\n", tot, f[26], f[27], f[28], f[29]);
	}
}
#endif

static bool ends(const std::string &s, const char *e) {
	size_t n = strlen(e);
	return s.size() >= n && !s.compare(s.size() - n, n, e);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	Vsim_top *top = new Vsim_top;
	unsigned long long max = 4000000000ULL;
	std::vector<std::string> script;
	const char *sdout = 0;
	unsigned long long linger = 1000000;
	auto &ram = top->rootp->MOD->ram;

	for (int i = 1; i < argc; i++) {
		if (!strncmp(argv[i], "+load=", 6)) {
			char *at = strrchr(argv[i], '@');
			if (!at) { fprintf(stderr, "sim: +load=<file>@<address>\n"); return 2; }
			*at = 0;
			unsigned long adr = strtoul(at + 1, 0, 16);
			FILE *f = fopen(argv[i] + 6, "rb");
			if (!f) { perror(argv[i] + 6); return 2; }
			unsigned long a = adr - 0x80000000UL, n = 0;
			int c;
			while ((c = fgetc(f)) != EOF) {
				unsigned w = ram[a >> 2];
				w = (w & ~(0xffu << (8 * (a & 3)))) | ((unsigned)c << (8 * (a & 3)));
				ram[a >> 2] = w;
				a++; n++;
			}
			fclose(f);
			fprintf(stderr, "sim: %s at %08lx, %lu bytes\n", argv[i] + 6, adr, n);
		} else if (!strncmp(argv[i], "+max=", 5)) {
			max = strtoull(argv[i] + 5, 0, 0);
		} else if (!strncmp(argv[i], "+sd=", 4)) {
#ifdef SIMSD
			// the SD card's contents; +sdout=<file>: what they are at the end
			FILE *f = fopen(argv[i] + 4, "rb");
			if (!f) { perror(argv[i] + 4); return 2; }
			auto &img = top->rootp->MOD->SIMSD;
			size_t n = fread(&img[0], 1, sizeof img, f);
			fclose(f);
			fprintf(stderr, "sim: %s in the SD card, %zu bytes of %zu\n", argv[i] + 4, n, sizeof img);
#endif
		} else if (!strncmp(argv[i], "+linger=", 8)) {
			// cycles to go on after the script's last line (for a last
			// line that takes time: reboot)
			linger = strtoull(argv[i] + 8, 0, 0);
		} else if (!strncmp(argv[i], "+sdout=", 7)) {
			sdout = argv[i] + 7;
		} else if (!strncmp(argv[i], "+type=", 6)) {
			FILE *f = fopen(argv[i] + 6, "r");
			if (!f) { perror(argv[i] + 6); return 2; }
			char line[512];
			while (fgets(line, sizeof line, f)) {
				// \e is ESC
				std::string l;
				for (char *p = line; *p; p++) {
					if (p[0] == '\\' && p[1] == 'e') { l += '\033'; p++; }
					else l += *p;
				}
				script.push_back(l);
			}
			fclose(f);
		}
	}

	std::string tail;			// the last characters printed
	size_t next = 0;			// the script line to type next
	std::string typing;			// what is left of the line being typed
	unsigned long long cyc = 0, quiet = 0, done_at = 0;
	bool armed = false;
	int vterm = 0, burst = 0;
	unsigned long long vwait = 0;

	top->clk = 0; top->rst = 1; top->rx_put = 0;
	for (int i = 0; i < 10; i++) { top->clk = !top->clk; top->eval(); }
	top->rst = 0;

	while (cyc < max && !top->poweroff && !Verilated::gotFinish()) {
		top->clk = 1; top->eval();
		top->rx_put = 0;
		if (top->tx_put) {
			putchar(top->tx_char); fflush(stdout);
			tail += (char)top->tx_char;
			if (tail.size() > 64) tail.erase(0, tail.size() - 64);
			quiet = 0;
			armed = ends(tail, "# ") || ends(tail, "$ ") || ends(tail, "login: ");
		} else {
			quiet++;
		}
		// type the next line once the prompt has stood for a while
		if (vwait && cyc > vwait) { vwait = 0; armed = true; }
		if (typing.empty() && armed && !vwait && quiet > 2000000) {
			if (next < script.size()) { typing = script[next++]; armed = false; }
			else if (!script.empty() && !done_at) done_at = cyc;
		}
		// a line "@n ..." is typed at terminal n (SIMKEYS: put straight
		// into that console's receiver, as the I/O processor would)
		if (!typing.empty() && typing[0] == '@' && typing.size() > 2 && typing[2] == ' ') {
			vterm = typing[1] - '0'; typing.erase(0, 3);
		}
		if (!typing.empty() && vterm) {
#ifdef SIMKEYS
			auto *v = top->rootp->MOD;
			if (!((v->SIMKEYS_V >> (vterm - 1)) & 1) && (cyc & 0xffff) == 0) {
				v->SIMKEYS_D[vterm - 1] = typing[0];
				v->SIMKEYS_V |= 1u << (vterm - 1);
				typing.erase(0, 1);
			}
#else
			typing.clear();
#endif
			if (typing.empty()) { vterm = 0; vwait = cyc + 40000000ULL; }
		} else if (!typing.empty() && !top->rx_busy && (burst || (cyc & 0xffff) == 0)) {
			// after an ESC the rest of the key comes at once
			if (typing[0] == '\033') burst = 1;
			else if (burst && ++burst > 3) burst = 0;
			top->rx_put = 1; top->rx_char = typing[0]; typing.erase(0, 1);
		}
#ifdef SIMNET
		{
			static std::vector<unsigned char> f;
			if (top->eth_tx_stb) f.push_back(top->eth_tx_byte);
			if (top->eth_tx_end) { net_frame(f); f.clear(); }
			top->eth_rx_go = 0;
			if (!net_out.empty() && !top->eth_rx_busy) {
				auto &o = net_out.front();
				auto &rxf = top->rootp->MOD->eth__DOT__peer->rxf;
				for (size_t i = 0; i < o.size(); i++) rxf[i] = o[i];
				top->eth_rx_len = o.size();
				top->eth_rx_go = 1;
				net_out.pop_front();
			}
		}
#endif
		if (done_at && cyc > done_at + linger) break;
		top->clk = 0; top->eval();
		cyc++;
	}
#ifdef SIMNET
	fprintf(stderr, "\nsim: the network: %u frames sent by the machine, %u ARP requests and %u pings answered\n",
		net_seen, net_arp, net_ping);
#endif
#ifdef SIMSD
	if (sdout) {
		auto &img = top->rootp->MOD->SIMSD;
		FILE *f = fopen(sdout, "wb");
		if (f) { fwrite(&img[0], 1, sizeof img, f); fclose(f); }
		fprintf(stderr, "\nsim: the SD card: %d blocks read, %d written, %d errors\n",
			top->rootp->MOD->SIMSD_RD, top->rootp->MOD->SIMSD_WR, top->rootp->MOD->SIMSD_ERR);
	}
#endif
	fprintf(stderr, "\nsim: %llu cycles, %s\n", cyc,
		top->poweroff ? "powered off" : cyc >= max ? "stopped at +max" : "script done");
	unsigned long long ir = top->rootp->MOD->MINSTRET;
	fprintf(stderr, "sim: %llu instructions, %.2f cycles each\n", ir, ir ? (double)cyc / ir : 0.0);
#ifdef SOC
	auto *m = top->rootp->MOD;
	fprintf(stderr, "sim: memory reads: %llu new blocks, %llu further words, %llu cycles\n",
		(unsigned long long)m->n_rd_new, (unsigned long long)m->n_rd_same, (unsigned long long)m->c_rd);
	fprintf(stderr, "sim: memory writes: %llu into another block, %llu into the held one, %llu cycles\n",
		(unsigned long long)m->n_wr_new, (unsigned long long)m->n_wr_same, (unsigned long long)m->c_wr);
	fprintf(stderr, "sim: memory blocks written by write combining: %llu\n", (unsigned long long)m->n_flush);
#endif
	top->final();
	delete top;
	return 0;
}
