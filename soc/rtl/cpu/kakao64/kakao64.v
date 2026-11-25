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
 * kakao64 -- the Kakao SOC's CPU.
 *
 * RV32IMA with the privileged architecture mainline Linux needs: M, S
 * and U modes and Sv32. It began as a fork of Zeitlos's zeitlos32ps
 * and keeps its pipeline:
 *
 *   F  fetch: pc_f to the memory port; the answer goes into a
 *      four-entry instruction queue
 *   D  the queue's head: register read, with a bypass from X's write
 *   X  everything else: decode, ALU, branches and jumps, loads, stores
 *      and the atomics (X waits for the answers), multiply and divide,
 *      the CSR instructions, traps; the register write happens as X
 *      finishes
 *
 * ONE memory port for fetches, data and page-table walks: a request is
 * taken on req && rdy and answered by ack (with the data) at the
 * earliest the next cycle. Up to two may be outstanding, and they are
 * answered in the order they were taken: the fetch after the one on
 * its way, or X's load or store behind a fetch.
 * Addresses on it are physical. A walk has the port first, then a
 * load or store in X, then a fetch.
 *
 * A redirect (taken branch, jump, mret, sret, trap, and the
 * instructions that change what a fetch means: sfence.vma, fence.i, a
 * write to satp) is decided in X; fetching restarts at the target the
 * next cycle. Nothing after X can cancel anything, and X is the only
 * stage that changes architectural state.
 *
 * Traps. An interrupt is taken at the boundary before the instruction
 * in X, never once it has started. Exceptions: illegal instruction
 * (2), breakpoint (3), ecall (8, 9, 11), a misaligned load (4) or
 * store (6), a jump or taken branch to an address that is not a
 * multiple of four (0, with the epc the jump's own address), and the
 * page faults (12, 13, 15). medeleg and mideleg send them to S-mode.
 * mtvec and stvec are direct only: their low two bits read zero.
 *
 * Translation. One TLB, direct-mapped on the low bits of the virtual
 * page number, for fetches and data alike. An entry holds a 4 KB page;
 * a megapage is entered one 4 KB piece at a time. A hit needs the tag
 * and this access's permission (its kind, the effective privilege,
 * SUM, MXR, and the dirty bit for a store); anything else is a miss,
 * so a stale entry can cause a walk but never a fault. The walker
 * reads the two levels through the memory port, makes every check
 * afresh, and either enters the page or reports the fault: to X for a
 * load or store, or as a marker in the instruction queue for a fetch,
 * so that it is raised in program order (or thrown away with the rest
 * of a wrong path). The accessed and dirty bits are not written here:
 * a page whose A bit is clear, or a store to one whose D bit is clear,
 * faults, and the kernel sets the bit. sfence.vma and a write to satp
 * empty the TLB; there are no ASIDs.
 *
 * Atomics. lr.w and sc.w with one reservation, which a trap, mret and
 * sret also drop; the AMOs as a read and then a write with nothing
 * else on the port in between.
 *
 * CSRs: the M and S sets Linux and OpenSBI use; `time` reads the
 * mtime input. A CSR instruction takes two cycles: the CSR is read in
 * the first and written, with rd, in the second. wfi is a no-op.
 */

