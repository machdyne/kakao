/*
 * k_port64 -- kakao64's memory port, a doubleword wide, on the cache's,
 * which is a word wide.
 *
 * A fetch, and a load or store whose byte lanes are all in one half of
 * the doubleword, is one access of the cache's. One that has lanes in
 * both halves (ld, sd, a page table entry) is two, the lower word
 * first. The answer goes to the CPU through a register (below).
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

	// the CPU
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
	input         c_idle,		// ...and nothing is under way in the cache
	input         c_ack,
	input  [31:0] c_rdat
);

	// One access at a time, and its answer through a register: the CPU
	// asks (taken when the cache is idle), the cache answers when it
	// does, and the CPU has that answer the cycle after, when it may ask
	// again. So neither the cache's answer nor its readiness, which both
	// come late out of the tag memory's comparison, goes on into the
	// CPU in the same cycle; that way round was the SOC's longest path
	// with a 64 bit CPU. It costs a cycle an access, and a fetch every
	// other cycle at best.
	//
	// 0: nothing under way; 1: an access of one word; 2: a doubleword's
	// lower word; 3: its upper word is to be asked for; 4: ...is asked for
	reg  [2:0] st;
	reg [31:0] lo;				// the lower word read
	reg [31:3] h_adr;
	reg        h_we;
	reg  [3:0] h_sel;
	reg [31:0] h_wdat;
	reg        a_v;				// the answer, for the CPU
	reg [63:0] a_dat;

	// (from the address and m_dbl, not from the lanes: they come late)
	wire up   = !m_instr && m_adr[2];			// the upper half alone
	wire idle = (st == 3'd0);
	wire hi   = (st == 3'd3);

	assign c_req   = idle ? m_req : hi;
	assign c_adr   = hi ? { h_adr, 3'b100 } : { m_adr[31:2], 2'b00 };
	assign c_we    = hi ? h_we : m_we;
	assign c_sel   = hi ? h_sel : m_instr ? 4'b1111 : up ? m_sel[7:4] : m_sel[3:0];
	assign c_wdat  = hi ? h_wdat : up ? m_wdat[63:32] : m_wdat[31:0];
	assign c_instr = idle && m_instr;

	// (c_idle, not c_rdy: nothing of ours is in the cache when st is 0,
	// so they are the same, but c_rdy has the comparison in it)
	assign m_rdy  = c_idle && idle;
	assign m_ack  = a_v;
	assign m_rdat = a_dat;

	always @(posedge clk) begin
		a_v <= 1'b0;
		if (rst) st <= 3'd0;
		else case (st)
			3'd0: if (m_req && c_idle) begin
				st     <= m_dbl ? 3'd2 : 3'd1;
				h_adr  <= m_adr[31:3];
				h_we   <= m_we;
				h_sel  <= m_sel[7:4];
				h_wdat <= m_wdat[63:32];
			end
			3'd1: if (c_ack) begin
				a_v   <= 1'b1;
				a_dat <= { c_rdat, c_rdat };
				st    <= 3'd0;
			end
			3'd2: if (c_ack) begin
				lo <= c_rdat;
				st <= 3'd3;
			end
			3'd3: if (c_rdy) st <= 3'd4;
			3'd4: if (c_ack) begin
				a_v   <= 1'b1;
				a_dat <= { c_rdat, lo };
				st    <= 3'd0;
			end
			default: st <= 3'd0;
		endcase
	end

endmodule
