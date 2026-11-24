/*
 * k_cache -- the Kakao SOC's cache: an instruction cache and a data
 * cache, each direct-mapped, with lines of one DDR3 block (16 bytes),
 * and the data cache written back, not through.
 *
 * Why not Zeitlos's wb_cache_one, which the SOC started with: that one
 * is a single array for instructions and data, and every store goes to
 * memory as it happens. Under Linux both cost dearly -- code and data
 * evict each other, and a store to DDR3 is a read and a write of a
 * whole block. Here a store stays in the cache until its line is
 * needed for something else, and then the line goes out as four
 * stores to one block, which Zeitlos's controller (WCOMBINE) turns
 * into one write and no read.
 *
 * The CPU's side is the port kakao32 has: a request is taken on
 * c_req && c_rdy and answered by c_ack, with the data, at the earliest
 * the next cycle; one outstanding; c_rdy is high again in the cycle a
 * fetch or load is answered from the cache (a hit). A fetch or load
 * that misses is answered when its word comes from memory, and c_rdy
 * stays low until the rest of the line has.
 *
 * What is cached is main memory, 0x8000_0000 to 0x9fff_ffff, when the
 * cache is on. Everything else, and everything while it is off, goes
 * to the bus behind as it comes (m_*, a Wishbone master, one access at
 * a time, full addresses).
 *
 * Its register is where wb_cache_one's data control was in this SOC,
 * 0x0300_0110: bit 0 turns the cache on. Turning it on empties both
 * caches first (the tag RAMs power up with anything in them); turning
 * it off throws away what the data cache had not written back, so
 * that is for memory whose contents no longer matter (kboot does it
 * before it trains the DDR3 again). It resets to off.
 *
 * Instructions and data. A line can be in both caches. So that a
 * fetch sees what was just stored: a line that the instruction cache
 * misses and the data cache holds unwritten is written back before it
 * is fetched from memory. A store to a line already in the
 * instruction cache does not change it there: that is what fence.i is
 * for (c_fencei, from the CPU: the instruction cache is emptied
 * before another request is taken), and the kernel uses it.
 *
 * The second port (p_*) is the I/O processor's way to main memory,
 * for the virtio devices' queues and buffers. It goes through the data
 * cache as the CPU's loads and stores do, so each sees what the other
 * wrote, and nothing has to be flushed or told. It is slow and polite:
 * a request waits a cycle (p_turn), then the CPU's port is not ready
 * until it is done; from the request's own address the arrays are
 * looked at a cycle later (S_PLOOK), so nothing of it is on the way
 * from the CPU's address to the arrays; and its answer is a register.
 * A request is p_req held with its address and data until p_ack; the
 * address is within main memory (bits 28..0).
 *
 * One access of the CPU's cannot wait for the second port to be done
 * the other way round: a register of a virtio slot, which the I/O
 * processor itself answers (k_virtio.v), perhaps after looking into
 * main memory. The bus says so with m_hold_i, while such an access
 * waits; then, if the second port asks, the access is put aside
 * (m_stb_o goes low; the device keeps what it has), the second port
 * is served, and the access is made again.
 */