module kakao64 #(
	parameter [63:0] RESET_PC       = 64'h0000_0000_8000_0000,
	parameter [0:0]  ENABLE_MUL     = 1,
	parameter [0:0]  ENABLE_DIV     = 1,
	parameter [0:0]  FAST_MUL       = 0,
	parameter [0:0]  REGS_INIT_ZERO = 1,
	// 1: Zbb's ror, rol and rori
	parameter [0:0]  ENABLE_ROT     = 0,
	// 1: static prediction in D -- jal and backward branches are taken
	// there (the fetch is redirected as the instruction moves to X), and
	// X corrects a backward branch that is not taken. On zeitlos32ps it
	// cost about 520 cells for 4.9% fewer cycles.
	parameter [0:0]  BTFN           = 0,
	// the TLB has 2**TLB_BITS entries
	parameter        TLB_BITS       = 5,
	// translated loads and stores go out in X's first cycle when they can
	parameter [0:0]  FAST_XLATE     = 1,
	// a branch target buffer of 2^BTB_BITS entries at the fetch (0: none)
	parameter        BTB_BITS       = 6
) (
	input clk,
	input rst,

	// the memory port
	output        m_req,
	// (a doubleword wide: m_adr is physical and word aligned, m_sel has
	// the byte lanes of the doubleword it is in, and a read answers with
	// that whole doubleword; a fetch's word is the half m_adr[2] names.
	// m_dbl: the access has lanes in both halves -- for what puts this
	// port on a narrower one, rtl/k_port64.v, to know without looking
	// at the lanes)
	output [31:0] m_adr,
	output        m_dbl,
	output        m_we,
	output  [7:0] m_sel,
	output [63:0] m_wdat,
	output        m_instr,			// this request is a fetch
	input         m_rdy,
	input         m_ack,
	input  [63:0] m_rdat,

	// the CLINT's mtime, for the time CSR
	output        fencei,			// one cycle: fence.i went by

	input  [63:0] mtime,

	// the interrupt lines, level, synchronous: mip's MSIP, MTIP, MEIP,
	// and the external interrupt for S-mode (ORed into SEIP)
	input         irq_msi,
	input         irq_mti,
	input         irq_mei,
	input         irq_sei
);

	localparam [1:0] PRV_U = 2'd0, PRV_S = 2'd1, PRV_M = 2'd3;

	// ============================================================
	// state
	// ============================================================

	// fetch
	reg [63:0] pc_f;				// next address to fetch (virtual)
	reg        f_halt;				// a fetch faulted: wait for a redirect
	// The requests outstanding: up to two, answered in the order they
	// were taken (o_*0 is the older). So a fetch can be asked for while
	// the one before it is still on its way, and a load or store while
	// a fetch is.
	reg  [1:0] o_n;					// how many
	reg  [1:0] f_n;					// ...of them fetches
	reg  [1:0] o_k0, o_k1;			// what for: 0 fetch, 1 data, 2 walk
	reg        o_x0, o_x1;			// (a fetch) its answer is to be dropped
	reg        o_pt0, o_pt1;		// (a fetch) predicted taken
	reg [30:0] o_tg0, o_tg1;		// ...to here (bits 31:1)
	reg        o_po0, o_po1;		// ...by the jump that ends in the word's upper half
	reg        o_hi0, o_hi1;		// its word is the doubleword's upper half
	wire [1:0] out_k  = o_k0;
	wire       f_kill = o_x0;
	wire       fo_pt  = o_pt0;
	wire [30:0] fo_tg = o_tg0;
	wire       fo_po  = o_po0;
	wire       fo_hi  = o_hi0;
	wire       f_out  = (f_n != 2'd0);
	wire       d_ack  = m_ack && (o_k0 == 2'd1);	// X's load or store is answered

	// the instruction queue: four entries in a ring, all sequential
	// from d_pc (written at iq_wp, read at iq_rp)
	reg  [2:0] iq_cnt;
	reg  [1:0] iq_rp, iq_wp;
	reg [31:0] iq_i0, iq_i1, iq_i2, iq_i3;
	reg        iq_f0, iq_f1, iq_f2, iq_f3;	// not an instruction: its fetch page-faulted
	reg        iq_p0, iq_p1, iq_p2, iq_p3;	// predicted taken: the next entry is not at +4
	reg [30:0] iq_t0, iq_t1, iq_t2, iq_t3;	// ...but here
	reg        iq_o0, iq_o1, iq_o2, iq_o3;	// ...after the jump that ends in its upper half (or lower)
	reg [63:0] d_pc;				// address of the head

	// X
	reg        x_valid;
	reg        x_first;				// first cycle of this instruction in X
	reg [31:0] x_instr;
	reg [63:0] x_pc;
	reg        x_ff;				// the fetch-fault marker
	reg        x_ff2;				// ...for its second half
	reg        x_c;					// it was a compressed instruction
	reg [15:0] x_raw;				// ...this one
	reg        x_pt;				// D predicted it taken (BTFN) and fetched its target
	reg        x_pg;				// the BTB predicted it taken, and D found it a jump
	reg [30:0] x_ptg;				// ...to here
	reg [63:0] x_a;					// rs1, as read in D
	reg [63:0] x_b;					// rs2, as read in D
	reg        x_fa, x_fb;			// ...but take W's value instead
	reg        x_issued;			// its (current) request has been taken
	reg        x_ph;				// an AMO's second request, the write
	reg        x_pf;				// its access page-faulted
	reg [11:0] x_off;				// a load's or store's offset
	reg [63:0] x_va;				// its data address, registered for the TLB
	reg        x_vr;				// ...and valid
	reg        x_scok;				// sc.w: the reservation held (after the first cycle)
	reg [63:0] amo_a, amo_b, amo_q;	// an AMO's address, rs2, and what it read

	// W: the register write, one cycle after X
	reg        w_we;
	reg  [4:0] w_rd;
	reg [63:0] w_val;
	reg [63:0] w_pc;				// for the testbenches

	reg [63:0] regs [0:31];
	reg [63:0] fregs [0:31];		// f0..f31
	reg        w_fp;				// W writes one of those
	reg  [1:0] ms_fs;				// mstatus.FS
	reg  [4:0] fflags;
	reg  [2:0] frm;

	// the reservation
	reg        res_v;
	reg [63:2] res_a;

	// privilege and the CSRs
	reg  [1:0] priv;
	reg        ms_sie, ms_mie, ms_spie, ms_mpie, ms_spp;	// mstatus
	reg  [1:0] ms_mpp;
	reg        ms_mprv, ms_sum, ms_mxr, ms_tvm, ms_tw, ms_tsr;
	reg        ie_ssi, ie_msi, ie_sti, ie_mti, ie_sei, ie_mei;	// mie
	reg        ip_ssi, ip_sti, ip_sei;	// mip's writable bits
	reg        dl_ssi, dl_sti, dl_sei;	// mideleg
	reg [15:0] medeleg;
	reg  [2:0] mcounteren, scounteren;
	reg [63:2] mtvec, stvec;
	reg [63:0] mscratch, sscratch;
	reg [63:1] mepc, sepc;
	reg        mcause_i, scause_i;	// xcause: interrupt
	reg  [3:0] mcause_c, scause_c;	// ...and its code
	reg [63:0] mtval, stval;
	reg        satp_mode;
	reg [19:0] satp_ppn;
	reg [63:0] mcycle;
	reg [63:0] minstret;
	reg        ret_q;				// an instruction retired last cycle
	reg [63:0] csr_q;				// the CSR instruction's read
	reg        t_pend;				// a trap was found last cycle: it is taken in this one
	reg        t_s, t_irq;			// ...to S-mode; an interrupt
	reg  [3:0] t_code;
	reg [63:0] t_tval;

	// the TLB: { tag, ppn[19:0], D, U, X, W, R }
	localparam TLB_N    = 1 << TLB_BITS;
	localparam TLB_TAGW = 27 - TLB_BITS;		// of an Sv39 page number
	// (in LUTs: a larger one would otherwise be taken for block RAM, with
	// the fetch PC and the data address as its address registers)
	(* ram_style = "distributed" *)
	reg [TLB_TAGW+24:0] tlb [0:TLB_N-1];
	reg [TLB_N-1:0]     tlb_v;

	// the walker
	reg  [2:0] w_st;				// 0 idle; request/answer: 1/2 level 2, 3/4 level 1, 5/6 level 0; 7 no walk, a fault
	reg [38:0] w_va;
	reg [31:0] w_adr;
	reg  [1:0] w_type;				// 0 fetch, 1 load, 2 store
	reg  [1:0] w_prv;
	reg        w_ev;				// the entry read is in pte_r
	reg [63:0] pte_r;
	reg        w_kill;				// (a fetch's) the path it was for is gone

	integer i;
	initial begin
		if (REGS_INIT_ZERO)
			for (i = 0; i < 32; i = i + 1) regs[i] = 64'd0;
		for (i = 0; i < TLB_N; i = i + 1) tlb[i] = 0;
		for (i = 0; i < 32; i = i + 1) fregs[i] = 64'd0;
	end

	// ============================================================
	// X: decode
	// ============================================================

	wire  [6:0] opcode;
	wire  [4:0] rd_idx;
	wire  [2:0] funct3;
	wire  [4:0] rs1_idx;
	wire  [4:0] rs2_idx;
	wire  [6:0] funct7;
	wire [63:0] imm_i, imm_s, imm_b, imm_u, imm_j;
	wire is_lui, is_auipc, is_jal, is_jalr, is_branch, is_load_i, is_store_i;
	wire is_opimm, is_op, is_w, is_fence, is_system, is_custom;
	wire is_muldiv, is_amo;
	wire is_csr, is_ecall, is_ebreak, is_mret, is_sret, is_wfi, is_sfence;
	wire is_legal, mem_legal;

	kakao64_decode #(
		.ENABLE_MUL(ENABLE_MUL),
		.ENABLE_DIV(ENABLE_DIV)
	) decode_i (
		.instr(x_instr),
		.opcode(opcode), .rd_idx(rd_idx), .funct3(funct3),
		.rs1_idx(rs1_idx), .rs2_idx(rs2_idx), .funct7(funct7),
		.imm_i(imm_i), .imm_s(imm_s), .imm_b(imm_b), .imm_u(imm_u), .imm_j(imm_j),
		.is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal), .is_jalr(is_jalr),
		.is_branch(is_branch), .is_load(is_load_i), .is_store(is_store_i),
		.is_opimm(is_opimm), .is_op(is_op), .is_w(is_w), .is_fence(is_fence),
		.is_system(is_system), .is_custom(is_custom),
		.is_muldiv(is_muldiv), .is_amo(is_amo),
		.is_csr(is_csr), .is_ecall(is_ecall), .is_ebreak(is_ebreak),
		.is_mret(is_mret), .is_sret(is_sret), .is_wfi(is_wfi),
		.is_sfence(is_sfence),
		.is_legal(is_legal), .mem_legal(mem_legal)
	);

	wire is_rot = 1'b0;		// (kakao32's Zbb rotates are not carried over)

	// -- floating point: what of F and D is done here --
	// The registers, their loads and stores, the moves to and from the
	// integer registers, the sign injections, the compares and fclass.
	// The arithmetic and the conversions are illegal instructions, for the
	// SBI firmware to do (docs/kakao64.md). All of it is illegal while
	// mstatus.FS is off.
	wire fs_on    = (ms_fs != 2'd0);
	wire is_fl    = (opcode == 7'b0000111) && (funct3[2:1] == 2'b01);	// flw, fld
	wire is_fst   = (opcode == 7'b0100111) && (funct3[2:1] == 2'b01);	// fsw, fsd
	wire is_opfp  = (opcode == 7'b1010011) && !funct7[1];			// single or double
	wire fp_dbl   = funct7[0];
	wire is_fsgnj = is_opfp && (funct7[6:2] == 5'b00100) && (funct3 != 3'b011) && !funct3[2];
	wire is_fmvxf = is_opfp && (funct7[6:2] == 5'b11100) && (rs2_idx == 5'd0) && (funct3 == 3'b000);
	wire is_fclass = is_opfp && (funct7[6:2] == 5'b11100) && (rs2_idx == 5'd0) && (funct3 == 3'b001);
	wire is_fmvfx = is_opfp && (funct7[6:2] == 5'b11110) && (rs2_idx == 5'd0) && (funct3 == 3'b000);
	wire is_fcmp  = is_opfp && (funct7[6:2] == 5'b10100) && (funct3 != 3'b011) && !funct3[2];
	wire is_fphw  = is_fl || is_fst || is_fsgnj || is_fmvxf || is_fclass || is_fmvfx || is_fcmp;
	wire is_load  = is_load_i || is_fl;
	wire is_store = is_store_i || is_fst;
	// its result goes to an f register
	wire x_wfp    = is_fl || is_fsgnj || is_fmvfx;

	wire is_lr   = is_amo && (x_instr[31:27] == 5'b00010);
	wire is_sc   = is_amo && (x_instr[31:27] == 5'b00011);
	wire amo_rmw = is_amo && !is_lr && !is_sc;
	wire is_fencei = is_fence && (funct3 == 3'b001);

	// -- which CSR, and may this instruction use it --
	wire [11:0] csr_adr = x_instr[31:20];
	// csrrw always writes; csrrs and csrrc write unless rs1 (or the
	// immediate, in the same field) is zero
	wire csr_wr  = (funct3[1:0] == 2'b01) || (rs1_idx != 5'd0);
	wire csr_hpm = (csr_adr[4:0] >= 5'd3);		// counters and events 3..31
	wire csr_ucnt = (csr_adr[11:5] == 7'b1100_000);	// 0xc00..0xc1f
	wire csr_exists =
		// machine
		(csr_adr == 12'h300) || (csr_adr == 12'h301) || (csr_adr == 12'h302) ||
		(csr_adr == 12'h303) || (csr_adr == 12'h304) || (csr_adr == 12'h305) ||
		(csr_adr == 12'h306) || (csr_adr == 12'h30a) || (csr_adr == 12'h320) ||
		(csr_adr[11:5] == 7'b0011_001 && csr_hpm) ||		// 0x323..0x33f
		(csr_adr == 12'h340) || (csr_adr == 12'h341) || (csr_adr == 12'h342) ||
		(csr_adr == 12'h343) || (csr_adr == 12'h344) ||
		// mcycle, minstret, the hpm counters
		(csr_adr[11:5] == 7'b1011_000 &&
		 (csr_adr[4:0] == 5'd0 || csr_adr[4:0] == 5'd2 || csr_hpm)) ||
		(csr_adr[11:4] == 8'hf1 && csr_adr[3:0] >= 4'd1 && csr_adr[3:0] <= 4'd5) ||
		// supervisor
		(csr_adr == 12'h100) || (csr_adr == 12'h104) || (csr_adr == 12'h105) ||
		(csr_adr == 12'h106) || (csr_adr == 12'h10a) || (csr_adr == 12'h140) ||
		(csr_adr == 12'h141) || (csr_adr == 12'h142) || (csr_adr == 12'h143) ||
		(csr_adr == 12'h144) || (csr_adr == 12'h180) ||
		// user: fflags, frm, fcsr; cycle, time, instret, the hpm counters
		(fs_on && (csr_adr == 12'h001 || csr_adr == 12'h002 || csr_adr == 12'h003)) ||
		csr_ucnt;
	// cycle, time and instret below M-mode need their bit in mcounteren,
	// and in U-mode in scounteren too; the hpm counters have no bits
	wire [2:0] cnt_bit = (csr_adr[4:0] == 5'd0) ? 3'b001 :
	                     (csr_adr[4:0] == 5'd1) ? 3'b010 :
	                     (csr_adr[4:0] == 5'd2) ? 3'b100 : 3'b000;
	wire cnt_ok = (priv == PRV_M) ||
		((|(mcounteren & cnt_bit)) && (priv == PRV_S || (|(scounteren & cnt_bit))));
	wire csr_ok = csr_exists && (priv >= csr_adr[9:8]) &&
		!(csr_wr && csr_adr[11:10] == 2'b11) &&
		(!csr_ucnt || cnt_ok) &&
		!(csr_adr == 12'h180 && priv == PRV_S && ms_tvm);

	wire sys_ok =
		(!is_csr    || csr_ok) &&
		(!is_mret   || priv == PRV_M) &&
		(!is_sret   || priv == PRV_M || (priv == PRV_S && !ms_tsr)) &&
		(!is_sfence || priv == PRV_M || (priv == PRV_S && !ms_tvm)) &&
		(!is_wfi    || priv == PRV_M || !ms_tw);

	wire x_legal = !x_ff && ((is_legal && sys_ok) || is_rot || (is_fphw && fs_on));

	// ============================================================
	// X: execute
	// ============================================================

	// X's operands: as read in D, or the result of the instruction just
	// before, which is in W now (the selects are registers, set in D)
	wire [63:0] xa = x_fa ? w_val : x_a;
	wire [63:0] xb = x_fb ? w_val : x_b;

	wire [63:0] alu_b = (is_op || is_branch) ? xb : is_store ? imm_s : imm_i;
	wire  [5:0] shamt = is_op ? xb[5:0] : x_instr[25:20];

	wire [63:0] alu_out;
	wire [63:0] alu_add;
	wire        br_taken;

	kakao64_alu alu_i (
		.a(xa),
		.b(alu_b),
		.shamt(shamt),
		.funct3(funct3),
		.sub(is_op && funct7[5]),
		.sra(funct7[5]),
		.word(is_w),
		.cmp(is_branch || ((is_op || is_opimm) && funct3[2:1] == 2'b01)),
		.out(alu_out),
		.add(alu_add),
		.taken(br_taken)
	);

	wire [63:0] pc_plus4 = x_pc + (x_c ? 64'd2 : 64'd4);	// the next instruction

	// The atomics address memory at rs1 itself. X's operand registers
	// are reloaded while a request waits (d_ld_ab), so an AMO's second
	// request uses the copies made at its first.
	// A load's or store's address has an adder of its own, whose offset
	// was picked in D (x_off: the I or the S immediate; zero for an
	// atomic), so that nothing of X's decoding is in front of it.
	wire [63:0] adr_sum  = xa + { {52{x_off[11]}}, x_off };
	wire [63:0] mem_adr  = x_ph ? amo_a : adr_sum;

	wire mem_misaligned =
		(funct3[1:0] == 2'b11) ? (mem_adr[2:0] != 3'b000) :
		(funct3[1:0] == 2'b10) ? (mem_adr[1:0] != 2'b00) :
		(funct3[1:0] == 2'b01) ? (mem_adr[0]   != 1'b0)  : 1'b0;

	wire [7:0]  st_sel;
	wire [63:0] st_dat;

	kakao64_store store_i (
		.size(funct3[1:0]),
		.adr_lo(x_va[2:0]),
		.rs2(amo_rmw ? amo_res : xb),
		.sel(st_sel),
		.dat(st_dat)
	);

	wire [63:0] ld_out;

	// The load's low address bits, kept from the cycle it is taken: X's
	// operand registers are reloaded from D while it waits (d_ld_ab).
	reg  [2:0]  x_lo;

	kakao64_load load_i (
		.funct3(funct3),
		.adr_lo(x_lo),
		.dword(m_rdat),
		.out(ld_out)
	);

	wire        md_ready;
	wire [63:0] md_result;
	// the W forms: the low words, extended as the operation reads them
	// (divuw and remuw without sign), and the result's low word
	wire        md_zx = funct3[2] && funct3[0];
	wire [63:0] md_a = !is_w ? xa : { {32{!md_zx & xa[31]}}, xa[31:0] };
	wire [63:0] md_b = !is_w ? xb : { {32{!md_zx & xb[31]}}, xb[31:0] };
	wire [63:0] md_res = is_w ? { {32{md_result[31]}}, md_result[31:0] } : md_result;
	wire        md_start;

	kakao64_muldiv_lean #(
		.ENABLE_MUL(ENABLE_MUL),
		.ENABLE_DIV(ENABLE_DIV),
		.FAST_MUL(FAST_MUL)
	) muldiv_i (
		.clk(clk),
		.rst(rst),
		.start(md_start),
		.op(funct3),
		.a(md_a),
		.b(md_b),
		.ready(md_ready),
		.result(md_result)
	);

	// -- the AMOs: what is written back, from what was read and rs2 --
	wire        amo_lt  = ($signed(amo_q) < $signed(amo_b));
	wire        amo_ltu = (amo_q < amo_b);
	wire [63:0] amo_res =
		(x_instr[31:27] == 5'b00001) ? amo_b :
		(x_instr[31:27] == 5'b00000) ? (amo_q + amo_b) :
		(x_instr[31:27] == 5'b00100) ? (amo_q ^ amo_b) :
		(x_instr[31:27] == 5'b01100) ? (amo_q & amo_b) :
		(x_instr[31:27] == 5'b01000) ? (amo_q | amo_b) :
		(x_instr[31:27] == 5'b10000) ? (amo_lt  ? amo_q : amo_b) :
		(x_instr[31:27] == 5'b10100) ? (amo_lt  ? amo_b : amo_q) :
		(x_instr[31:27] == 5'b11000) ? (amo_ltu ? amo_q : amo_b) :
		                               (amo_ltu ? amo_b : amo_q);

	// sc.w succeeds if the reservation is for this address. Decided in
	// its first cycle (rs1 is not kept after that) and remembered.
	wire sc_live = res_v && (res_a == xa[63:2]);
	// (an sc takes a cycle to find that out, so that the comparison is
	// not in front of the port's request: it asks in its second cycle)
	wire sc_ok   = x_scok;

	// ============================================================
	// X: the CSRs' read side
	// ============================================================

	// bit 11 MEI, 9 SEI, 7 MTI, 5 STI, 3 MSI, 1 SSI
	wire [11:0] mip_v = { irq_mei, 1'b0, ip_sei | irq_sei, 1'b0, irq_mti, 1'b0,
	                      ip_sti, 1'b0, irq_msi, 1'b0, ip_ssi, 1'b0 };
	wire [11:0] mie_v = { ie_mei, 1'b0, ie_sei, 1'b0, ie_mti, 1'b0,
	                      ie_sti, 1'b0, ie_msi, 1'b0, ie_ssi, 1'b0 };
	wire [11:0] mdl_v = { 2'b00, dl_sei, 3'b000, dl_sti, 3'b000, dl_ssi, 1'b0 };

	// SXL and UXL are fixed at 64 bits
	wire [63:0] mstatus_r = { (ms_fs == 2'd3), 27'd0, 4'b1010, 9'd0, ms_tsr, ms_tw, ms_tvm, ms_mxr, ms_sum, ms_mprv,
		2'd0, ms_fs, ms_mpp, 2'd0, ms_spp, ms_mpie, 1'b0, ms_spie, 1'b0, ms_mie, 1'b0, ms_sie, 1'b0 };
	wire [63:0] sstatus_r = { (ms_fs == 2'd3), 29'd0, 2'b10, 12'd0, ms_mxr, ms_sum, 3'd0, ms_fs, 4'd0, ms_spp, 2'd0, ms_spie, 3'd0, ms_sie, 1'b0 };
	// RV64, A, C, D, F, I, S, U and M (D and F with the firmware's help)
	wire [63:0] misa_r    = 64'h8000_0000_0014_012d | (ENABLE_MUL ? 64'h0000_1000 : 64'h0);

	wire [63:0] minstret_r = minstret + { 63'd0, ret_q };
	wire csr_cnt = (csr_adr[11:8] == 4'hb || csr_adr[11:8] == 4'hc);
	wire [63:0] cnt_r =
		(csr_adr[4:0] == 5'd0) ? mcycle :
		(csr_adr[4:0] == 5'd1) ? mtime :
		(csr_adr[4:0] == 5'd2) ? minstret_r :
		64'd0;
	wire [63:0] csr_rd =
		csr_cnt              ? cnt_r :
		(csr_adr == 12'h001) ? { 59'd0, fflags } :
		(csr_adr == 12'h002) ? { 61'd0, frm } :
		(csr_adr == 12'h003) ? { 56'd0, frm, fflags } :
		(csr_adr == 12'h300) ? mstatus_r :
		(csr_adr == 12'h301) ? misa_r :
		(csr_adr == 12'h302) ? { 48'd0, medeleg } :
		(csr_adr == 12'h303) ? { 52'd0, mdl_v } :
		(csr_adr == 12'h304) ? { 52'd0, mie_v } :
		(csr_adr == 12'h305) ? { mtvec, 2'b00 } :
		(csr_adr == 12'h306) ? { 61'd0, mcounteren } :
		(csr_adr == 12'h340) ? mscratch :
		(csr_adr == 12'h341) ? { mepc, 1'b0 } :
		(csr_adr == 12'h342) ? { mcause_i, 59'd0, mcause_c } :
		(csr_adr == 12'h343) ? mtval :
		(csr_adr == 12'h344) ? { 52'd0, mip_v } :
		(csr_adr == 12'h100) ? sstatus_r :
		(csr_adr == 12'h104) ? { 52'd0, mie_v & mdl_v } :
		(csr_adr == 12'h105) ? { stvec, 2'b00 } :
		(csr_adr == 12'h106) ? { 61'd0, scounteren } :
		(csr_adr == 12'h140) ? sscratch :
		(csr_adr == 12'h141) ? { sepc, 1'b0 } :
		(csr_adr == 12'h142) ? { scause_i, 59'd0, scause_c } :
		(csr_adr == 12'h143) ? stval :
		(csr_adr == 12'h144) ? { 52'd0, mip_v & mdl_v } :
		(csr_adr == 12'h180) ? { satp_mode, 3'd0, 40'd0, satp_ppn } :
		64'd0;

	// the value written, from the read of the cycle before
	wire [63:0] csr_src = funct3[2] ? { 59'd0, rs1_idx } : xa;
	wire [63:0] csr_new =
		(funct3[1:0] == 2'b01) ? csr_src :
		(funct3[1:0] == 2'b10) ? (csr_q | csr_src) : (csr_q & ~csr_src);
	// SEIP: a set or clear acts on the written bit, not on the pin
	wire csr_sei =
		(funct3[1:0] == 2'b01) ? csr_src[9] :
		(funct3[1:0] == 2'b10) ? (ip_sei | csr_src[9]) : (ip_sei & ~csr_src[9]);
	wire [1:0] csr_mpp = (csr_new[12:11] == 2'd2) ? 2'd0 : csr_new[12:11];

	// ============================================================
	// X: control
	// ============================================================

	// -- interrupts: at the boundary before the instruction in X, never
	// once it has started (a load issued, a divide begun). Those not
	// delegated go to M-mode, and are on unless M-mode has MIE off;
	// the delegated ones go to S-mode, and are on in U-mode and in
	// S-mode with SIE.
	wire [11:0] pend   = mip_v & mie_v;
	wire [11:0] pend_m = pend & ~mdl_v;
	wire [11:0] pend_s = pend & mdl_v;
	wire irq_m = (|pend_m) && (priv != PRV_M || ms_mie);
	wire irq_s = (|pend_s) && (priv == PRV_U || (priv == PRV_S && ms_sie));
	wire [11:0] pend_t = irq_m ? pend_m : pend_s;
	wire [3:0] irq_code = pend_t[11] ? 4'd11 : pend_t[3] ? 4'd3 : pend_t[7] ? 4'd7 :
	                      pend_t[9]  ? 4'd9  : pend_t[1] ? 4'd1 : 4'd5;
	wire irq_take = x_valid && x_first && (irq_m || irq_s);

	wire x_go    = x_valid && !irq_take && !t_pend;	// X acts this cycle
	// (an sc.w that fails touches nothing)
	wire x_mem   = is_load || is_store || (is_amo && !is_sc) || (is_sc && !x_first && x_scok);
	wire st_type = is_store || (is_amo && !is_lr);	// it needs write access

	// One adder for everything PC-relative: auipc's result and the jal
	// and branch targets (one instruction at a time needs it).
	wire [63:0] pcrel = x_pc + (is_jal ? imm_j : is_branch ? imm_b : imm_u);

	// -- exceptions --
	wire e_ill  = !x_ff && !x_legal;
	wire e_mem  = !x_ff && x_mem && !x_issued && mem_misaligned;
	// (with C every jump's target is an instruction's address: bit 0 is
	// never set, by the encodings and by jalr)
	wire e_jmp  = 1'b0;
	wire x_bad  = x_ff || e_ill || is_ecall || is_ebreak || e_mem || e_jmp || x_pf;
	wire x_exc  = x_go && x_bad;

	wire [3:0] exc_code =
		x_ff      ? 4'd12 :
		e_ill     ? 4'd2 :
		is_ebreak ? 4'd3 :
		is_ecall  ? { 2'b10, priv } :
		e_mem     ? (st_type ? 4'd6 : 4'd4) :
		x_pf      ? (st_type ? 4'd15 : 4'd13) : 4'd0;
	wire [63:0] exc_tval =
		x_ff      ? (x_ff2 ? x_pc + 64'd2 : x_pc) :
		e_ill     ? (x_c ? { 48'd0, x_raw } : { 32'd0, x_instr }) :
		is_ebreak ? x_pc :
		is_ecall  ? 64'd0 :
		(e_mem || x_pf) ? mem_adr :
		is_jalr   ? { alu_add[63:1], 1'b0 } : pcrel;

	// A trap takes two cycles. In the first it is found (trap_now) and
	// what it needs is put into registers; X's instruction stays where
	// it is and does nothing. In the second (trap_take) the CSRs are
	// written and the fetch is redirected, from those registers. So
	// nothing of X's decoding and arithmetic is in front of the CSRs'
	// enables or the fetch's address by way of a trap.
	wire trap_now  = (irq_take || x_exc) && !t_pend;
	wire trap_take = t_pend;
	wire [3:0] trap_code = t_code;
	wire [3:0] now_code  = irq_take ? irq_code : exc_code;
	// to S-mode: from S or U, with the cause's bit set in mideleg/medeleg
	wire now_s  = (priv != PRV_M) &&
		(irq_take ? !irq_m : medeleg[exc_code]);
	wire trap_s = t_s;

	// X's load or store wants the port (written without x_bad: the
	// branch compare is in that, and this is the port's request)
	// (its own test of legality, without the privilege checks of the
	// system instructions, which are no concern of a load or store)
	wire x_mleg  = !x_ff && (mem_legal || ((is_fl || is_fst) && fs_on));
	// It wants the port (x_dw); its address is right for one (x_dwant:
	// then it is put into x_va); and, from the cycle after, it asks,
	// from that register (x_dq). So the adder, and with it the
	// operands' forwarding and what picks the offset, is a cycle away
	// from the port and from the cache behind it.
	wire x_dw    = x_go && x_mleg && x_mem && !x_issued && !x_pf;
	wire x_dwant = x_dw && !mem_misaligned;
	wire x_dq    = x_dw && x_vr;

	assign md_start = x_go && x_first && x_legal && is_muldiv;

	// X's instruction is real and legal and acts this cycle
	wire x_ok   = x_go && !x_bad;

	// ...and finishes this cycle: most at once, loads and stores on
	// their answer (an AMO on its second), multiply/divide when the
	// unit is ready, a CSR instruction in its second cycle
	// (written apart, so that what does not depend on m_ack is built
	// without it: m_ack arrives late, from the cache's tag compare)
	wire x_fin_nm = is_muldiv ? md_ready :
	                (is_csr || is_sc) ? !x_first : 1'b1;
	wire x_last = !amo_rmw || x_ph;		// this request is its last
	wire x_fin  = x_mem    ? (x_issued && d_ack && x_last) : x_fin_nm;

	wire x_retire = x_ok && x_fin;

	// Which result: the decoder's classes are mutually exclusive, so the
	// result is an AND-OR of one-hot selects rather than a priority chain
	wire s_alu  = is_opimm || (is_op && !is_muldiv);
	wire s_lui  = is_lui;
	wire s_pcr  = is_auipc;
	wire s_link = is_jal || is_jalr;
	wire s_ld   = is_load || is_lr;
	wire s_md   = is_muldiv;
	wire s_csr  = is_csr;
	wire s_amo  = amo_rmw;
	wire s_sc   = is_sc;
	wire s_fp   = is_fsgnj || is_fmvxf || is_fclass || is_fmvfx || is_fcmp;

	// a single is the low word of a register whose high word is all
	// ones; anything else there reads as the canonical NaN
	wire [31:0] fa_s = (xa[63:32] == 32'hffff_ffff) ? xa[31:0] : 32'h7fc0_0000;
	wire [31:0] fb_s = (xb[63:32] == 32'hffff_ffff) ? xb[31:0] : 32'h7fc0_0000;
	wire        sj_b = fp_dbl ? xb[63] : fb_s[31];
	wire        sj_a = fp_dbl ? xa[63] : fa_s[31];
	wire        sj   = (funct3[1:0] == 2'b00) ? sj_b : (funct3[1:0] == 2'b01) ? !sj_b : (sj_a ^ sj_b);
	// fclass
	wire        fc_s   = fp_dbl ? xa[63] : fa_s[31];
	wire        fc_e0  = fp_dbl ? (xa[62:52] == 11'd0)    : (fa_s[30:23] == 8'd0);
	wire        fc_e1  = fp_dbl ? (xa[62:52] == 11'h7ff)  : (fa_s[30:23] == 8'hff);
	wire        fc_m0  = fp_dbl ? (xa[51:0] == 52'd0)     : (fa_s[22:0] == 23'd0);
	wire        fc_q   = fp_dbl ? xa[51] : fa_s[22];
	wire  [9:0] fclass = {
		fc_e1 && !fc_m0 && fc_q,				// 9: a quiet NaN
		fc_e1 && !fc_m0 && !fc_q,				// 8: a signaling NaN
		!fc_s && fc_e1 && fc_m0,				// 7: +infinity
		!fc_s && !fc_e0 && !fc_e1,				// 6: positive, normal
		!fc_s && fc_e0 && !fc_m0,				// 5: positive, subnormal
		!fc_s && fc_e0 && fc_m0,				// 4: +0
		fc_s && fc_e0 && fc_m0,					// 3: -0
		fc_s && fc_e0 && !fc_m0,				// 2: negative, subnormal
		fc_s && !fc_e0 && !fc_e1,				// 1: negative, normal
		fc_s && fc_e1 && fc_m0 };				// 0: -infinity
	// feq, flt, fle: both operands as sign and magnitude. Nothing is
	// equal to or ordered with a NaN; the two zeros are equal. Invalid:
	// a signaling NaN for feq, any NaN for the others.
	wire        fb_e1  = fp_dbl ? (xb[62:52] == 11'h7ff) : (fb_s[30:23] == 8'hff);
	wire        fb_m0  = fp_dbl ? (xb[51:0] == 52'd0)    : (fb_s[22:0] == 23'd0);
	wire        fb_q   = fp_dbl ? xb[51] : fb_s[22];
	wire        fa_nan = fc_e1 && !fc_m0, fb_nan = fb_e1 && !fb_m0;
	wire [62:0] fa_mag = fp_dbl ? xa[62:0] : { 32'd0, fa_s[30:0] };
	wire [62:0] fb_mag = fp_dbl ? xb[62:0] : { 32'd0, fb_s[30:0] };
	wire        f_zz   = (fa_mag == 63'd0) && (fb_mag == 63'd0);
	wire        f_eq   = ((sj_a == sj_b) && (fa_mag == fb_mag)) || f_zz;
	wire        f_mlt  = (fa_mag < fb_mag);
	wire        f_lt   = (sj_a != sj_b) ? (sj_a && !f_zz) :
	                     (!f_eq && (sj_a ? !f_mlt : f_mlt));
	wire        f_cmp  = !(fa_nan || fb_nan) &&
		((funct3[1:0] == 2'b10) ? f_eq : (funct3[1:0] == 2'b01) ? f_lt : (f_lt || f_eq));
	wire        f_nv   = (funct3[1:0] == 2'b10) ? ((fa_nan && !fc_q) || (fb_nan && !fb_q))
	                                           : (fa_nan || fb_nan);
	wire [63:0] fp_out =
		is_fcmp   ? { 63'd0, f_cmp } :
		is_fsgnj  ? (fp_dbl ? { sj, xa[62:0] } : { 32'hffff_ffff, sj, fa_s[30:0] }) :
		is_fclass ? { 54'd0, fclass } :
		is_fmvxf  ? (fp_dbl ? xa : { {32{xa[31]}}, xa[31:0] }) :
		            (fp_dbl ? xa : { 32'hffff_ffff, xa[31:0] });

	wire x_we = x_ok && x_fin &&
		(s_alu || s_lui || s_pcr || s_link || s_ld || s_md || s_csr || s_amo || s_sc || s_fp);

	// (the load's result is the last to arrive: it joins at the end)
	wire [63:0] x_wdat_e =
		({64{s_alu}}  & alu_out)     | ({64{s_lui}}  & imm_u)     |
		({64{s_pcr}}  & pcrel)       | ({64{s_link}} & pc_plus4)  |
		({64{s_md}}   & md_res)      |
		({64{s_csr}}  & csr_q)       | ({64{s_amo}}  & amo_q)     |
		({64{s_sc}}   & { 63'd0, !sc_ok })   | ({64{s_fp}}   & fp_out);
	// (a single in an f register has ones above it)
	wire [63:0] x_wdat = !s_ld ? x_wdat_e :
		(is_fl && !funct3[0]) ? { 32'hffff_ffff, ld_out[31:0] } : ld_out;

	// a write to satp, in the CSR instruction's last cycle
	wire csr_we   = x_ok && is_csr && !x_first && csr_wr;
	wire satp_we  = csr_we && (csr_adr == 12'h180);
	wire tlb_flush = satp_we || (x_ok && is_sfence);

	// Redirects: a trap, a jump, a taken branch, mret and sret, and
	// what changes the meaning of the fetches behind it
	// The fetch has already gone where a jal or taken branch goes when
	// D sent it there (x_pt) or the BTB did and D found it right (x_pg);
	// then a branch that is not taken has to turn it back. Either flag
	// is only ever set on a jal or branch (D sees to the BTB's other
	// mistakes itself, d_fix), so these are all one-cycle instructions:
	// X redirects in an instruction's last cycle and no other, which
	// d_go relies on.
	wire x_tk   = is_jal || (is_branch && br_taken);
	// (the BTB's target is in the 4 GB the jump is in)
	wire x_tgok = (pcrel[31:1] == x_ptg) && (pcrel[63:32] == x_pc[63:32]);
	wire r_pcr  = x_ok && x_tk && !x_pt && !(x_pg && x_tgok);
	wire r_nt   = x_ok && !x_tk && (x_pt || x_pg);
	wire r_jalr = x_ok && is_jalr;
	wire r_mret = x_ok && is_mret;
	wire r_sret = x_ok && is_sret;
	wire r_next = (x_ok && (is_sfence || is_fencei)) || satp_we;
	assign fencei = x_ok && is_fencei;

	wire x_redir = trap_take || r_pcr || r_jalr || r_mret || r_sret || r_nt || r_next;

	wire [63:0] x_target =
		({64{trap_take}} & { (trap_s ? stvec : mtvec), 2'b00 }) |
		({64{r_pcr}}     & pcrel)                  |
		({64{r_jalr}}    & { alu_add[63:1], 1'b0 }) |
		({64{r_mret}}    & { mepc, 1'b0 })         |
		({64{r_sret}}    & { sepc, 1'b0 })         |
		({64{r_nt || r_next}} & pc_plus4);

	// X is free for the next instruction at the next edge
	wire x_free = !x_valid || x_retire || trap_take;

	// The same, but with "a load or store has been taken" counting as
	// free: from then on X no longer reads its operand registers (the
	// cache has the address and data, the load formatter has x_lo, an
	// AMO its own copies), so D may write them in every such cycle
	// while it waits. The last write is in the cycle D really moves
	// (d_go), so they end up the same -- but their enable no longer
	// waits for m_ack, which is the critical path's end (tag RAM ->
	// hit -> ack -> d_go -> x_a).
	wire x_free_ab = !x_valid || irq_take || (x_mem && x_issued) ||
	                 (x_go && x_bad) ||
	                 (x_go && !x_mem && x_fin_nm);

	// ============================================================
	// D: the queue's head, register read with a bypass from X
	// ============================================================

	// The queue holds words; instructions are 16 or 32 bits and begin at
	// either half of one. D's instruction is at d_pc: in the head word
	// (w0), or begun in its upper half and ended in the next word (w1).
	wire [1:0]  iq_r1 = iq_rp + 2'd1;
	wire [31:0] w0 = iq_rp[1] ? (iq_rp[0] ? iq_i3 : iq_i2) : (iq_rp[0] ? iq_i1 : iq_i0);
	wire        w0_f = iq_rp[1] ? (iq_rp[0] ? iq_f3 : iq_f2) : (iq_rp[0] ? iq_f1 : iq_f0);
	wire        w0_p = iq_rp[1] ? (iq_rp[0] ? iq_p3 : iq_p2) : (iq_rp[0] ? iq_p1 : iq_p0);
	wire        w0_o = iq_rp[1] ? (iq_rp[0] ? iq_o3 : iq_o2) : (iq_rp[0] ? iq_o1 : iq_o0);
	wire [30:0] w0_t = iq_rp[1] ? (iq_rp[0] ? iq_t3 : iq_t2) : (iq_rp[0] ? iq_t1 : iq_t0);
	wire [31:0] w1 = iq_r1[1] ? (iq_r1[0] ? iq_i3 : iq_i2) : (iq_r1[0] ? iq_i1 : iq_i0);
	wire        w1_f = iq_r1[1] ? (iq_r1[0] ? iq_f3 : iq_f2) : (iq_r1[0] ? iq_f1 : iq_f0);
	wire        w1_p = iq_r1[1] ? (iq_r1[0] ? iq_p3 : iq_p2) : (iq_r1[0] ? iq_p1 : iq_p0);
	wire        w1_o = iq_r1[1] ? (iq_r1[0] ? iq_o3 : iq_o2) : (iq_r1[0] ? iq_o1 : iq_o0);
	wire [30:0] w1_t = iq_r1[1] ? (iq_r1[0] ? iq_t3 : iq_t2) : (iq_r1[0] ? iq_t1 : iq_t0);

	wire        d_off  = d_pc[1];
	wire [15:0] d_p16  = d_off ? w0[31:16] : w0[15:0];
	wire        d_c    = (d_p16[1:0] != 2'b11) && !w0_f;
	wire        d_span = d_off && !d_c && !w0_f;		// it ends in w1
	wire [31:0] d_cx;
	kakao64_cexp cexp_i (.c(d_p16), .i(d_cx));

	wire        d_valid = (iq_cnt != 3'd0) && (!d_span || (iq_cnt[2:1] != 2'd0));
	wire [31:0] d_instr = d_c ? d_cx : d_span ? { w1[15:0], w0[31:16] } : w0;
	wire        d_ff2   = d_span && w1_f;			// the fetch of its second half faulted
	wire        d_ff    = w0_f || d_ff2;
	// The fetch followed a prediction after the word in which a jump
	// ends (iq_p), in the half iq_o says. It is D's instruction that
	// was predicted when it ends just there.
	wire        d_end1  = d_span ? 1'b0 : (d_off || !d_c);	// the half it ends in
	wire        d_ptw0  = !d_span && w0_p && (w0_o == d_end1);
	wire        d_ptw1  = d_span && !w0_p && w1_p && !w1_o;
	wire        d_pt    = d_ptw0 || d_ptw1;
	wire [30:0] d_ptg   = d_span ? w1_t : w0_t;
	// ...and when D's instruction goes past the end of a word after
	// which the fetch went elsewhere, without being what was predicted
	// there, the prediction was wrong (code has changed under the BTB)
	wire        d_past  = w0_p && !d_ptw0 && (d_span || d_end1);
	// the words D's instruction uses up
	wire        d_pop1  = d_span || d_end1;
	wire  [4:0] d_rs1   = d_instr[19:15];
	wire  [4:0] d_rs2   = d_instr[24:20];
	// (the same as x_we with a register to write, but put so that the
	// memory's answer, which comes last, is one gate from the end)
	wire x_res = (s_alu || s_lui || s_pcr || s_link || s_ld || s_md || s_csr || s_amo || s_sc || s_fp) &&
		(rd_idx != 5'd0 || x_wfp);
	(* keep *) wire x_wr_m = x_ok && x_res && x_mem && x_issued && x_last;	// ...when the answer comes
	(* keep *) wire x_wr_n = x_ok && x_res && !x_mem && x_fin_nm;
	wire        x_wr    = (d_ack && x_wr_m) || x_wr_n;

	// the register file as of the next edge: W writes at this one, so its
	// value is taken directly (a register, not X's result logic)
	// which file each is read from: the f registers for a floating-point
	// operation's operands (but not what fmv.d.x and the conversions from
	// integers take), and for what fsw and fsd store
	// the offset of a load or store (stores: 0100011 and, for the f
	// registers, 0100111; an atomic, 0101111, has none)
	wire        d_isst = (d_instr[6:3] == 4'b0100) && (d_instr[1:0] == 2'b11);
	wire [11:0] d_ofs  = (d_instr[6:0] == 7'b0101111) ? 12'd0 :
	                     d_isst ? { d_instr[31:25], d_instr[11:7] } : d_instr[31:20];
	wire d_opfp = (d_instr[6:0] == 7'b1010011);
	wire d_fr1  = d_opfp && (d_instr[31:28] != 4'b1111) && (d_instr[31:28] != 4'b1101);
	wire d_fr2  = d_opfp || (d_instr[6:0] == 7'b0100111);
	wire [63:0] d_a = (!d_fr1 && d_rs1 == 5'd0) ? 64'd0 :
	                  (w_we && w_rd == d_rs1 && w_fp == d_fr1) ? w_val :
	                  d_fr1 ? fregs[d_rs1] : regs[d_rs1];
	wire [63:0] d_b = (!d_fr2 && d_rs2 == 5'd0) ? 64'd0 :
	                  (w_we && w_rd == d_rs2 && w_fp == d_fr2) ? w_val :
	                  d_fr2 ? fregs[d_rs2] : regs[d_rs2];

	// ...and the instruction leaving X now writes W next: forward it then
	wire d_fa = x_wr && (rd_idx == d_rs1) && (x_wfp == d_fr1) && (d_fr1 || d_rs1 != 5'd0);
	wire d_fb = x_wr && (rd_idx == d_rs2) && (x_wfp == d_fr2) && (d_fr2 || d_rs2 != 5'd0);

	// d_go is the enable of most of X's registers, and m_ack -- late, from
	// the cache's tag compare -- is in it only while X waits for its last
	// answer (x_wack). Then nothing else can hold X (no interrupt is
	// taken once an access is out, no redirect comes from a load or
	// store), so d_go is D's readiness and m_ack. Built as one final
	// select on m_ack, kept apart, so that m_ack passes one LUT before
	// the fan-out rather than the whole retire logic.
	wire d_go_full = d_valid && !d_bad && x_free && !x_redir;	// reference
	(* keep *) wire x_wack  = x_valid && x_mem && x_issued && x_last;
	(* keep *) wire d_go_w  = d_valid && !d_bad;
	(* keep *) wire d_go_n  = d_valid && !d_bad && !x_redir &&
		(!x_valid ||
		 (x_go && !x_bad && !x_mem && x_fin_nm));
	wire d_go = x_wack ? (d_go_w && d_ack) : d_go_n;
	// copies of it for the wide register groups, so that no one net
	// fans out to all of them (the tools do not duplicate it themselves)
	(* keep *) wire d_go_i = x_wack ? (d_go_w && d_ack) : d_go_n;	// x_instr

	// BTFN: D's instruction is a jal or a backward branch, so fetch its
	// target now. Only when X is not waiting for an answer (then d_go is
	// d_go_n, which has no m_ack in it, and the fetch PC's enable stays
	// off the critical path); otherwise X redirects as without BTFN.
	wire        d_isbr  = (d_instr[6:0] == 7'b1100011);
	wire        d_isjal = (d_instr[6:0] == 7'b1101111);
	wire        d_pred  = BTFN && !d_ff && (d_isjal || (d_isbr && d_instr[31]));
	wire [63:0] d_imm   = d_isjal ?
		{ {44{d_instr[31]}}, d_instr[19:12], d_instr[20], d_instr[30:21], 1'b0 } :
		{ {52{d_instr[31]}}, d_instr[7], d_instr[30:25], d_instr[11:8], 1'b0 };
	wire [63:0] d_tgt   = d_pc + d_imm;
	wire        d_red   = BTFN && d_pred && !d_pt && !x_wack && d_go_n;
	// the BTB's prediction for D's instruction is right in kind and
	// place: it is a jal or a branch, and that is where it goes
	// (only in kind here: that the target is the right one is X's to
	// check, x_tgok, where the target is computed anyway. An adder and a
	// comparison behind the expander were the SOC's longest path.)
	wire        d_pg    = d_pt && !d_ff && (d_isjal || d_isbr);
	// ...or it is not (the BTB finds its entries by a part of the
	// address, and code changes under it): then the instruction stays
	// in D for a cycle while what was fetched behind it is thrown away
	// and the fetch goes on from the address after it, as if nothing
	// had been predicted
	wire        d_bad   = d_valid && ((d_pt && !d_pg) || d_past);
	// (the wrong prediction is the second word's when D's instruction
	// ends there; then both words stay)
	wire        d_fix2  = d_span && !w0_p;
	wire [63:0] d_wpc   = { d_pc[63:2], 2'b00 };
	wire        d_fix   = d_bad && !x_redir;
	(* keep *) wire d_go_p = x_wack ? (d_go_w && d_ack) : d_go_n;	// x_pc
	// (checked in every simulation, also those that build as for
	// synthesis: Verilator defines VERILATOR)
`ifndef SYNTHESIS
`define KAKAO32_CHECK
`endif
`ifdef VERILATOR
`define KAKAO32_CHECK
`endif
`ifdef KAKAO32_CHECK
	always @(posedge clk)
		if (!rst && (d_go !== d_go_full)) begin
			$display("kakao64: d_go %b != reference %b at pc %016x", d_go, d_go_full, x_pc);
			$finish;
		end
`endif
	// Nor do they need D to be valid or the instruction to survive: when
	// X is free, whatever is written is either the instruction that moves
	// to X (the last write then is its d_go cycle) or nothing that X will
	// read. So the enable has no branch compare (x_redir) in it.
	wire d_ld_ab = x_free_ab;

	// ============================================================
	// the branch target buffer: where the fetch goes next
	// ============================================================

	// Without it every jal and taken branch costs the two or three
	// cycles from X's redirect to the target's arrival in X -- a quarter
	// of Dhrystone's cycles. Each entry is a jump's address (a part of
	// it: BTB_TAG bits above the index) and its target; the fetch of an
	// address that has an entry is followed by the fetch of the target.
	// Entries are made by jals and taken branches as X meets them, and
	// unmade by a prediction that was wrong. Nothing here is trusted:
	// D checks that the instruction is a jal or branch to that target,
	// X that a branch is taken, and whatever else was predicted is
	// redirected as if nothing had been. A jalr is not predicted.
	localparam BTB_W   = (BTB_BITS != 0) ? BTB_BITS : 1;
	localparam BTB_TAG = 10;
	// (valid, tag, the half of the word the jump ends in, target[31:1])
	reg [BTB_TAG+32:0] btb [0:(1<<BTB_W)-1];
	reg                bt_we;
	reg [BTB_W-1:0]    bt_wa;
	reg [BTB_TAG+32:0] bt_wd;
	integer bt_i;
	initial for (bt_i = 0; bt_i < (1 << BTB_W); bt_i = bt_i + 1) btb[bt_i] = 0;
	always @(posedge clk) if (bt_we) btb[bt_wa] <= bt_wd;

	wire [BTB_TAG+32:0] bt_e   = btb[pc_f[2 +: BTB_W]];
	wire                bt_hit = (BTB_BITS != 0) && bt_e[BTB_TAG+32] &&
		(bt_e[32 +: BTB_TAG] == pc_f[2+BTB_W +: BTB_TAG]);
	wire                bt_po  = bt_e[31];
	wire [30:0]         bt_tg  = bt_e[30:0];
	// where X's jump ends: the word the BTB knows it by
	wire [63:0]         x_end  = x_c ? x_pc : x_pc + 64'd2;

	// ============================================================
	// the port: who asks, and translation
	// ============================================================

	// room for a fetch's answer: the queue plus what is in flight stays
	// at 4, a test on registers alone
	wire f_room = ({1'b0, iq_cnt} + {2'b0, f_n}) < 4'd4;
	wire w_busy = (w_st != 3'd0);
	wire f_want = f_room && !rst && !f_halt && !x_dw;

	// the effective privilege of X's data access
	wire [1:0] d_prv = (priv == PRV_M && ms_mprv) ? ms_mpp : priv;

	// Two lookups side by side, each with a registered address: the
	// fetch PC, and X's data address a cycle after the adder made it
	// (x_va). So a translated load or store takes a cycle more, and
	// neither the adder nor the choice between the two (x_dwant, with
	// the interrupt test in it) is in front of the TLB read and its
	// compare. Untranslated, the address goes to the port as before.
	wire        d_xl    = satp_mode && (d_prv != PRV_M);
	wire        f_xl    = satp_mode && (priv != PRV_M);
	wire  [1:0] d_type  = st_type ? 2'd2 : 2'd1;
	// X's data address is ready for the lookup

	// May this access use a page with these bits? (U, X, W, R, and for a
	// store D; the walker tests A before it calls this)
	function perm_ok;
		input [1:0] kind;		// 0 fetch, 1 load, 2 store
		input [1:0] prv;
		input       sum, mxr;
		input       d, u, x, w, r;
		reg         uok;
		begin
			uok = u ? (prv == PRV_U || (prv == PRV_S && sum && kind != 2'd0))
			        : (prv != PRV_U);
			perm_ok = uok && (
				(kind == 2'd0) ? x :
				(kind == 2'd1) ? (r || (mxr && x)) :
				                 (w && d));
		end
	endfunction

	// an Sv39 address is 39 bits, sign-extended: anything else has no
	// translation (a page fault, which the walker raises without a walk)
	function canon;
		input [63:0] va;
		canon = (va[63:39] == {25{va[38]}});
	endfunction

	wire [TLB_BITS-1:0]  dk_idx = x_va[12 +: TLB_BITS];
	wire [TLB_TAGW+24:0] dk_e   = tlb[dk_idx];
	wire d_hit = tlb_v[dk_idx] &&
		(dk_e[TLB_TAGW+24:25] == x_va[38:12+TLB_BITS]) && canon(x_va) &&
		perm_ok(d_type, d_prv, ms_sum, ms_mxr, dk_e[4], dk_e[3], dk_e[2], dk_e[1], dk_e[0]);
	wire d_ok = !d_xl || d_hit;

	wire [TLB_BITS-1:0]  fk_idx = pc_f[12 +: TLB_BITS];
	wire [TLB_TAGW+24:0] fk_e   = tlb[fk_idx];
	wire f_hit = tlb_v[fk_idx] &&
		(fk_e[TLB_TAGW+24:25] == pc_f[38:12+TLB_BITS]) && canon(pc_f) &&
		perm_ok(2'd0, priv, ms_sum, ms_mxr, fk_e[4], fk_e[3], fk_e[2], fk_e[1], fk_e[0]);
	wire f_ok = !f_xl || f_hit;

	// A third lookup, with the base register, while the adder adds:
	// when the entry for the base's page is there and allows the
	// access, and the offset does not leave the page, the access goes
	// out in X's first cycle after all. An offset is under 2048 either
	// way, so the page is another one exactly when bit 12 comes out of
	// the adder changed; that one bit is all of the adder that is in
	// front of the request. Everything else -- another page, no entry,
	// no permission, the second half of an AMO -- is for the registered
	// lookup a cycle later, as before.
	wire [TLB_BITS-1:0]  bk_idx = xa[12 +: TLB_BITS];
	wire [TLB_TAGW+24:0] bk_e   = tlb[bk_idx];
	wire bk_hit = tlb_v[bk_idx] &&
		(bk_e[TLB_TAGW+24:25] == xa[38:12+TLB_BITS]) && canon(xa) &&
		perm_ok(d_type, d_prv, ms_sum, ms_mxr, bk_e[4], bk_e[3], bk_e[2], bk_e[1], bk_e[0]);
	// (the lookup with the base register, bk_*, is not used: it put the
	// request in the adder's cycle. FAST_XLATE has no effect.)

	wire [31:0] d_pa =
		d_xl ? { dk_e[24:5], x_va[11:2], 2'b00 } : { x_va[31:2], 2'b00 };
	wire [31:0] f_pa = f_xl ? { fk_e[24:5], pc_f[11:2], 2'b00 } : { pc_f[31:2], 2'b00 };

	wire x_dreq  = x_dq && d_ok && !w_busy;
	wire f_req   = f_want  && f_ok && !w_busy;
	wire w_d     = x_dq && !d_ok;		// a walk for X's access
	wire w_start = (w_d || (f_want && !f_ok && !f_out)) && !w_busy;
	wire w_req   = (w_st == 3'd1) || (w_st == 3'd3) || (w_st == 3'd5);
	// what the walk is for
	wire [63:0] lk_va   = x_dq ? x_va : pc_f;
	wire  [1:0] lk_prv  = x_dq ? d_prv : priv;
	wire  [1:0] lk_type = x_dq ? d_type : 2'd0;

	wire d_we = is_store || is_sc || (amo_rmw && x_ph);

	assign m_req   = w_req || x_dreq || f_req;
	assign m_adr   = w_req ? w_adr : x_dq ? d_pa : f_pa;
	assign m_we    = x_dreq && d_we;
	// (a load's lanes too: a device register may change when it is read)
	assign m_sel   = x_dreq ? st_sel : 8'hff;
	assign m_wdat  = st_dat;
	assign m_instr = f_req;
	assign m_dbl   = w_req || (x_dq && funct3[1:0] == 2'b11);

	wire taken   = m_req && m_rdy;
	wire f_taken = f_req && m_rdy;
	wire f_ack   = m_ack && (out_k == 2'd0);		// a fetch answered
	wire w_ack   = m_ack && (out_k == 2'd2);		// a walk's read answered

	// -- the walker's verdict on the entry it has just read --
	// (it is looked at the cycle after it arrives, w_ev: from the cache's
	// data to the TLB's write enable was the longest path in the SOC)
	wire [63:0] pte    = pte_r;
	// a fetch's answer: its half of the doubleword
	wire [31:0] f_word = fo_hi ? m_rdat[63:32] : m_rdat[31:0];
	// (the reserved bits must be zero; so must the page number's bits
	// above the 4 GB there is, which ought to be an access fault and is
	// a page fault here)
	wire pte_bad  = !pte[0] || (!pte[1] && pte[2]) || (pte[63:30] != 34'd0);
	wire pte_leaf = pte[1] || pte[3];
	// the level of the entry read: 2 (a gigapage if a leaf), 1 (a
	// megapage), 0
	wire w_l2     = (w_st == 3'd2);
	wire w_l1     = (w_st == 3'd4);
	wire w_l0     = (w_st == 3'd6);
	wire w_nc     = (w_st == 3'd7);		// the address is not canonical
	wire pte_perm = pte[6] &&
		perm_ok(w_type, w_prv, ms_sum, ms_mxr, pte[7], pte[4], pte[3], pte[2], pte[1]);
	// a superpage whose low PPN bits are set is misaligned
	wire pte_mis  = (w_l2 && pte[27:10] != 18'd0) || (w_l1 && pte[18:10] != 9'd0);
	wire w_fault  = (w_ev && (pte_bad ||
		(pte_leaf ? (!pte_perm || pte_mis) : w_l0))) || w_nc;
	wire w_fill   = w_ev && !pte_bad && pte_leaf && !w_fault;
	wire w_next   = w_ev && !pte_bad && !pte_leaf && !w_l0;
	wire [19:0] w_ppn = w_l2 ? { pte[29:28], w_va[29:12] } :
	                    w_l1 ? { pte[29:19], w_va[20:12] } : pte[29:10];
	wire w_fetch  = (w_type == 2'd0);
	// a fetch's fault goes into the queue, unless its path is gone
	wire f_fault  = w_fault && w_fetch && !w_kill && !x_redir && !d_red && !d_fix;

	wire f_push  = (f_ack && !f_kill) || f_fault;

	// ============================================================
	// the clocked part
	// ============================================================

	always @(posedge clk) begin
		mcycle <= mcycle + 64'd1;

		if (rst) begin
			pc_f <= RESET_PC;
			d_pc <= RESET_PC;
			f_halt <= 1'b0;
			o_n <= 2'd0;
			f_n <= 2'd0;
			o_k0 <= 2'd0; o_k1 <= 2'd0;
			o_x0 <= 1'b0; o_x1 <= 1'b0;
			bt_we <= 1'b0;
			iq_cnt <= 3'd0;
			iq_rp <= 2'd0;
			iq_wp <= 2'd0;
			x_valid <= 1'b0;
			x_first <= 1'b0;
			x_issued <= 1'b0;
			x_ph <= 1'b0;
			x_pf <= 1'b0;
			x_vr <= 1'b0;
			x_ff <= 1'b0;
			x_pt <= 1'b0;
			x_pg <= 1'b0;
			x_scok <= 1'b0;
			w_we <= 1'b0;
			x_fa <= 1'b0;
			x_fb <= 1'b0;
			res_v <= 1'b0;
			priv <= PRV_M;
			ms_sie <= 1'b0; ms_mie <= 1'b0; ms_spie <= 1'b0; ms_mpie <= 1'b0;
			ms_spp <= 1'b0; ms_mpp <= 2'd0;
			ms_mprv <= 1'b0; ms_sum <= 1'b0; ms_mxr <= 1'b0;
			ms_tvm <= 1'b0; ms_tw <= 1'b0; ms_tsr <= 1'b0;
			ms_fs <= 2'd0; fflags <= 5'd0; frm <= 3'd0; w_fp <= 1'b0;
			ie_ssi <= 1'b0; ie_msi <= 1'b0; ie_sti <= 1'b0;
			ie_mti <= 1'b0; ie_sei <= 1'b0; ie_mei <= 1'b0;
			ip_ssi <= 1'b0; ip_sti <= 1'b0; ip_sei <= 1'b0;
			dl_ssi <= 1'b0; dl_sti <= 1'b0; dl_sei <= 1'b0;
			medeleg <= 16'd0;
			mcounteren <= 3'd0; scounteren <= 3'd0;
			mtvec <= 62'd0; stvec <= 62'd0;
			mscratch <= 64'd0; sscratch <= 64'd0;
			mepc <= 63'd0; sepc <= 63'd0;
			mcause_i <= 1'b0; mcause_c <= 4'd0;
			scause_i <= 1'b0; scause_c <= 4'd0;
			mtval <= 64'd0; stval <= 64'd0;
			satp_mode <= 1'b0; satp_ppn <= 20'd0;
			mcycle <= 64'd0;
			minstret <= 64'd0;
			ret_q <= 1'b0;
			t_pend <= 1'b0;
			tlb_v <= {TLB_N{1'b0}};
			w_st <= 3'd0;
			w_ev <= 1'b0;
			w_kill <= 1'b0;
		end else begin

			// -- the port --------------------------------------------
			// (the older goes when it is answered; the new one is the
			// only one then, or else the younger)
			if (m_ack) begin
				o_k0 <= o_k1; o_x0 <= o_x1; o_pt0 <= o_pt1;
				o_tg0 <= o_tg1; o_po0 <= o_po1; o_hi0 <= o_hi1;
			end
			if (taken) begin
				if (o_n == {1'b0, m_ack}) begin
					o_k0 <= w_req ? 2'd2 : x_dreq ? 2'd1 : 2'd0; o_x0 <= 1'b0;
					o_pt0 <= bt_hit; o_tg0 <= bt_tg; o_po0 <= bt_po; o_hi0 <= pc_f[2];
				end else begin
					o_k1 <= w_req ? 2'd2 : x_dreq ? 2'd1 : 2'd0; o_x1 <= 1'b0;
					o_pt1 <= bt_hit; o_tg1 <= bt_tg; o_po1 <= bt_po; o_hi1 <= pc_f[2];
				end
			end
			o_n <= o_n + {1'b0, taken} - {1'b0, m_ack};
			f_n <= f_n + {1'b0, f_taken} - {1'b0, f_ack};
			// a redirect: every fetch still to come back is from the old
			// path, the one taken in this cycle too
			if (x_redir || d_red || d_fix) begin
				o_x0 <= 1'b1; o_x1 <= 1'b1;
			end
`ifndef SYNTHESIS
			if (taken && o_n == 2'd2 && !m_ack) begin
				$display("kakao64: a third request outstanding"); $finish;
			end
`endif

			// -- retire ------------------------------------------------
			// (an instruction that writes either half of minstret does
			// not count itself: what it wrote is what the next one reads)
			// Counted a cycle late (ret_q), so that the counter's enable is
			// not at the end of the path from the cache's answer; a read
			// in between adds the one still owed (minstret_r).
			ret_q <= x_retire && !(csr_we && csr_adr == 12'hb02);
			if (ret_q) minstret <= minstret + 64'd1;

			// -- X -----------------------------------------------------
			t_pend <= trap_now;
			if (trap_now) begin
				t_s    <= now_s;
				t_irq  <= irq_take;
				t_code <= now_code;
				t_tval <= irq_take ? 64'd0 : exc_tval;
			end
			if (trap_take) begin
				res_v <= 1'b0;
				if (trap_s) begin
					sepc     <= x_pc[63:1];
					scause_i <= t_irq;
					scause_c <= trap_code;
					stval    <= t_tval;
					ms_spie  <= ms_sie;
					ms_sie   <= 1'b0;
					ms_spp   <= priv[0];
					priv     <= PRV_S;
				end else begin
					mepc     <= x_pc[63:1];
					mcause_i <= t_irq;
					mcause_c <= trap_code;
					mtval    <= t_tval;
					ms_mpie  <= ms_mie;
					ms_mie   <= 1'b0;
					ms_mpp   <= priv;
					priv     <= PRV_M;
				end
			end else if (x_go) begin
				if (x_first) x_scok <= sc_live;

				if (x_ok && is_mret) begin
					priv    <= ms_mpp;
					ms_mie  <= ms_mpie;
					ms_mpie <= 1'b1;
					ms_mpp  <= PRV_U;
					if (ms_mpp != PRV_M) ms_mprv <= 1'b0;
					res_v   <= 1'b0;
				end
				if (x_ok && is_sret) begin
					priv    <= { 1'b0, ms_spp };
					ms_sie  <= ms_spie;
					ms_spie <= 1'b1;
					ms_spp  <= 1'b0;
					ms_mprv <= 1'b0;
					res_v   <= 1'b0;
				end

				// a compare that was invalid says so
				if (x_ok && is_fcmp && f_nv) begin fflags[4] <= 1'b1; ms_fs <= 2'd3; end

				if (is_csr && x_first) csr_q <= csr_rd;
				if (csr_we) begin
					// (a write to a counter replaces this cycle's count)
					case (csr_adr)
						12'h300: begin
							ms_sie <= csr_new[1]; ms_mie <= csr_new[3];
							ms_spie <= csr_new[5]; ms_mpie <= csr_new[7];
							ms_spp <= csr_new[8]; ms_mpp <= csr_mpp;
							ms_mprv <= csr_new[17]; ms_sum <= csr_new[18];
							ms_mxr <= csr_new[19]; ms_tvm <= csr_new[20];
							ms_tw <= csr_new[21]; ms_tsr <= csr_new[22];
							ms_fs <= csr_new[14:13];
						end
						12'h001: begin fflags <= csr_new[4:0]; ms_fs <= 2'd3; end
						12'h002: begin frm <= csr_new[2:0]; ms_fs <= 2'd3; end
						12'h003: begin fflags <= csr_new[4:0]; frm <= csr_new[7:5]; ms_fs <= 2'd3; end
						12'h100: begin
							ms_sie <= csr_new[1]; ms_spie <= csr_new[5];
							ms_spp <= csr_new[8]; ms_sum <= csr_new[18];
							ms_mxr <= csr_new[19]; ms_fs <= csr_new[14:13];
						end
						12'h302: medeleg <= csr_new[15:0] & 16'hb3ff;
						12'h303: begin dl_ssi <= csr_new[1]; dl_sti <= csr_new[5]; dl_sei <= csr_new[9]; end
						12'h304: begin
							ie_ssi <= csr_new[1]; ie_msi <= csr_new[3]; ie_sti <= csr_new[5];
							ie_mti <= csr_new[7]; ie_sei <= csr_new[9]; ie_mei <= csr_new[11];
						end
						12'h104: begin
							if (dl_ssi) ie_ssi <= csr_new[1];
							if (dl_sti) ie_sti <= csr_new[5];
							if (dl_sei) ie_sei <= csr_new[9];
						end
						12'h305: mtvec    <= csr_new[63:2];
						12'h105: stvec    <= csr_new[63:2];
						12'h306: mcounteren <= csr_new[2:0];
						12'h106: scounteren <= csr_new[2:0];
						12'h340: mscratch <= csr_new;
						12'h140: sscratch <= csr_new;
						12'h341: mepc     <= csr_new[63:1];
						12'h141: sepc     <= csr_new[63:1];
						12'h342: begin mcause_i <= csr_new[63]; mcause_c <= csr_new[3:0]; end
						12'h142: begin scause_i <= csr_new[63]; scause_c <= csr_new[3:0]; end
						12'h343: mtval    <= csr_new;
						12'h143: stval    <= csr_new;
						12'h344: begin ip_ssi <= csr_new[1]; ip_sti <= csr_new[5]; ip_sei <= csr_sei; end
						12'h144: if (dl_ssi) ip_ssi <= csr_new[1];
						12'h180: if (csr_new[62:60] == 3'd0) begin
							satp_mode <= csr_new[63]; satp_ppn <= csr_new[19:0];
						end
						12'hb00: mcycle   <= csr_new;
						12'hb02: minstret <= csr_new;
						default: ;
					endcase
				end

				// the reservation: made by lr.w's answer, spent by any sc.w
				if (x_retire && is_lr) res_v <= 1'b1;
				if (x_retire && is_sc) res_v <= 1'b0;

				if (x_dreq && taken) begin
					x_issued <= 1'b1;
					if (is_lr) res_a <= xa[63:2];
					if (is_amo && !x_ph) begin
						amo_a <= xa;
						// (a word's: extended, which keeps both orders)
						amo_b <= funct3[0] ? xb : { {32{xb[31]}}, xb[31:0] };
					end
				end
				// an AMO's read is answered: now its write
				if (x_issued && d_ack && !x_last) begin
					amo_q    <= ld_out;
					x_ph     <= 1'b1;
					x_issued <= 1'b0;
				end
				if (!x_retire) x_first <= 1'b0;
			end

			// -- W: the result, written to the register file next cycle
			// (w_val holds until the next write: an instruction that
			// forwards from it may wait in X for several cycles)
			w_we  <= x_wr;
			if (x_wr) begin
				w_fp  <= x_wfp;
				// (an f register written: the state is dirty)
				if (x_wfp) ms_fs <= 2'd3;
				w_rd  <= rd_idx;
				w_val <= x_wdat;
				w_pc  <= x_pc;
			end

			// -- X's operands (see x_free_ab) --------------------------
			if (d_ld_ab) begin
				x_a <= d_a;
				x_b <= d_b;
			end
			if (x_dreq && m_rdy) x_lo <= x_va[2:0];
			if (x_dwant && !x_vr) begin
				x_va <= mem_adr;
				x_vr <= 1'b1;
			end

			// -- X takes the next instruction --------------------------
			if (d_go_i) begin
				x_instr <= d_instr;
				x_off   <= d_ofs;
			end
			if (d_go_p) x_pc <= d_pc;
			if (d_go) begin
				x_valid  <= 1'b1;
				x_first  <= 1'b1;
				x_issued <= 1'b0;
				x_ph     <= 1'b0;
				x_pf     <= 1'b0;
				x_vr     <= 1'b0;
				x_ff     <= d_ff;
				x_ff2    <= d_ff2 && !w0_f;
				x_c      <= d_c;
				x_raw    <= d_p16;
				x_pt     <= d_red;
				x_pg     <= d_pg;
				x_ptg    <= d_ptg;
				x_fa     <= d_fa;
				x_fb     <= d_fb;
			end else if (x_free) begin
				x_valid  <= 1'b0;
				x_pf     <= 1'b0;
			end

			// -- the walker ----------------------------------------------
			if (w_start) begin
				w_st   <= canon(lk_va) ? 3'd1 : 3'd7;
				w_va   <= lk_va[38:0];
				w_type <= lk_type;
				w_prv  <= lk_prv;
				w_adr  <= { satp_ppn, lk_va[38:30], 3'b000 };
				w_kill <= 1'b0;
			end
			if (w_req && m_rdy) w_st <= w_st + 3'd1;
			w_ev <= w_ack;
			if (w_ack) pte_r <= m_rdat;
			if (w_ev) begin
				w_st <= 3'd0;
				if (w_next) begin
					w_st  <= w_st + 3'd1;
					w_adr <= { pte[29:10], (w_l2 ? w_va[29:21] : w_va[20:12]), 3'b000 };
				end
				if (w_fill && !w_kill) begin
					tlb[w_va[12 +: TLB_BITS]] <=
						{ w_va[38:12+TLB_BITS], w_ppn, pte[7], pte[4], pte[3], pte[2], pte[1] };
					tlb_v[w_va[12 +: TLB_BITS]] <= 1'b1;
				end
				if (w_fault && !w_fetch) x_pf <= 1'b1;
			end
			if (w_nc) begin
				w_st <= 3'd0;
				if (!w_fetch) x_pf <= 1'b1;
			end
			// a fetch's walk is for a path that is now gone
			// (also one that starts in this very cycle, for the address the
			// fetch is just leaving: without this its fault would be taken
			// for the new address's)
			if ((x_redir || d_red || d_fix) &&
					((w_busy && w_fetch) || (w_start && !w_d))) w_kill <= 1'b1;
			if (tlb_flush) tlb_v <= {TLB_N{1'b0}};

			// -- the queue ---------------------------------------------
			if (x_redir) begin
				iq_cnt <= 3'd0;
				iq_rp  <= 2'd0;
				iq_wp  <= 2'd0;
				d_pc   <= x_target;
			end else if (d_red) begin
				// the head goes to X; the rest is the fall-through path
				iq_cnt <= 3'd0;
				iq_rp  <= 2'd0;
				iq_wp  <= 2'd0;
				d_pc   <= d_tgt;
			end else if (d_fix) begin
				// D's instruction stays (one word, or two), no longer
				// predicted; the rest goes
				iq_cnt <= d_fix2 ? 3'd2 : 3'd1;
				iq_wp  <= d_fix2 ? iq_rp + 2'd2 : iq_rp + 2'd1;
				case (d_fix2 ? iq_r1 : iq_rp)
					2'd0: iq_p0 <= 1'b0;
					2'd1: iq_p1 <= 1'b0;
					2'd2: iq_p2 <= 1'b0;
					default: iq_p3 <= 1'b0;
				endcase
			end else begin
				if (f_push) begin
					case (iq_wp)
						2'd0: begin iq_i0 <= f_word; iq_f0 <= f_fault; iq_p0 <= fo_pt && !f_fault; iq_t0 <= fo_tg; iq_o0 <= fo_po; end
						2'd1: begin iq_i1 <= f_word; iq_f1 <= f_fault; iq_p1 <= fo_pt && !f_fault; iq_t1 <= fo_tg; iq_o1 <= fo_po; end
						2'd2: begin iq_i2 <= f_word; iq_f2 <= f_fault; iq_p2 <= fo_pt && !f_fault; iq_t2 <= fo_tg; iq_o2 <= fo_po; end
						default: begin iq_i3 <= f_word; iq_f3 <= f_fault; iq_p3 <= fo_pt && !f_fault; iq_t3 <= fo_tg; iq_o3 <= fo_po; end
					endcase
					iq_wp <= iq_wp + 2'd1;
				end
				// what D's instruction used up goes: a word, none (the
				// lower of two in one word), or two (a predicted jump
				// that ends in the second: what follows that is elsewhere)
				if (d_go) begin
					if (d_ptw1)
						iq_rp <= iq_rp + 2'd2;
					else if (d_pop1 || d_pt)
						iq_rp <= iq_rp + 2'd1;
					d_pc  <= d_pt ? { d_pc[63:32], d_ptg, 1'b0 } : d_pc + (d_c ? 64'd2 : 64'd4);
				end
				iq_cnt <= iq_cnt + {2'b0, f_push} -
					(!d_go ? 3'd0 : d_ptw1 ? 3'd2 : (d_pop1 || d_pt) ? 3'd1 : 3'd0);
			end

			// -- fetch -------------------------------------------------
			if (x_redir) begin
				pc_f   <= { x_target[63:2], 2'b00 };
				f_halt <= 1'b0;
			end else if (d_red) begin
				pc_f   <= { d_tgt[63:2], 2'b00 };
				f_halt <= 1'b0;
			end else if (d_fix) begin
				pc_f   <= d_wpc + (d_fix2 ? 64'd8 : 64'd4);
				f_halt <= 1'b0;
			end else begin
				if (f_taken) pc_f <= bt_hit ? { pc_f[63:32], bt_tg[30:1], 2'b00 } : pc_f + 64'd4;
				if (f_fault) f_halt <= 1'b1;
			end

			// -- the BTB learns ------------------------------------------
			// a jal or taken branch the fetch did not follow goes in (a
			// cycle later: bt_*); an entry that predicted wrongly goes out
			// (in X: a branch's turn; or in D, an entry that was not for
			// this instruction at all)
			bt_we <= (BTB_BITS != 0) && (r_pcr || (r_nt && x_pg) || d_fix);
			if (r_pcr || r_nt) begin
				bt_wa <= x_end[2 +: BTB_W];
				bt_wd <= { r_pcr, x_end[2+BTB_W +: BTB_TAG], x_end[1], pcrel[31:1] };
			end else begin
				bt_wa <= d_fix2 ? d_wpc[2 +: BTB_W] + 1'b1 : d_pc[2 +: BTB_W];
				bt_wd <= 0;
			end
		end
	end

	// the register file's one write port: W's write
	always @(posedge clk) begin
		if (!rst && w_we && !w_fp)
			regs[w_rd] <= w_val;
		if (!rst && w_we && w_fp)
			fregs[w_rd] <= w_val;
	end

	// for the testbenches: the write W makes this cycle
	wire w_wr = !rst && w_we;

`ifdef K_DEBUG_FF
	always @(posedge clk) if (!rst) begin
		if (f_fault) $display("DBG f_fault pc_f=%08x w_va=%08x pte=%08x priv=%0d cnt=%0d", pc_f, w_va, pte, priv, iq_cnt);
		if (x_valid && x_ff && x_go) $display("DBG x_ff trap x_pc=%08x", x_pc);
		if (d_fix) $display("DBG d_fix d_pc=%08x ptg=%08x", d_pc, {d_ptg,2'b00});
	end
`endif

`ifdef K_PROFILE
	// Where the cycles go, for the simulation to print: each cycle is
	// counted once, by what X was doing.
	reg [63:0] p_n [0:15];
	reg [3:0]  p_k;
	reg        p_dw;				// the data request in hand has waited a cycle already
	integer    p_i;
	initial for (p_i = 0; p_i < 16; p_i = p_i + 1) p_n[p_i] = 0;
	always @(*) begin
		if (rst) p_k = 15;
		else if (x_valid && x_ok && x_fin) p_k = 0;					// an instruction done
		else if (!x_valid) begin
			if (w_busy) p_k = 9;									// nothing in X: a fetch's page walk
			else if (f_out) p_k = 7;								// ...its fetch is on the way
			else p_k = 8;											// ...not even asked yet
		end else if (irq_take || x_bad) p_k = 10;					// a trap being taken
		else if (is_muldiv) p_k = 1;								// multiply or divide running
		else if (is_csr) p_k = 11;									// a CSR instruction's first cycle
		else if (x_mem) begin
			if (x_issued) p_k = p_dw ? 3 : 2;						// waiting for the answer: first cycle, later
			else if (w_busy) p_k = 4;								// a data page walk
			else if (x_dreq && !m_rdy) p_k = 5;						// the port is not free
			else if (x_dwant && !x_dreq) p_k = 6;					// translation's second cycle
			else p_k = 12;											// asked this cycle
		end else p_k = 13;
	end
	always @(posedge clk) begin
		p_n[p_k] <= p_n[p_k] + 1;
		p_dw <= x_valid && x_issued && !d_ack;
	end
	final begin
		$display("profile: %0d done | muldiv %0d | data: asked %0d, answer 1st cycle %0d, later %0d, walk %0d, port busy %0d, translate %0d",
			p_n[0], p_n[1], p_n[12], p_n[2], p_n[3], p_n[4], p_n[5], p_n[6]);
		$display("profile: X empty: fetch on the way %0d, not asked %0d, fetch walk %0d | trap %0d | csr %0d | other %0d",
			p_n[7], p_n[8], p_n[9], p_n[10], p_n[11], p_n[13]);
	end
`endif

endmodule
