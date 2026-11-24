/*
 * Kakao SOC
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
 * kakao64_cexp -- a compressed instruction (RV64C) as the 32 bit
 * instruction it stands for. Combinational.
 *
 * What has no 32 bit form comes out as 32'd0, which the decoder calls
 * illegal: the reserved encodings. The core reports the 16 bits
 * themselves when it traps.
 */

module kakao64_cexp (
	input      [15:0] c,
	output reg [31:0] i
);

	wire [4:0] rd   = c[11:7];				// also rs1
	wire [4:0] rs2  = c[6:2];
	wire [4:0] rdp  = { 2'b01, c[4:2] };		// x8..x15
	wire [4:0] rs1p = { 2'b01, c[9:7] };

	// the immediates, as the 32 bit forms want them
	wire [11:0] i_addi4  = { 2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00 };
	wire [11:0] i_lw     = { 5'd0, c[5], c[12:10], c[6], 2'b00 };
	wire [11:0] i_ld     = { 4'd0, c[6:5], c[12:10], 3'b000 };
	wire [11:0] i_imm    = { {7{c[12]}}, c[6:2] };
	wire [11:0] i_16sp   = { {3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000 };
	wire [19:0] i_lui    = { {15{c[12]}}, c[6:2] };
	wire [11:0] i_lwsp   = { 4'd0, c[3:2], c[12], c[6:4], 2'b00 };
	wire [11:0] i_ldsp   = { 3'd0, c[4:2], c[12], c[6:5], 3'b000 };
	wire [11:0] i_swsp   = { 4'd0, c[8:7], c[12:9], 2'b00 };
	wire [11:0] i_sdsp   = { 3'd0, c[9:7], c[12:10], 3'b000 };
	wire  [5:0] shamt    = { c[12], c[6:2] };
	// c.j: offset[11|4|9:8|10|6|7|3:1|5] in c[12:2]
	wire [20:0] j_off    = { {10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0 };
	// c.beqz, c.bnez: offset[8|4:3] in c[12:10], [7:6|2:1|5] in c[6:2]
	wire [12:0] b_off    = { {5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0 };

	wire [31:0] jal  = { j_off[20], j_off[10:1], j_off[11], j_off[19:12], 5'd0, 7'b1101111 };

	always @* begin
		i = 32'd0;
		case ({ c[1:0], c[15:13] })
			// ---- quadrant 0 ----
			5'b00_000:							// c.addi4spn
				if (c[12:5] != 8'd0) i = { i_addi4, 5'd2, 3'b000, rdp, 7'b0010011 };
			5'b00_001: i = { i_ld, rs1p, 3'b011, rdp, 7'b0000111 };				// c.fld
			5'b00_010: i = { i_lw, rs1p, 3'b010, rdp, 7'b0000011 };				// c.lw
			5'b00_011: i = { i_ld, rs1p, 3'b011, rdp, 7'b0000011 };				// c.ld
			5'b00_101: i = { i_ld[11:5], rdp, rs1p, 3'b011, i_ld[4:0], 7'b0100111 };	// c.fsd
			5'b00_110: i = { i_lw[11:5], rdp, rs1p, 3'b010, i_lw[4:0], 7'b0100011 };	// c.sw
			5'b00_111: i = { i_ld[11:5], rdp, rs1p, 3'b011, i_ld[4:0], 7'b0100011 };	// c.sd
			// ---- quadrant 1 ----
			5'b01_000: i = { i_imm, rd, 3'b000, rd, 7'b0010011 };				// c.addi, c.nop
			5'b01_001:							// c.addiw
				if (rd != 5'd0) i = { i_imm, rd, 3'b000, rd, 7'b0011011 };
			5'b01_010: i = { i_imm, 5'd0, 3'b000, rd, 7'b0010011 };				// c.li
			5'b01_011:
				if ({ c[12], c[6:2] } == 6'd0) i = 32'd0;
				else if (rd == 5'd2) i = { i_16sp, 5'd2, 3'b000, 5'd2, 7'b0010011 };	// c.addi16sp
				else i = { i_lui, rd, 7'b0110111 };								// c.lui
			5'b01_100:
				case (c[11:10])
					2'b00: i = { 6'b000000, shamt, rs1p, 3'b101, rs1p, 7'b0010011 };	// c.srli
					2'b01: i = { 6'b010000, shamt, rs1p, 3'b101, rs1p, 7'b0010011 };	// c.srai
					2'b10: i = { i_imm, rs1p, 3'b111, rs1p, 7'b0010011 };			// c.andi
					default:
						case ({ c[12], c[6:5] })
							3'b000: i = { 7'b0100000, rdp, rs1p, 3'b000, rs1p, 7'b0110011 };	// c.sub
							3'b001: i = { 7'b0000000, rdp, rs1p, 3'b100, rs1p, 7'b0110011 };	// c.xor
							3'b010: i = { 7'b0000000, rdp, rs1p, 3'b110, rs1p, 7'b0110011 };	// c.or
							3'b011: i = { 7'b0000000, rdp, rs1p, 3'b111, rs1p, 7'b0110011 };	// c.and
							3'b100: i = { 7'b0100000, rdp, rs1p, 3'b000, rs1p, 7'b0111011 };	// c.subw
							3'b101: i = { 7'b0000000, rdp, rs1p, 3'b000, rs1p, 7'b0111011 };	// c.addw
							default: i = 32'd0;
						endcase
				endcase
			5'b01_101: i = jal;													// c.j
			5'b01_110: i = { b_off[12], b_off[10:5], 5'd0, rs1p, 3'b000, b_off[4:1], b_off[11], 7'b1100011 };	// c.beqz
			5'b01_111: i = { b_off[12], b_off[10:5], 5'd0, rs1p, 3'b001, b_off[4:1], b_off[11], 7'b1100011 };	// c.bnez
			// ---- quadrant 2 ----
			5'b10_000: i = { 6'b000000, shamt, rd, 3'b001, rd, 7'b0010011 };		// c.slli
			5'b10_001: i = { i_ldsp, 5'd2, 3'b011, rd, 7'b0000111 };				// c.fldsp
			5'b10_010:							// c.lwsp
				if (rd != 5'd0) i = { i_lwsp, 5'd2, 3'b010, rd, 7'b0000011 };
			5'b10_011:							// c.ldsp
				if (rd != 5'd0) i = { i_ldsp, 5'd2, 3'b011, rd, 7'b0000011 };
			5'b10_100:
				if (!c[12]) begin
					if (rs2 == 5'd0) begin		// c.jr
						if (rd != 5'd0) i = { 12'd0, rd, 3'b000, 5'd0, 7'b1100111 };
					end else
						i = { 7'd0, rs2, 5'd0, 3'b000, rd, 7'b0110011 };			// c.mv
				end else begin
					if (rs2 == 5'd0) begin
						if (rd == 5'd0) i = 32'h0010_0073;						// c.ebreak
						else i = { 12'd0, rd, 3'b000, 5'd1, 7'b1100111 };			// c.jalr
					end else
						i = { 7'd0, rs2, rd, 3'b000, rd, 7'b0110011 };			// c.add
				end
			5'b10_101: i = { i_sdsp[11:5], rs2, 5'd2, 3'b011, i_sdsp[4:0], 7'b0100111 };	// c.fsdsp
			5'b10_110: i = { i_swsp[11:5], rs2, 5'd2, 3'b010, i_swsp[4:0], 7'b0100011 };	// c.swsp
			5'b10_111: i = { i_sdsp[11:5], rs2, 5'd2, 3'b011, i_sdsp[4:0], 7'b0100011 };	// c.sdsp
			default: i = 32'd0;
		endcase
	end

endmodule
