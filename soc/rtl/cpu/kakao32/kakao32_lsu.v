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
 * kakao32_store / kakao32_load -- byte-lane steering for stores and
 * extraction for loads, shared by zeitlos32 and zeitlos32p.
 *
 * Both purely combinational. The bus is 32 bits wide and word-aligned;
 * a byte or halfword store puts its data on every lane it could land
 * on and selects the right one with sel, and a load takes the whole
 * word and picks its byte or halfword back out by the address's low
 * two bits. Misalignment is the core's to detect (it raises IRQ 2
 * before anything reaches the bus), so neither module sees it.
 */

module kakao32_store (
	input   [1:0] size,		// funct3[1:0]: 0 byte, 1 half, 2 word
	input   [1:0] adr_lo,		// address bits 1:0
	input  [31:0] rs2,
	output reg  [3:0] sel,
	output reg [31:0] dat
);

	always @* begin
		case (size)
			2'b00: begin							// sb
				dat = {4{rs2[7:0]}};
				case (adr_lo)
					2'b00: sel = 4'b0001;
					2'b01: sel = 4'b0010;
					2'b10: sel = 4'b0100;
					default: sel = 4'b1000;
				endcase
			end
			2'b01: begin							// sh
				dat = {2{rs2[15:0]}};
				sel = adr_lo[1] ? 4'b1100 : 4'b0011;
			end
			default: begin							// sw
				dat = rs2;
				sel = 4'b1111;
			end
		endcase
	end

endmodule

module kakao32_load (
	input   [2:0] funct3,		// lb lh lw lbu lhu
	input   [1:0] adr_lo,		// address bits 1:0
	input  [31:0] word,		// the whole aligned word from the bus
	output [31:0] out
);

	// The word comes late (from the cache's memory, in the cycle the
	// result is registered), what to do with it is known early. So the
	// choices are made first, as numbers, and the word goes through
	// one 4-way choice for the low byte, one for the sign, and one
	// more gate for the rest.
	wire is_b = (funct3[1:0] == 2'b00);
	wire is_h = (funct3[1:0] == 2'b01);
	wire sgn  = !funct3[2];

	// which byte of the word is the result's low byte
	wire [1:0] bs = is_b ? adr_lo : is_h ? { adr_lo[1], 1'b0 } : 2'b00;
	// which byte of the word has the sign
	wire [1:0] ss = is_b ? adr_lo : { adr_lo[1], 1'b1 };
	// the result's second byte: 0 the word's second, 1 its fourth (the
	// upper half), 2 the sign, 3 zeros
	wire [1:0] ms = is_b ? { 1'b1, !sgn } : (is_h && adr_lo[1]) ? 2'b01 : 2'b00;
	// the result's upper half: 0 the word's, 2 the sign, 3 zeros
	wire [1:0] us = (is_b || is_h) ? { 1'b1, !sgn } : 2'b00;

	wire [7:0] b0 = word[7:0], b1 = word[15:8], b2 = word[23:16], b3 = word[31:24];

	wire s = ss[1] ? (ss[0] ? b3[7] : b2[7]) : (ss[0] ? b1[7] : b0[7]);

	assign out[7:0]   = bs[1] ? (bs[0] ? b3 : b2) : (bs[0] ? b1 : b0);
	assign out[15:8]  = ms[1] ? (ms[0] ? 8'd0 : {8{s}}) : (ms[0] ? b3 : b1);
	assign out[31:16] = us[1] ? (us[0] ? 16'd0 : {16{s}}) : word[31:16];

endmodule
