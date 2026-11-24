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
 * kakao64_store / kakao64_load -- byte-lane steering for stores and
 * extraction for loads, shared by zeitlos32 and zeitlos32p.
 *
 * Both purely combinational. The bus is 64 bits wide and
 * doubleword-aligned; a store narrower than that puts its data on every
 * lane it could land on and selects the right ones with sel, and a load
 * takes the whole doubleword and picks its part back out by the
 * address's low three bits. Misalignment is the core's to detect (it raises IRQ 2
 * before anything reaches the bus), so neither module sees it.
 */

module kakao64_store (
	input   [1:0] size,		// funct3[1:0]: 0 byte, 1 half, 2 word, 3 doubleword
	input   [2:0] adr_lo,		// address bits 2:0
	input  [63:0] rs2,
	output  [7:0] sel,
	output reg [63:0] dat
);

	// the value in every lane it could go to; sel says which
	wire [7:0] m = (size == 2'd0) ? 8'h01 : (size == 2'd1) ? 8'h03 :
	               (size == 2'd2) ? 8'h0f : 8'hff;
	assign sel = m << adr_lo;

	always @* begin
		case (size)
			2'b00:   dat = {8{rs2[7:0]}};
			2'b01:   dat = {4{rs2[15:0]}};
			2'b10:   dat = {2{rs2[31:0]}};
			default: dat = rs2;
		endcase
	end

endmodule

module kakao64_load (
	input   [2:0] funct3,		// lb lh lw ld lbu lhu lwu
	input   [2:0] adr_lo,		// address bits 2:0
	input  [63:0] dword,		// the whole aligned doubleword from the bus
	output reg [63:0] out
);

	wire [63:0] s   = dword >> { adr_lo, 3'b000 };
	wire        sgn = !funct3[2];

	always @* begin
		case (funct3[1:0])
			2'b00:   out = { {56{sgn & s[7]}},  s[7:0] };
			2'b01:   out = { {48{sgn & s[15]}}, s[15:0] };
			2'b10:   out = { {32{sgn & s[31]}}, s[31:0] };
			default: out = s;
		endcase
	end

endmodule
