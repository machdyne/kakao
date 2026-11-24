/*
 * k_port64 -- kakao64's memory port, a doubleword wide, on the cache's,
 * which is a word wide.
 *
 * A fetch, and a load or store whose byte lanes are all in one half of
 * the doubleword, is one access of the cache's. One that has lanes in
 * both halves (ld, sd, a page table entry) is two, the lower word
 * first. The answer goes to the CPU through a register, and whether
 * the CPU's request is taken is a register too (below).
 *
 * This is the way to a 64 bit machine with the cache as it is, not the
 * way it should stay: a doubleword costs two accesses, and the two are
 * not one to anything else that looks at the memory in between (the
 * I/O processor) or to a device (the CLINT's mtime, which is why
 * k_clint has HOLD_HI).
 */

module k_port64 (
	input         clk,
	input         rst,

	// the CPU: up to two requests outstanding, answered in order
	input         m_req,
	input  [31:0] m_adr,
	input         m_we,
	input   [7:0] m_sel,
	input         m_dbl,		// lanes in both halves
	input  [63:0] m_wdat,
	input         m_instr,
	output        m_rdy,
	output        m_ack,
	output [63:0] m_rdat,

	// the cache
	output        c_req,
	output [31:0] c_adr,
	output        c_we,
	output  [3:0] c_sel,
	output [31:0] c_wdat,
	output        c_instr,
	input         c_rdy,
	input         c_ack,
	input  [31:0] c_rdat
);

	// The cache's answer and its readiness both come late out of the tag
	// memory's comparison, and the way from there on into the CPU in the
	// same cycle was the SOC's longest path with a 64 bit CPU. So
	// neither goes there:
	//
	// The answer goes through a register (a_*): the CPU has it the
	// cycle after the cache gave it.
	//
	// A request is taken from the CPU whenever the place for one that
	// waits (h_*) is empty, which is a register. It is shown to the
	// cache in the same cycle; if the cache takes it, well, and if not,
	// it waits in h_* and is shown from there until it is taken. A
	// doubleword waits there in any case, for its upper word.
	//
	// The cache takes a request while it answers the one before (a
	// fetch or load that hits), so on hits there is a request a cycle,
	// each answered to the CPU two cycles after it asked; the CPU has
	// two outstanding then.
	reg        hv;				// a request waits
	reg        h_hi;			// ...a doubleword's upper word
	reg [31:2] h_adr;
	reg        h_we, h_dbl, h_instr;
	reg  [7:0] h_sel;
	reg [63:0] h_wdat;

	// what the cache has, not yet answered: 0 nothing (or not ours to
	// know), 1 a word, 2 a doubleword's lower, 3 its upper
	reg  [1:0] ck;
	reg [31:0] lo;				// the lower word read
	reg        a_v;				// the answer, for the CPU
	reg [63:0] a_dat;

	// (from the address and m_dbl, not from the lanes: they come late)
	wire m_up = !m_instr && !m_dbl && m_adr[2];		// the upper half alone
	wire h_up = !h_instr && !h_dbl && h_adr[2];
	wire up   = hv ? (h_hi || h_up) : m_up;

	assign c_req   = hv || m_req;
	assign c_adr   = hv ? { h_adr[31:3], h_hi || (h_adr[2] && !h_dbl), 2'b00 } :
	                      { m_adr[31:3], m_adr[2] && !m_dbl, 2'b00 };
	assign c_we    = hv ? h_we : m_we;
	assign c_sel   = hv ? (h_instr ? 4'b1111 : up ? h_sel[7:4] : h_sel[3:0]) :
	                      (m_instr ? 4'b1111 : up ? m_sel[7:4] : m_sel[3:0]);
	assign c_wdat  = hv ? (up ? h_wdat[63:32] : h_wdat[31:0]) :
	                      (up ? m_wdat[63:32] : m_wdat[31:0]);
	assign c_instr = hv ? h_instr : m_instr;

	assign m_rdy  = !hv;
	assign m_ack  = a_v;
	assign m_rdat = a_dat;

	wire take = c_req && c_rdy;
	// the kind of what the cache is shown
	wire      x_dbl = hv ? h_dbl : m_dbl;
	wire      x_hi  = hv && h_hi;

	always @(posedge clk) begin
		a_v <= 1'b0;

		if (!hv) begin
			h_adr   <= m_adr[31:2];
			h_we    <= m_we;
			h_dbl   <= m_dbl;
			h_instr <= m_instr;
			h_sel   <= m_sel;
			h_wdat  <= m_wdat;
		end

		if (rst) begin
			hv   <= 1'b0;
			h_hi <= 1'b0;
			ck   <= 2'd0;
		end else begin
			// what waits next: the request not taken, or the upper word
			// of the doubleword whose lower word was
			if (!hv) begin
				hv   <= m_req && (!c_rdy || m_dbl);
				h_hi <= m_req && c_rdy && m_dbl;
			end else if (c_rdy) begin
				if (h_dbl && !h_hi) h_hi <= 1'b1;
				else begin hv <= 1'b0; h_hi <= 1'b0; end
			end

			if (c_ack) begin
				case (ck)
					2'd2: lo <= c_rdat;
					2'd3: begin a_v <= 1'b1; a_dat <= { c_rdat, lo }; end
					default: begin a_v <= 1'b1; a_dat <= { c_rdat, c_rdat }; end
				endcase
				ck <= 2'd0;
			end
			if (take) ck <= !x_dbl ? 2'd1 : x_hi ? 2'd3 : 2'd2;
		end
	end

endmodule
