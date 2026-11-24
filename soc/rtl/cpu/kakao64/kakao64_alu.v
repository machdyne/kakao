/*
 * Zeitlos SOC -- kakao64 ALU
 * Copyright (c) 2026 Lone Dynamics Corporation. All rights reserved.
 *
 * kakao64_alu's ports and results, plus (ENABLE_ROT) Zbb's ror, rol
 * and rori, as picorv32's ENABLE_ROT and rtl/boards.vh's `CPU_ROT.
 *
 * All the shifts are one funnel shifter: the low 32 bits of
 * {hi, lo} >> k.
 *
 *   srl, sra   hi = 0 or a's sign      lo = a   k = n
 *   ror        hi = a                  lo = a   k = n
 *   rol        hi = a                  lo = a   k = -n (mod 32)
 *   sll        hi = a                  lo = 0   k = -n (mod 32)
 *              (n = 0: lo = a, so that the result is a, not 0)
 *
 * which replaces kakao64_alu's separate left and right shifters with
 * one, slightly wider; the rotates come almost free.
 *
 * rot: the instruction is a rotate (funct7 0110000); funct3 001 is rol,
 * 101 ror/rori. The core decides whether it is legal.
 */

module kakao64_alu (
	input  [63:0] a,
	input  [63:0] b,
	input   [5:0] shamt,
	input   [2:0] funct3,
	input         sub,		// funct3 0: a - b instead of a + b
	input         sra,		// funct3 5: arithmetic shift
	input         word,		// a W instruction: on the low words, the result sign-extended
	input         cmp,		// a branch, slt or sltu: a - b (not a load/store's funct3)
	output reg [63:0] out,
	output     [63:0] add,
	output reg        taken
);

	// one adder: a + b, or a - b for sub and for everything that compares
	wire        inv  = cmp || ((funct3 == 3'b000) && sub);
	wire [64:0] sum  = {1'b0, a} + {1'b0, b ^ {64{inv}}} + {64'd0, inv};
	assign add = sum[63:0];

	wire        ltu  = !sum[64];
	wire        lt   = (a[63] ^ b[63]) ? a[63] : sum[63];
	wire        eq   = (a == b);

	// the shifts. A W shift takes the low word, extended as the shift
	// would have filled it, and five bits of the amount.
	wire  [5:0] k   = word ? { 1'b0, shamt[4:0] } : shamt;
	wire [63:0] ra  = !word ? a : sra ? { {32{a[31]}}, a[31:0] } : { 32'd0, a[31:0] };
	wire [63:0] sl  = a << k;
	wire [63:0] sr  = sra ? $unsigned($signed(ra) >>> k) : (ra >> k);

	reg [63:0] r;
	always @* begin
		case (funct3)
			3'b000:  r = sum[63:0];
			3'b001:  r = sl;
			3'b010:  r = {63'd0, lt};
			3'b011:  r = {63'd0, ltu};
			3'b100:  r = a ^ b;
			3'b101:  r = sr;
			3'b110:  r = a | b;
			default: r = a & b;
		endcase
		out = word ? { {32{r[31]}}, r[31:0] } : r;
	end

	always @* begin
		case (funct3)
			3'b000:  taken =  eq;		// beq
			3'b001:  taken = !eq;		// bne
			3'b100:  taken =  lt;		// blt
			3'b101:  taken = !lt;		// bge
			3'b110:  taken =  ltu;		// bltu
			3'b111:  taken = !ltu;		// bgeu
			default: taken = 1'b0;		// funct3 2/3 illegal
		endcase
	end

endmodule
