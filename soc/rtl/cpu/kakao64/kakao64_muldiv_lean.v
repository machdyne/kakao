/*
 * Zeitlos SOC
 * Copyright (c) 2026 Lone Dynamics Corporation. All rights reserved.
 *
 * Redistribution and use in source, binary or physical forms, with or
 * without modification, is permitted provided that the following
 * condition is met:
 *
 * * Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 *
 * THIS HARDWARE, SOFTWARE, DATA AND/OR DOCUMENTATION ("THE ASSETS") IS
 * PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
 * SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 * DAMAGES OR OTHER LIABILITY ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE ASSETS OR THE USE OR OTHER DEALINGS IN THE ASSETS. USE AT
 * YOUR OWN RISK.
 *
 */

/*
 * kakao64_muldiv_lean -- RV64M (the W forms are the core's: it extends the operands and
 * the result) with the same ports, the same
 * handshake and the same cycle counts as kakao64_muldiv, in less
 * logic. Selected by a core's LEAN parameter; kakao64_muldiv itself
 * is untouched.
 *
 * Where the area went in kakao64_muldiv, and what this does instead:
 *
 *   - Quotient, dividend and remainder were three registers (quot,
 *     dvnd, rem). Here they are one 64-bit shift register, acc =
 *     {remainder, dividend-then-quotient}: each step shifts the next
 *     dividend bit out of the top of the low half into the remainder
 *     and the new quotient bit into the bottom. The product (fast or
 *     sequential) lives in the same register.
 *   - The divisor and the sequential multiplicand share one register.
 *   - The sequential multiply's adder and the divide's subtractor are
 *     one adder. With FAST_MUL the sequential multiply is not built at
 *     all (kakao64_muldiv built it either way).
 *   - The result was negated by three negators (64-bit product, quotient,
 *     remainder). Here one 32-bit negator sits after the result mux:
 *     -x is ~x + 1, and the high word of a negated 64-bit product is
 *     ~hi + (lo == 0), so only the carry-in differs.
 *
 * Same states (IDLE, RUN x32, FIX) and the same divide-by-zero and
 * overflow results as kakao64_muldiv, so a core sees no difference:
 * the zeitlos32p lockstep suite compares the two write for write.
 */

