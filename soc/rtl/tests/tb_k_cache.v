/*
 * tb_k_cache -- k_cache against a plain memory, with random requests.
 *
 * Small caches (1 KB each) over 8 KB of main memory in four distant
 * pieces, so lines evict each other all the time; a memory that
 * answers after 0 to 3 cycles; loads, stores of every byte pattern,
 * fetches, fence.i, and now and then something outside main memory.
 * Every load must return what was last stored; every fetch, what was
 * stored before the last fence.i (a fetch of a word stored since then
 * may return either, and is not checked). Meanwhile the second port
 * loads and stores in the same memory, and each side must see what
 * the other stored. At the end the cache is read through once more,
 * word by word, against the reference.
 *
 *   make cache        (N=<requests> SEED=<n>)
 */

`timescale 1ns / 1ps

module tb_k_cache;

	parameter N = 400000;
	parameter SEED = 1;

	reg clk = 0, rst = 1;
	always #5 clk = !clk;

	reg         c_req = 0, c_we, c_instr, c_fencei = 0;
	reg  [31:0] c_adr, c_wdat;
	reg   [3:0] c_sel;
	wire        c_rdy, c_ack;
	wire [31:0] c_rdat;

	reg         p_req = 0, p_we;
	reg  [31:0] p_adr, p_wdat;
	reg   [3:0] p_sel;
	wire        p_ack;
	wire [31:0] p_rdat;
	reg  [31:0] p_exp;
	integer     n_pl, n_ps, p_idle;
	reg  [31:0] pr;

	wire [31:0] m_adr, m_dat_o;
	reg  [31:0] m_dat_i;
	wire        m_we, m_stb;
	wire  [3:0] m_sel;
	reg         m_ack = 0;

	k_cache #(.I_KB(1), .D_KB(1)) dut (
		.clk(clk), .rst(rst),
		.c_req(c_req), .c_adr(c_adr), .c_we(c_we), .c_sel(c_sel),
		.c_wdat(c_wdat), .c_instr(c_instr),
		.c_rdy(c_rdy), .c_idle(), .c_ack(c_ack), .c_rdat(c_rdat), .c_fencei(c_fencei),
		.p_req(p_req), .p_adr(p_adr[28:0]), .p_we(p_we), .p_sel(p_sel), .p_wdat(p_wdat),
		.p_ack(p_ack), .p_rdat(p_rdat),
		.m_adr_o(m_adr), .m_dat_o(m_dat_o), .m_dat_i(m_dat_i),
		.m_we_o(m_we), .m_sel_o(m_sel), .m_stb_o(m_stb), .m_ack_i(m_ack),
		.m_hold_i(m_hold)
	);

	// word index: piece (2 bits), word in piece (9 bits)
	function [10:0] widx(input [31:0] a);
		widx = { a[17:16], a[10:2] };
	endfunction

	reg [31:0] mem [0:2047];		// the memory behind
	reg [31:0] gold [0:2047];		// what the CPU should see
	reg        stale [0:2047];	// stored since the last fence.i

	integer seed, i, n_done, errors, n_ld, n_st, n_if, n_fi, n_by;
	integer m_wait;
	// an access outside main memory may be one that waits for the second
	// port's user (a virtio register): it is answered only after that
	// user has had hold_left more requests answered, and is put aside
	// for them meanwhile
	reg     acc = 0;
	integer hold_left = 0, n_held = 0, n_aside = 0;
	wire    m_hold = acc && (hold_left != 0);
	reg     m_stb_q = 0;

	// -- the memory, and the bus outside main memory --
	always @(posedge clk) begin
		m_ack <= 1'b0;
		m_stb_q <= m_stb;
		if (acc && hold_left != 0 && p_ack) hold_left = hold_left - 1;
		if (acc && m_stb_q && !m_stb && !m_ack) n_aside = n_aside + 1;
		if (m_stb && !m_ack && m_adr[31:29] != 3'b100 && !acc) begin
			acc <= 1'b1;
			if ($urandom % 3 == 0) begin hold_left = 1 + $urandom % 3; n_held = n_held + 1; end
		end else if (m_stb && !m_ack && !(m_hold && m_adr[31:29] != 3'b100)) begin
			if (m_wait != 0) m_wait <= m_wait - 1;
			else begin
				m_ack <= 1'b1;
				if (m_adr[31:29] != 3'b100) acc <= 1'b0;
				m_wait <= $urandom % 4;
				if (m_adr[31:29] == 3'b100) begin
					// (a line fetched ahead may be the one just past a piece,
					// which nothing here asks for: it is read, never written)
					if (m_adr[28:18] != 0 || m_adr[15:12] != 0 || (m_adr[11] && (m_we || m_adr[10:4] != 0))) begin
						$display("FAIL: memory address %08x", m_adr); errors = errors + 1;
					end
					m_dat_i <= mem[widx(m_adr)];
					if (m_we) begin
						if (m_sel[0]) mem[widx(m_adr)][7:0]   <= m_dat_o[7:0];
						if (m_sel[1]) mem[widx(m_adr)][15:8]  <= m_dat_o[15:8];
						if (m_sel[2]) mem[widx(m_adr)][23:16] <= m_dat_o[23:16];
						if (m_sel[3]) mem[widx(m_adr)][31:24] <= m_dat_o[31:24];
					end
				end else
					m_dat_i <= ~m_adr;
			end
		end
	end

	// -- the CPU's side --
	reg        o_v = 0;				// a request is out
	reg        o_chk;
	reg [31:0] o_exp, o_adr;
	reg        o_instr;
	reg        sweep = 0;			// the last pass
	integer    sw_i;
	reg [31:0] r;

	reg started = 0;
	integer run_n = 0;
	reg [31:0] run_a;

	task new_req;
		begin
			r = $urandom;
			if (!started) begin
				// first of all, the cache is turned on
				started <= 1;
				c_adr <= 32'h0300_0110; c_wdat <= 32'd1; c_we <= 1; c_sel <= 4'b1111;
				c_instr <= 0; c_req <= 1;
			end else if (sweep) begin
				c_adr <= { 14'h2000, sw_i[10:9], 5'd0, sw_i[8:0], 2'b00 };
				c_we <= 0; c_instr <= 0; c_sel <= 4'b1111; c_req <= (sw_i < 2048);
			end else if (run_n != 0 && r[1:0] != 0) begin
				// a run of fetches, one word after another, as code goes
				// (other requests come between them)
				run_n   <= run_n - 1;
				run_a   <= { run_a[31:11], run_a[10:2] + 9'd1, 2'b00 };
				c_adr   <= { run_a[31:11], run_a[10:2] + 9'd1, 2'b00 };
				c_instr <= 1; c_we <= 0; c_sel <= 4'b1111; c_req <= 1;
			end else if (r[3:0] < 13) begin
				if (run_n == 0 && r[31:27] == 5'd1) begin
					run_n <= 5 + r[26:22];
					run_a <= { 14'h2000, r[5:4], 5'd0, r[15:7], 2'b00 };
				end
				c_req   <= 1;
				// a few sets, so that they collide
				c_adr   <= { 14'h2000, r[5:4], 5'd0, r[6] ? r[15:7] : { 4'd0, r[11:7] }, 2'b00 };
				c_instr <= (r[18:16] < 3);
				c_we    <= !(r[18:16] < 3) && (r[21:19] < 3);
				c_sel   <= (!(r[18:16] < 3) && (r[21:19] < 3)) ?
							(r[23:22] == 0 ? 4'b1111 : r[23:22] == 1 ? (4'b0011 << {r[24],1'b0})
							: (4'b0001 << r[25:24])) : 4'b1111;
				c_wdat  <= $urandom;
				if (r[31:28] == 0) begin		// outside main memory
					c_adr <= { 4'h1, r[27:26], 24'd0, 2'b00 };
					c_instr <= 0;
				end
			end else
				c_req <= 0;
		end
	endtask

	always @(posedge clk) begin
		c_fencei <= 1'b0;
		if (rst) begin
			c_req <= 0;
		end else begin
			if (c_ack) begin
				if (!o_v) begin $display("FAIL: answer with nothing asked"); errors = errors + 1; end
				else if (o_chk && c_rdat !== o_exp) begin
					$display("FAIL: %s %08x: %08x, expected %08x (request %0d)",
						o_instr ? "fetch" : "load", o_adr, c_rdat, o_exp, n_done);
					errors = errors + 1;
				end
				o_v <= 1'b0;
				n_done = n_done + 1;
			end
			if (c_req && c_rdy) begin
				if (o_v && !c_ack) begin $display("FAIL: taken with one out"); errors = errors + 1; end
				o_v <= 1'b1; o_adr <= c_adr; o_instr <= c_instr;
				if (c_adr[31:29] != 3'b100) begin
					o_chk <= !c_we; o_exp <= ~c_adr; n_by = n_by + 1;
				end else if (c_we) begin
					o_chk <= 1'b0; n_st = n_st + 1;
					if (c_sel[0]) gold[widx(c_adr)][7:0]   = c_wdat[7:0];
					if (c_sel[1]) gold[widx(c_adr)][15:8]  = c_wdat[15:8];
					if (c_sel[2]) gold[widx(c_adr)][23:16] = c_wdat[23:16];
					if (c_sel[3]) gold[widx(c_adr)][31:24] = c_wdat[31:24];
					stale[widx(c_adr)] = 1'b1;
				end else begin
					o_chk <= !(c_instr && stale[widx(c_adr)]);
					o_exp <= gold[widx(c_adr)];
					if (c_instr) n_if = n_if + 1; else n_ld = n_ld + 1;
				end
				if (sweep && started) sw_i = sw_i + 1;
				new_req;
			end else if (!c_req)
				new_req;

			// the second port: a request is held until it is answered;
			// it counts from the cycle the cache takes it
			if (dut.p_take || dut.p_aside) begin
				if (p_we) begin
					if (p_sel[0]) gold[widx(p_adr)][7:0]   = p_wdat[7:0];
					if (p_sel[1]) gold[widx(p_adr)][15:8]  = p_wdat[15:8];
					if (p_sel[2]) gold[widx(p_adr)][23:16] = p_wdat[23:16];
					if (p_sel[3]) gold[widx(p_adr)][31:24] = p_wdat[31:24];
					stale[widx(p_adr)] = 1'b1;
				end else
					p_exp <= gold[widx(p_adr)];
			end
			if (p_ack) begin
				if (!p_req) begin $display("FAIL: second port answered with nothing asked"); errors = errors + 1; end
				else if (!p_we && p_rdat !== p_exp) begin
					$display("FAIL: second port load %08x: %08x, expected %08x", p_adr, p_rdat, p_exp);
					errors = errors + 1;
				end
				if (p_we) n_ps = n_ps + 1; else n_pl = n_pl + 1;
				p_req <= 1'b0;
				p_idle = $urandom % 40;
			end else if (!p_req && started && !(sweep && sw_i >= 2048)) begin
				if (p_idle != 0) p_idle = p_idle - 1;
				else begin
					pr = $urandom;
					p_req  <= 1'b1;
					p_adr  <= { 14'h2000, pr[5:4], 5'd0, pr[6] ? pr[15:7] : { 4'd0, pr[11:7] }, 2'b00 };
					p_we   <= pr[16];
					p_sel  <= !pr[16] ? 4'b1111 : pr[18:17] == 0 ? 4'b1111 :
						pr[18:17] == 1 ? (4'b0011 << {pr[19],1'b0}) : (4'b0001 << pr[20:19]);
					p_wdat <= $urandom;
				end
			end

			// fence.i, at any time
			if (!sweep && ($urandom % 3000) == 0) begin
				c_fencei <= 1'b1;
				n_fi = n_fi + 1;
				for (i = 0; i < 2048; i = i + 1) stale[i] = 1'b0;
			end

			if (!sweep && n_done >= N) begin sweep <= 1'b1; sw_i = 0; end
			if (sweep && sw_i == 2048 && !o_v && !c_req && !p_req) begin
				$display("%0d loads, %0d stores, %0d fetches, %0d fence.i, %0d outside (%0d held, put aside %0d times); second port %0d loads, %0d stores",
					n_ld, n_st, n_if, n_fi, n_by, n_held, n_aside, n_pl, n_ps);
				if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
				$finish;
			end
			if (errors > 20) $finish;
		end
	end

	// nothing answered for a long time: say where it stands
	integer idle_n = 0;
	always @(posedge clk) begin
		idle_n <= (c_ack || p_ack || rst) ? 0 : idle_n + 1;
		if (idle_n == 20000) begin
			$display("FAIL: stuck: st %0d p_turn %b r_p %b b_susp %b; c_req %b o_v %b; p_req %b; m_stb %b acc %b hold_left %0d sweep %b",
				dut.st, dut.p_turn, dut.r_p, dut.b_susp, c_req, o_v, p_req, m_stb, acc, hold_left, sweep);
			$finish;
		end
	end

	initial begin
		seed = SEED;
		errors = 0; n_done = 0; n_ld = 0; n_st = 0; n_if = 0; n_fi = 0; n_by = 0;
		m_wait = 0; n_pl = 0; n_ps = 0; p_idle = 5;
		for (i = 0; i < 2048; i = i + 1) begin
			mem[i] = $urandom; gold[i] = mem[i]; stale[i] = 0;
		end
		repeat (4) @(posedge clk);
		rst <= 0;
	end

endmodule
