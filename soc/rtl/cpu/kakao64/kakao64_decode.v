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
 * kakao64_decode -- kakao64's instruction decode (from zeitlos32).
 *
 *
 * Purely combinational, from one 32-bit instruction word: its fields,
 * its five immediates, one wire per instruction class, and whether the
 * whole word is legal. Nothing here knows how instructions are
 * sequenced -- the multicycle core decodes its latched instruction, the
 * pipelined core the instruction in its decode stage -- which is why
 * it is a module of its own rather than part of either core.
 *
 * What is legal: RV32IM, FENCE and FENCE.I as no-ops, the CSR
 * instructions, ecall, ebreak, mret, sret, wfi,
 * sfence.vma and the A extension. (Which CSRs exist, and what each
 * privilege may execute, is the core's to say.)
 */

module kakao64_decode #(
	parameter [0:0] ENABLE_MUL      = 1,
	parameter [0:0] ENABLE_DIV      = 1
) (
	input  [31:0] instr,

	output  [6:0] opcode,
	output  [4:0] rd_idx,
	output  [2:0] funct3,
	output  [4:0] rs1_idx,
	output  [4:0] rs2_idx,
	output  [6:0] funct7,

	output [63:0] imm_i,
	output [63:0] imm_s,
	output [63:0] imm_b,
	output [63:0] imm_u,
	output [63:0] imm_j,

	output        is_lui,
	output        is_auipc,
	output        is_jal,
	output        is_jalr,
	output        is_branch,
	output        is_load,
	output        is_store,
	output        is_opimm,
	output        is_op,
	output        is_w,			// ...or is_opimm: the W form, on words
	output        is_fence,
	output        is_system,
	output        is_custom,

	output        is_muldiv,
	output        is_amo,

	// SYSTEM: the CSR instructions (which CSRs exist, and whether this
	// one may be written, is the core's to say: csr_ok), and the four
	// that are one encoding each
	output        is_csr,
	output        is_ecall,
	output        is_ebreak,
	output        is_mret,
	output        is_sret,
	output        is_wfi,
	output        is_sfence,

	// legal, a CSR instruction's CSR aside
	output        is_legal,
	output        mem_legal		// ...and a load, a store or an atomic
);

	assign opcode  = instr[6:0];
	assign rd_idx  = instr[11:7];
	assign funct3  = instr[14:12];
	assign rs1_idx = instr[19:15];
	assign rs2_idx = instr[24:20];
	assign funct7  = instr[31:25];

	assign imm_i = {{52{instr[31]}}, instr[31:20]};
	assign imm_s = {{52{instr[31]}}, instr[31:25], instr[11:7]};
	assign imm_b =
		{{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
	assign imm_u = {{32{instr[31]}}, instr[31:12], 12'b0};
	assign imm_j =
		{{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

	assign is_lui    = (opcode == 7'b0110111);
	assign is_auipc  = (opcode == 7'b0010111);
	assign is_jal    = (opcode == 7'b1101111);
	assign is_jalr   = (opcode == 7'b1100111) && (funct3 == 3'b000);
	assign is_branch = (opcode == 7'b1100011);
	assign is_load   = (opcode == 7'b0000011);
	assign is_store  = (opcode == 7'b0100011);
	assign is_opimm  = (opcode == 7'b0010011) || (opcode == 7'b0011011);
	assign is_op     = (opcode == 7'b0110011) || (opcode == 7'b0111011);
	assign is_w      = opcode[3] && (is_op || is_opimm);
	assign is_fence  = (opcode == 7'b0001111);
	assign is_system = (opcode == 7'b1110011);
	assign is_custom = (opcode == 7'b0001011);

	wire is_mul = is_op && (funct7 == 7'b0000001) && !funct3[2];
	wire is_div = is_op && (funct7 == 7'b0000001) &&  funct3[2];
	assign is_muldiv = (is_mul && ENABLE_MUL) || (is_div && ENABLE_DIV);

	assign is_csr    = is_system && (funct3[1:0] != 2'b00);
	assign is_ecall  = (instr == 32'h0000_0073);
	assign is_ebreak = (instr == 32'h0010_0073);
	assign is_mret   = (instr == 32'h3020_0073);
	assign is_sret   = (instr == 32'h1020_0073);
	assign is_wfi    = (instr == 32'h1050_0073);
	// sfence.vma rs1, rs2
	assign is_sfence = is_system && (funct7 == 7'b0001001) && (instr[14:7] == 8'd0);

	// The A extension, words only: lr.w (rs2 zero), sc.w and the nine AMOs
	wire [4:0] funct5 = instr[31:27];
	assign is_amo = (opcode == 7'b0101111) && (funct3[2:1] == 2'b01) && (
		(funct5 == 5'b00010 && rs2_idx == 5'd0) || funct5 == 5'b00011 ||
		funct5 == 5'b00001 || funct5 == 5'b00000 || funct5 == 5'b00100 ||
		funct5 == 5'b01100 || funct5 == 5'b01000 || funct5 == 5'b10000 ||
		funct5 == 5'b10100 || funct5 == 5'b11000 || funct5 == 5'b11100);

	wire branch_legal = is_branch && (funct3 != 3'b010) && (funct3 != 3'b011);

	wire load_legal = is_load && (funct3 != 3'b111);		// lb lh lw ld lbu lhu lwu
	wire store_legal = is_store && !funct3[2];			// sb sh sw sd

	// the W forms of the multiply family: mulw only
	wire md_legal = is_muldiv && (!is_w || funct3 == 3'b000 || funct3[2]);
	wire op_legal = is_op &&
		(((funct7 == 7'b0000000) && (!is_w || funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b101)) ||
		 ((funct7 == 7'b0100000) && ((funct3 == 3'b000) || (funct3 == 3'b101))) ||
		 ((funct7 == 7'b0000001) && md_legal));
	// shift amounts have six bits, five in the W forms; addiw is the
	// only other W instruction with an immediate
	wire sh_hi0 = is_w ? (funct7 == 7'b0000000) : (instr[31:26] == 6'b000000);
	wire sh_hi1 = is_w ? (funct7 == 7'b0100000) : (instr[31:26] == 6'b010000);
	wire opimm_legal = is_opimm &&
		(((funct3 != 3'b001 && funct3 != 3'b101) && (!is_w || funct3 == 3'b000)) ||
		 ((funct3 == 3'b001) && sh_hi0) ||
		 ((funct3 == 3'b101) && (sh_hi0 || sh_hi1)));

	assign mem_legal = load_legal || store_legal || is_amo;
	assign is_legal =
		is_lui || is_auipc || is_jal || is_jalr || branch_legal ||
		load_legal || store_legal || opimm_legal || op_legal || is_fence ||
		is_amo || is_csr || is_ecall || is_ebreak || is_mret || is_sret ||
		is_wfi || is_sfence;

endmodule