module kakao64_muldiv_lean #(
	parameter [0:0] ENABLE_MUL = 1,
	parameter [0:0] ENABLE_DIV = 1,
	parameter [0:0] FAST_MUL   = 0
) (
	input             clk,
	input             rst,

	input             start,
	input       [2:0] op,			// funct3: 0-3 mul family, 4-7 div family
	input      [63:0] a,
	input      [63:0] b,

	output reg        ready,
	output     [63:0] result
);

	localparam MD_IDLE = 2'd0;
	localparam MD_RUN  = 2'd1;
	localparam MD_FIX  = 2'd2;
	localparam MD_FAST = 2'd3;

	reg [1:0]  state;
	reg [6:0]  cnt;
	reg [2:0]  op_q;
	reg [127:0] acc;			// product, or {remainder, quotient}
	reg [63:0] dsor;			// divisor, or the sequential multiplicand
	reg        neg;				// negate the result

	wire mul_a_signed = (op == 3'b001) || (op == 3'b010);	// mulh, mulhsu
	wire mul_b_signed = (op == 3'b001);						// mulh
	wire div_signed   = (op == 3'b100) || (op == 3'b110);	// div, rem
	wire is_rem       = op[2] & op[1];

	wire a_neg = (op[2] ? div_signed : mul_a_signed) && a[63];
	wire b_neg = (op[2] ? div_signed : mul_b_signed) && b[63];

	wire [63:0] a_abs = a_neg ? (~a + 64'd1) : a;
	wire [63:0] b_abs = b_neg ? (~b + 64'd1) : b;

	wire do_mul = !op[2] && ENABLE_MUL;
	wire do_div =  op[2] && ENABLE_DIV;
	wire run_mul = !op_q[2] && ENABLE_MUL && !FAST_MUL;

	// One adder for both iterative operations.
	//   divide:   {acc[63:31]} - dsor     (33-bit trial remainder)
	//   multiply: {acc[63:32]} + (acc[0] ? dsor : 0)
	wire [64:0] add_x = run_mul ? {1'b0, acc[127:64]} : acc[127:63];
	wire [64:0] add_y = run_mul ? (acc[0] ? {1'b0, dsor} : 65'd0)
	                            : ~{1'b0, dsor};
	wire [65:0] add_s = {1'b0, add_x} + {1'b0, add_y} + {65'd0, !run_mul};
	// divide: the trial is non-negative exactly when the subtraction
	// does not borrow, i.e. when the carry out of bit 32 is set
	wire        div_ge = add_s[65];

	// Fast multiply: operands registered before the DSP, as in
	// kakao64_muldiv (the product is already correctly signed).
	reg signed [64:0] fm_a;
	reg signed [64:0] fm_b;
	wire signed [129:0] fm_p;
	wire signed [64:0] fm_a_sel = $signed({mul_a_signed & a[63], a});
	wire signed [64:0] fm_b_sel = $signed({mul_b_signed & b[63], b});

	generate
		if (FAST_MUL) begin : g_fast_mul
			assign fm_p = fm_a * fm_b;
		end else begin : g_no_fast_mul
			assign fm_p = 130'd0;
		end
	endgenerate

	always @(posedge clk) begin
		if (rst) begin
			state <= MD_IDLE;
			ready <= 1'b0;
			cnt <= 7'd0;
			op_q <= 3'd0;
			neg <= 1'b0;
		end else begin
			ready <= 1'b0;
			case (state)
			MD_IDLE: begin
				if (start) begin
					op_q <= op;
					cnt <= 7'd64;
					if (do_mul) begin
						if (FAST_MUL) begin
							neg <= 1'b0;
							fm_a <= fm_a_sel;
							fm_b <= fm_b_sel;
							state <= MD_FAST;
						end else begin
							neg <= (a_neg ^ b_neg);
							acc <= {64'd0, b_abs};
							dsor <= a_abs;
							state <= MD_RUN;
						end
					end else if (do_div) begin
						// No special cases: dividing by 0 subtracts nothing, so every
						// quotient bit is 1 (0xffffffff), and the remainder is |a|,
						// which neg (a's sign) turns back into a; the quotient keeps
						// its sign (b != 0 below). -2^31 / -1: |a| = 0x8000_0000,
						// |b| = 1: quotient 0x8000_0000 (neg = 1 ^ 1), remainder 0.
						// Both as RISC-V requires; both take the full 32 steps.
						neg <= is_rem ? a_neg : ((a_neg ^ b_neg) && (b != 64'd0));
						acc <= {64'd0, a_abs};
						dsor <= b_abs;
						state <= MD_RUN;
					end
				end
			end

			MD_FAST: begin
				acc <= fm_p[127:0];
				state <= MD_FIX;
			end

			MD_RUN: begin
				if (run_mul)
					acc <= {add_s[64:0], acc[63:1]};
				else if (div_ge)
					acc <= {add_s[63:0], acc[62:0], 1'b1};
				else
					acc <= {acc[126:0], 1'b0};
				cnt <= cnt - 7'd1;
				if (cnt == 7'd1) state <= MD_FIX;
			end

			MD_FIX: begin
				state <= MD_IDLE;
				ready <= 1'b1;
			end

			default: state <= MD_IDLE;
			endcase
		end
	end

	// mul -> low word; mulh* -> high word; div/divu -> low word (the
	// quotient); rem/remu -> high word (the remainder)
	wire        hi  = op_q[2] ? op_q[1] : (op_q[1:0] != 2'b00);
	wire [63:0] sel = hi ? acc[127:64] : acc[63:0];
	// carry into the negation: +1, except the high word of a negated
	// product, which carries in only when the low word is zero
	wire        cin = (!op_q[2] && hi) ? (acc[63:0] == 64'd0) : 1'b1;

	assign result = neg ? (~sel + {63'd0, cin}) : sel;

endmodule