module k_cache #(
	parameter I_KB = 16,
	parameter D_KB = 16
) (
	input         clk,
	input         rst,

	input         c_req,
	input  [31:0] c_adr,
	input         c_we,
	input   [3:0] c_sel,
	input  [31:0] c_wdat,
	input         c_instr,
	output        c_rdy,
	output        c_idle,			// nothing is under way: a request now is taken
	output        c_ack,
	output [31:0] c_rdat,
	input         c_fencei,			// one cycle: empty the instruction cache

	input         p_req,
	input  [28:0] p_adr,
	input         p_we,
	input   [3:0] p_sel,
	input  [31:0] p_wdat,
	output reg    p_ack,
	output [31:0] p_rdat,

	output reg [31:0] m_adr_o,
	output reg [31:0] m_dat_o,
	input      [31:0] m_dat_i,
	output reg        m_we_o,
	output reg  [3:0] m_sel_o,
	output reg        m_stb_o,
	input             m_ack_i,
	input             m_hold_i		// the access waits for the second port's user
);

	// sets (lines) and words, per cache; a line is four words
	localparam I_SETS = I_KB * 64;
	localparam D_SETS = D_KB * 64;
	localparam IB = $clog2(I_SETS);
	localparam DB = $clog2(D_SETS);
	// main memory is 512 MB: address bits 28..0
	localparam ITW = 25 - IB;			// tag: address bits 28 .. 4+IB
	localparam DTW = 25 - DB;

	localparam [3:0] S_IDLE = 0, S_LOOK = 1, S_WB_RD = 2, S_WB_WR = 3,
		S_FILL = 4, S_STORE = 5, S_BYP = 6, S_SWEEP = 7, S_CFG = 8, S_WB_TAG = 9,
		S_PLOOK = 10, S_RESUME = 11, S_REDO = 12;

	reg  [3:0] st;
	reg        on;					// the cache is on
	reg        i_flush;				// fence.i: empty the instruction cache next
	reg        lk_p, lk_s;			// look, for the second port; for a store of either
	reg        lk_a, lk_r;			// look, for the CPU; for a fetch or load of its
	reg        p_turn;				// the second port's request is next
	reg        r_p;					// the request in hand is the second port's
	// the CPU's access that was put aside for it
	reg        b_susp;
	reg [31:0] b_adr, b_wdat;
	reg        b_we;
	reg  [3:0] b_sel;
	// where a request ends: back to that access, if there is one
	wire [3:0] s_rest = b_susp ? S_RESUME : S_IDLE;
	reg        r_fm;				// the fetch in hand is not to hit

	// the request in hand
	reg [31:0] r_adr, r_wdat;
	reg        r_we, r_instr;
	// the fetch or load being looked up, once more: if it misses, the
	// registers above have by then moved on (see S_REDO)
	reg [31:0] q_adr;
	reg        q_instr;
	reg  [3:0] q_sel;
	reg  [3:0] r_sel;

	// ------------------------------------------------------------
	// the arrays
	// ------------------------------------------------------------

	// instruction cache: tag { valid, tag }, data
	reg [ITW:0]   i_tag [0:I_SETS-1];
	reg [31:0]    i_dat [0:I_SETS*4-1];
	reg [ITW:0]   i_tag_q;
	reg [31:0]    i_dat_q;

	// data cache: tag { valid, dirty, tag }, data in byte lanes
	reg [DTW+1:0] d_tag [0:D_SETS-1];
	reg [7:0]     d_d0 [0:D_SETS*4-1];
	reg [7:0]     d_d1 [0:D_SETS*4-1];
	reg [7:0]     d_d2 [0:D_SETS*4-1];
	reg [7:0]     d_d3 [0:D_SETS*4-1];
	reg [DTW+1:0] d_tag_q;
	reg [31:0]    d_dat_q;

	// array ports: one address each a cycle, for reading or writing
	reg  [IB-1:0]   it_a;  reg it_we;  reg [ITW:0]   it_w;
	reg  [IB+1:0]   id_a;  reg id_we;  reg [31:0]    id_w;
	reg  [DB-1:0]   dt_a;  reg dt_we;  reg [DTW+1:0] dt_w;
	reg  [DB+1:0]   dd_a;  reg [3:0] dd_we; reg [31:0] dd_w;

	always @(posedge clk) begin
		if (it_we) i_tag[it_a] <= it_w;
		i_tag_q <= i_tag[it_a];
		if (id_we) i_dat[id_a] <= id_w;
		i_dat_q <= i_dat[id_a];
		if (dt_we) d_tag[dt_a] <= dt_w;
		d_tag_q <= d_tag[dt_a];
		if (dd_we[0]) d_d0[dd_a] <= dd_w[7:0];
		if (dd_we[1]) d_d1[dd_a] <= dd_w[15:8];
		if (dd_we[2]) d_d2[dd_a] <= dd_w[23:16];
		if (dd_we[3]) d_d3[dd_a] <= dd_w[31:24];
		d_dat_q <= { d_d3[dd_a], d_d2[dd_a], d_d1[dd_a], d_d0[dd_a] };
	end

	// ------------------------------------------------------------
	// the request, and what the arrays say about it
	// ------------------------------------------------------------

	wire c_main = (c_adr[31:29] == 3'b100);
	wire c_cfg  = (c_adr[31:8] == 24'h030001);
	wire r_main = (r_adr[31:29] == 3'b100);

	wire [IB-1:0]  r_iset = r_adr[4 +: IB];
	wire [DB-1:0]  r_dset = r_adr[4 +: DB];
	wire [ITW-1:0] r_itag = r_adr[28:4+IB];
	wire [DTW-1:0] r_dtag = r_adr[28:4+DB];

	// The tags are compared on the carry chain: all ones added to the
	// difference overflows unless the difference is zero. From the tag
	// memory through the comparison to the CPU is the SOC's longest
	// path, and a tree of LUTs for it was two levels deeper.
	wire [ITW:0] i_ne = { 1'b0, i_tag_q[ITW-1:0] ^ r_itag } + { 1'b0, {ITW{1'b1}} };
	wire [DTW:0] d_ne = { 1'b0, d_tag_q[DTW-1:0] ^ r_dtag } + { 1'b0, {DTW{1'b1}} };
	wire i_hit   = i_tag_q[ITW] && !i_ne[ITW];
	wire d_valid = d_tag_q[DTW+1];
	wire d_dirty = d_tag_q[DTW];
	wire d_hit   = d_valid && !d_ne[DTW];

	// The answer to the CPU has a comparison of its own, one for both
	// caches: each bit of it takes the instruction cache's tag or the
	// data cache's, as the request is a fetch or not (the tags are
	// compared from the top, where both have the same address bits; a
	// cache that is not valid there differs in one more bit). So the
	// answer is one gate behind one carry chain, where the two caches'
	// own comparisons and a choice between them were three.
	localparam UW = (ITW > DTW) ? ITW : DTW;
	wire [UW:0] u_x;
	genvar u;
	generate
		for (u = 0; u < UW; u = u + 1) begin : ub
			wire ib = (u < ITW) ? (i_tag_q[(u < ITW) ? ITW - 1 - u : 0] ^ r_adr[28 - u]) : 1'b0;
			wire db = (u < DTW) ? (d_tag_q[(u < DTW) ? DTW - 1 - u : 0] ^ r_adr[28 - u]) : 1'b0;
			assign u_x[u] = r_instr ? ib : db;
		end
	endgenerate
	assign u_x[UW] = r_instr ? !i_tag_q[ITW] : !d_valid;
	wire [UW+1:0] u_ne = { 1'b0, u_x } + { 1'b0, {(UW+1){1'b1}} };
	wire u_hit  = !u_ne[UW+1];

	wire look   = (st == S_LOOK);
	// (lk_a and lk_r are "look, for the CPU" and "look, for a fetch or
	// a load of the CPU's" as registers, so that the answers are one
	// gate from the comparison)
	wire hit    = r_instr ? (i_hit && !r_fm) : d_hit;
	wire rd_hit = lk_r && u_hit;				// answered from the cache
	wire st_hit = lk_s && d_hit;				// a store into the cache
	wire hit_p  = lk_p && d_hit;				// the second port's, answered next cycle

	// bypass and register answers
	reg        x_ack;
	reg [31:0] x_dat;

	assign c_ack  = (lk_a && u_hit) || x_ack;
	assign c_rdat = x_ack ? x_dat : r_instr ? i_dat_q : d_dat_q;
	// a store into the cache writes the arrays this cycle, so the next
	// request waits one. After fence.i nothing is taken until the
	// instruction cache is empty; a fetch taken in fence.i's own cycle
	// is made to miss (r_fm), so it comes from memory too. (c_fencei is
	// late in its cycle, and from here back to the CPU was far too long
	// a way for it.)
	// (what is known early first, so that the comparison passes one gate)
	wire rdy_idle = !i_flush && !p_turn && (st == S_IDLE);
	wire rdy_look = !i_flush && !p_turn && lk_r;
	assign c_rdy  = rdy_idle || (rdy_look && u_hit);
	assign c_idle = rdy_idle;

	wire take = c_req && c_rdy;
	// The registers of the request in hand take the CPU's request in
	// every cycle in which one could be taken -- whether one is asked,
	// and whether the fetch or load being looked up hits, is not waited
	// for: both come late (the hit from the tag memory through the
	// comparison), and these are some seventy enables. A request not
	// asked for is never looked at. A fetch or load that misses has lost
	// its registers to whatever the CPU showed next: it is put back from
	// q_* and looked up again (S_REDO), two cycles on a miss that takes
	// dozens.
	wire r_en = rdy_idle || rdy_look;
	wire redo = look && lk_r && !u_hit;
	wire p_take = p_turn && !i_flush && (st == S_IDLE);
	assign p_rdat = x_dat;
	// ...or taken in place of the CPU's access that waits for its user
	wire p_aside = (st == S_BYP) && !m_ack_i && m_hold_i && p_turn && !r_p;

	// ------------------------------------------------------------
	// the sequencer
	// ------------------------------------------------------------

	reg  [1:0] cnt;					// the word of a line
	reg [12:0] sw;					// the set being emptied
	reg        sw_d;				// ...in the data cache too
	reg        wb_i;				// the write-back is for a fetch: the line stays
	reg [DTW-1:0] v_tag;			// the line being written back

	wire [31:0] line_adr = { 3'b100, r_adr[28:4], 4'b0000 };
	wire [31:0] v_adr    = { 3'b100, v_tag, r_dset, 4'b0000 };

	// what the arrays are asked this cycle
	always @(*) begin
		it_a = c_adr[4 +: IB];  it_we = 1'b0;  it_w = { 1'b1, r_itag };
		id_a = c_adr[2 +: IB+2]; id_we = 1'b0;  id_w = m_dat_i;
		dt_a = c_adr[4 +: DB];  dt_we = 1'b0;  dt_w = { 1'b1, 1'b0, r_dtag };
		dd_a = c_adr[2 +: DB+2]; dd_we = 4'b0000; dd_w = r_wdat;

		case (st)
			S_LOOK: begin
				if (st_hit) begin
					// the store, and the line is now unwritten
					dd_a = r_adr[2 +: DB+2]; dd_we = r_sel;
					dt_a = r_dset; dt_we = 1'b1; dt_w = { 1'b1, 1'b1, r_dtag };
				end else if (!rd_hit) begin
					// a miss: the write-back, if there is one, reads next
					dd_a = { r_dset, 2'b00 };
				end
			end
			S_PLOOK: begin
				dt_a = r_dset;
				dd_a = r_adr[2 +: DB+2];
			end
			S_REDO: begin
				it_a = q_adr[4 +: IB]; id_a = q_adr[2 +: IB+2];
				dt_a = q_adr[4 +: DB]; dd_a = q_adr[2 +: DB+2];
			end
			S_WB_RD: begin
				dd_a = { r_dset, cnt };
			end
			S_WB_WR: begin
				dd_a = { r_dset, cnt + 2'd1 };
			end
			S_WB_TAG: begin
				// written back for a fetch: still there, no longer unwritten
				dt_a = r_dset; dt_we = wb_i; dt_w = { 1'b1, 1'b0, v_tag };
			end
			S_FILL: begin
				id_a = { r_iset, cnt }; id_we = r_instr && m_ack_i;
				dd_a = { r_dset, cnt }; dd_we = {4{!r_instr && m_ack_i}}; dd_w = m_dat_i;
				it_a = r_iset; it_we = r_instr && m_ack_i && (cnt == 2'd3);
				dt_a = r_dset; dt_we = !r_instr && m_ack_i && (cnt == 2'd3);
			end
			S_STORE: begin
				// the store that missed, into the line just fetched
				dd_a = r_adr[2 +: DB+2]; dd_we = r_sel;
				dt_a = r_dset; dt_we = 1'b1; dt_w = { 1'b1, 1'b1, r_dtag };
			end
			S_SWEEP: begin
				it_a = sw[IB-1:0]; it_we = (sw < I_SETS); it_w = 0;
				dt_a = sw[DB-1:0]; dt_we = sw_d && (sw < D_SETS); dt_w = 0;
			end
			default: ;
		endcase
	end

	wire [12:0] sw_last = ((sw_d && D_SETS > I_SETS) ? D_SETS : I_SETS) - 1;

	always @(posedge clk) begin
		x_ack <= 1'b0;
		lk_p  <= 1'b0;
		lk_s  <= 1'b0;
		lk_a  <= 1'b0;
		lk_r  <= 1'b0;
		p_ack <= 1'b0;
		if (c_fencei) i_flush <= 1'b1;

		if (rst) begin
			st <= S_IDLE;
			on <= 1'b0;
			i_flush <= 1'b0;
			m_stb_o <= 1'b0;
			m_we_o <= 1'b0;
			p_turn <= 1'b0;
			r_p <= 1'b0;
			b_susp <= 1'b0;
		end else begin
			if (p_req && !p_turn && !r_p && !p_ack) p_turn <= 1'b1;

			case (st)

			S_IDLE, S_LOOK: begin
				// (S_LOOK falls to S_IDLE unless something below says otherwise)
				st <= s_rest;

				if (redo) begin
					st <= S_REDO;
				end else if (look && !hit) begin
					// a miss. For a fetch, a line the data cache holds
					// unwritten goes to memory first, and stays; for data,
					// the line in the way goes if it is unwritten.
					cnt   <= 2'd0;
					v_tag <= d_tag_q[DTW-1:0];
					wb_i  <= r_instr;
					if (r_instr ? (d_hit && d_dirty) : (d_valid && d_dirty))
						st <= S_WB_RD;
					else
						st <= S_FILL;
				end else if (i_flush && !take) begin
					i_flush <= 1'b0;
					sw <= 13'd0; sw_d <= 1'b0;
					st <= S_SWEEP;
				end

				// the second port's: answered from the cache here, as a
				// store into it is done here (st_hit, above)
				if (hit_p) begin
					p_ack <= 1'b1;
					r_p   <= 1'b0;
					x_dat <= d_dat_q;
				end

				if (p_take) begin
					r_adr <= { 3'b100, p_adr }; r_wdat <= p_wdat; r_we <= p_we;
					r_sel <= p_sel; r_instr <= 1'b0;
					r_fm <= 1'b0;
					r_p <= 1'b1;
					p_turn <= 1'b0;
					if (on)
						st <= S_PLOOK;
					else begin
						st <= S_BYP;
						m_adr_o <= { 3'b100, p_adr }; m_dat_o <= p_wdat; m_we_o <= p_we;
						m_sel_o <= p_sel; m_stb_o <= 1'b1;
					end
				end

				if (r_en) begin
					r_adr <= c_adr; r_wdat <= c_wdat; r_sel <= c_sel;
					r_we <= c_we; r_instr <= c_instr;
					r_fm <= c_instr && c_fencei;
					// (the bus's address and data too, wanted or not: which
					// it is comes late, and m_stb_o says. A read's lanes as
					// well: a device's register may change when it is read,
					// a 16550's do)
					m_adr_o <= c_adr; m_dat_o <= c_wdat; m_we_o <= c_we;
					m_sel_o <= c_sel;
				end
				if (look) begin
					q_adr <= r_adr; q_instr <= r_instr; q_sel <= r_sel;
				end
				if (take) begin
					if (c_cfg)
						st <= S_CFG;
					else if (on && c_main) begin
						st <= S_LOOK;
						lk_s <= !c_instr && c_we;
						lk_a <= !(c_instr && c_fencei);
						lk_r <= c_instr ? !c_fencei : !c_we;
					end
					else begin
						st <= S_BYP;
						m_stb_o <= 1'b1;
					end
				end
			end

			// -- the second port's request: the arrays are asked now --
			S_PLOOK: begin
				st <= S_LOOK;
				lk_p <= 1'b1;
				lk_s <= r_we;
			end

			// -- write a line back: read a word, write it, four times --
			S_WB_RD: begin
				st <= S_WB_WR;
				m_dat_o <= d_dat_q;
				m_adr_o <= v_adr | { 28'd0, cnt, 2'b00 };
				m_we_o <= 1'b1; m_sel_o <= 4'b1111; m_stb_o <= 1'b1;
			end
			S_WB_WR: begin
				// (the array is reading the next word meanwhile, and the
				// memory answers a cycle after it is asked at the earliest)
				if (m_ack_i) begin
					cnt <= cnt + 2'd1;
					m_adr_o <= v_adr | { 28'd0, cnt + 2'd1, 2'b00 };
					m_dat_o <= d_dat_q;
					if (cnt == 2'd3) begin
						m_stb_o <= 1'b0;
						st <= S_WB_TAG;
					end
				end
			end
			S_WB_TAG: begin
				cnt <= 2'd0;
				st <= S_FILL;
			end

			// -- fetch a line: four reads, into the cache it is for --
			S_FILL: begin
				if (!m_stb_o) begin
					m_adr_o <= line_adr | { 28'd0, cnt, 2'b00 };
					m_we_o <= 1'b0; m_sel_o <= 4'b1111; m_stb_o <= 1'b1;
				end else if (m_ack_i) begin
					cnt <= cnt + 2'd1;
					m_adr_o <= line_adr | { 28'd0, cnt + 2'd1, 2'b00 };
					// a fetch or load is answered as its word goes by, and
					// the CPU gets on with it while the rest arrives; a
					// store is done when the line is in
					if (cnt == r_adr[3:2]) begin
						x_dat <= m_dat_i;
						x_ack <= !r_we && !r_p;
						if (!r_we && r_p) begin p_ack <= 1'b1; r_p <= 1'b0; end
					end
					if (cnt == 2'd3) begin
						m_stb_o <= 1'b0;
						st <= r_we ? S_STORE : s_rest;
					end
				end
			end

			S_STORE: begin
				x_ack <= !r_p;
				if (r_p) begin p_ack <= 1'b1; r_p <= 1'b0; end
				st <= s_rest;
			end

			// -- everything that is not cached --
			S_BYP: begin
				if (m_ack_i) begin
					m_stb_o <= 1'b0;
					x_ack <= !r_p;
					if (r_p) begin p_ack <= 1'b1; r_p <= 1'b0; end
					x_dat <= m_dat_i;
					st <= s_rest;
				end else if (p_aside) begin
					// put aside for the second port's request
					m_stb_o <= 1'b0;
					b_susp <= 1'b1;
					b_adr <= r_adr; b_wdat <= r_wdat; b_we <= r_we; b_sel <= r_sel;
					r_adr <= { 3'b100, p_adr }; r_wdat <= p_wdat; r_we <= p_we;
					r_sel <= p_sel; r_instr <= 1'b0;
					r_fm <= 1'b0;
					r_p <= 1'b1;
					p_turn <= 1'b0;
					st <= on ? S_PLOOK : S_RESUME;	// (with the cache off there is no second port)
					if (!on) p_ack <= 1'b1;
				end
			end

			// -- the access put aside, again --
			// -- a fetch or load missed: its registers back, and look again,
			// this time for the sequencer alone (no lk_a, no lk_r: nothing
			// is answered and nothing taken) --
			S_REDO: begin
				r_adr <= q_adr; r_instr <= q_instr; r_sel <= q_sel;
				r_we <= 1'b0; r_fm <= 1'b0;
				st <= S_LOOK;
			end

			S_RESUME: begin
				r_p <= 1'b0;
				b_susp <= 1'b0;
				r_adr <= b_adr; r_wdat <= b_wdat; r_we <= b_we; r_sel <= b_sel;
				m_adr_o <= b_adr; m_dat_o <= b_wdat; m_we_o <= b_we; m_sel_o <= b_sel;
				m_stb_o <= 1'b1;
				st <= S_BYP;
			end

			// -- the register --
			S_CFG: begin
				x_ack <= 1'b1;
				x_dat <= (r_adr[7:2] == 6'd4) ? { 31'd0, on } : 32'd0;
				st <= S_IDLE;
				if (r_we && r_adr[7:2] == 6'd4 && r_sel[0]) begin
					on <= r_wdat[0];
					if (r_wdat[0] && !on) begin
						sw <= 13'd0; sw_d <= 1'b1;
						st <= S_SWEEP;
					end
				end
			end

			// -- empty the instruction cache, or both --
			S_SWEEP: begin
				sw <= sw + 13'd1;
				if (sw == sw_last) st <= s_rest;
			end

			default: st <= S_IDLE;
			endcase
		end
	end

`ifdef K_CACHE_STATS
	// what it did, for the simulation to print
	reg [63:0] n_if, n_ld, n_st, n_imiss, n_lmiss, n_smiss, n_wb, n_wbi, n_iseq, n_inext;
	reg [24:0] last_il, last_if;		// the line last missed, last fetched from
	initial begin n_iseq = 0; n_inext = 0; last_il = 0; last_if = 0; n_if = 0; n_ld = 0; n_st = 0; n_imiss = 0; n_lmiss = 0; n_smiss = 0; n_wb = 0; n_wbi = 0; end
	always @(posedge clk) begin
		if (look && r_instr) n_if <= n_if + 1;
		if (look && !r_instr && !r_we) n_ld <= n_ld + 1;
		if (look && r_we) n_st <= n_st + 1;
		if (look && !hit && r_instr) n_imiss <= n_imiss + 1;
		if (look && !hit && r_instr) last_il <= r_adr[28:4];
		if (look && r_instr) last_if <= r_adr[28:4];
		if (look && !hit && r_instr && r_adr[28:4] == last_il + 25'd1) n_iseq <= n_iseq + 1;
		if (look && !hit && r_instr && r_adr[28:4] == last_if + 25'd1) n_inext <= n_inext + 1;
		if (look && !hit && !r_instr && !r_we) n_lmiss <= n_lmiss + 1;
		if (look && !hit && r_we) n_smiss <= n_smiss + 1;
		if (st == S_WB_TAG && !wb_i) n_wb <= n_wb + 1;
		if (st == S_WB_TAG && wb_i) n_wbi <= n_wbi + 1;
	end
	final begin
		$display("k_cache: %0d fetches, %0d missed; %0d loads, %0d missed; %0d stores, %0d missed",
			n_if, n_imiss, n_ld, n_lmiss, n_st, n_smiss);
		$display("k_cache: %0d lines written back, and %0d for a fetch", n_wb, n_wbi);
		$display("k_cache: of the fetches missed, %0d were of the line after the last one missed, %0d of the line after the last one fetched from",
			n_iseq, n_inext);
	end
`endif

endmodule
