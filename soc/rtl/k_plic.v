/*
 * k_plic -- the interrupt controller, as QEMU's virt machine has it
 * (sifive,plic-1.0.0), small: sources 1 to 15, priorities 0 to 7, and
 * two contexts, 0 the hart's M-mode and 1 its S-mode.
 *
 *   0x000000 + 4*n   source n's priority (0: never)
 *   0x001000         pending, a bit a source (read only)
 *   0x002000         context 0's enables, a bit a source
 *   0x002080         context 1's
 *   0x200000         context 0's threshold    0x200004  claim / complete
 *   0x201000         context 1's threshold    0x201004  claim / complete
 *
 * Sources are levels. A source that is high and not being served
 * becomes pending; a claim (a read) takes the pending, enabled source
 * of the highest priority, lowest number first, and it is then being
 * served until its number is written back.
 *
 * req is the one cycle of an access; the answer is combinational, for
 * the bus to register.
 */

module k_plic (
	input         clk,
	input         rst,

	input         req,
	input         we,
	input  [25:2] adr,
	input  [31:0] wdat,
	output reg [31:0] rdat,

	input  [15:1] src,
	output reg    irq_m,
	output reg    irq_s
);

	reg  [2:0] prio [1:15];
	reg [15:1] pend, serv;
	reg [15:1] en0, en1;
	reg  [2:0] thr0, thr1;

	// The best pending source for each context, in two steps with a
	// register between: which priority is the highest that has a
	// pending, enabled source, and which sources those are; then the
	// lowest of them. So a claim sees the state of a cycle ago, and
	// takes nothing if its source has been taken meanwhile.
	reg [15:1] m0, m1;				// the sources of the best priority
	reg  [2:0] pr0, pr1;
	reg [15:1] lv0 [1:7];
	reg [15:1] lv1 [1:7];
	reg [15:1] n0, n1;
	reg  [2:0] q0, q1;
	integer i, p;
	always @(*) begin
		for (p = 1; p <= 7; p = p + 1)
			for (i = 1; i <= 15; i = i + 1) begin
				lv0[p][i] = pend[i] && en0[i] && (prio[i] == p);
				lv1[p][i] = pend[i] && en1[i] && (prio[i] == p);
			end
		n0 = 15'd0; q0 = 3'd0; n1 = 15'd0; q1 = 3'd0;
		for (p = 1; p <= 7; p = p + 1) begin
			if (|lv0[p]) begin n0 = lv0[p]; q0 = p[2:0]; end
			if (|lv1[p]) begin n1 = lv1[p]; q1 = p[2:0]; end
		end
	end

	function [3:0] lowest(input [15:1] m);
		integer k;
		begin
			lowest = 4'd0;
			for (k = 15; k >= 1; k = k - 1) if (m[k]) lowest = k[3:0];
		end
	endfunction
	wire [3:0] id0 = lowest(m0);
	wire [3:0] id1 = lowest(m1);

	wire s_prio  = (adr[25:12] == 14'h0000);
	wire s_pend  = (adr[25:12] == 14'h0001);
	wire s_en    = (adr[25:12] == 14'h0002);
	wire s_ctx   = (adr[25:13] == 13'h0100);		// 0x200000, 0x201000
	wire ctx     = adr[12];
	wire en_ctx  = adr[7];
	wire s_claim = s_ctx && (adr[11:2] == 10'd1);
	wire s_thr   = s_ctx && (adr[11:2] == 10'd0);

	wire [3:0] claim_c  = ctx ? id1 : id0;
	wire [3:0] claim_id = (claim_c != 4'd0 && pend[claim_c]) ? claim_c : 4'd0;

	always @(*) begin
		rdat = 32'd0;
		if (s_prio && adr[11:6] == 6'd0 && adr[5:2] != 4'd0) rdat = { 29'd0, prio[adr[5:2]] };
		else if (s_pend && adr[11:2] == 10'd0) rdat = { 16'd0, pend, 1'b0 };
		else if (s_en && adr[11:8] == 4'd0 && adr[6:2] == 5'd0) rdat = { 16'd0, en_ctx ? en1 : en0, 1'b0 };
		else if (s_thr) rdat = { 29'd0, ctx ? thr1 : thr0 };
		else if (s_claim) rdat = { 28'd0, claim_id };
	end


	integer j;
	always @(posedge clk) begin
		m0 <= n0; pr0 <= q0;
		m1 <= n1; pr1 <= q1;
		irq_m <= (pr0 > thr0);
		irq_s <= (pr1 > thr1);
		if (rst) begin
			pend <= 15'd0; serv <= 15'd0; en0 <= 15'd0; en1 <= 15'd0;
			thr0 <= 3'd0; thr1 <= 3'd0;
			for (j = 1; j <= 15; j = j + 1) prio[j] <= 3'd0;
			irq_m <= 1'b0; irq_s <= 1'b0;
			m0 <= 15'd0; m1 <= 15'd0; pr0 <= 3'd0; pr1 <= 3'd0;
		end else begin
			pend <= pend | (src & ~serv);
			if (req && !we && s_claim && claim_id != 4'd0) begin
				pend[claim_id] <= 1'b0;
				serv[claim_id] <= 1'b1;
			end
			if (req && we) begin
				if (s_prio && adr[11:6] == 6'd0 && adr[5:2] != 4'd0) prio[adr[5:2]] <= wdat[2:0];
				if (s_en && adr[11:8] == 4'd0 && adr[6:2] == 5'd0) begin
					if (en_ctx) en1 <= wdat[15:1]; else en0 <= wdat[15:1];
				end
				if (s_thr) begin
					if (ctx) thr1 <= wdat[2:0]; else thr0 <= wdat[2:0];
				end
				if (s_claim && wdat[31:4] == 28'd0 && wdat[3:0] != 4'd0) serv[wdat[3:0]] <= 1'b0;
			end
		end
	end

endmodule
