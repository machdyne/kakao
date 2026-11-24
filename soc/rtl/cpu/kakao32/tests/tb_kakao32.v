/*
 * Zeitlos SOC -- kakao32 test harness
 * Copyright (c) 2026 Lone Dynamics Corporation. All rights reserved.
 *
 * Runs one compiled test program against kakao32 and reports
 * pass/fail. The programs are zeitlos32's (rtl/cpu/zeitlos32/tests/
 * prog), unchanged, with the same conventions:
 *
 *   store to 0xe000_0000   finished: 0 passed, else the failing check
 *   store to 0xf000_0000   a byte to the console
 *   store to 0xe000_0010   pulse the given irq lines for one cycle
 *   store to 0xe000_0014   hold the given irq lines until written again
 *
 * The memory is a model of ONE rtl/cache_split.v-style port: a request
 * is taken on req && rdy; ack comes LAT cycles after the cycle it was
 * taken in (LAT 0: the next cycle, a cache hit), and rdy is high again
 * in the ack cycle. LAT is fixed, or random per request (RANDLAT:
 * 0..LAT), and with BUSY the port also drops rdy at random. Stores
 * land in memory when acknowledged.
 */

/*
 * tb_kakao32 -- kakao32 on a memory with wait states.
 *
 *   0x8000_0000 ...        memory, MEM_WORDS words, loaded from +hex=
 *   store to +tohost=      finished, riscv-tests' way: 1 passed, else
 *                          the failing test's number, shifted left one
 *   store to 0xe000_0014   the interrupt lines, held until written
 *                          again: bit 0 MSI, bit 1 MTI, bit 2 MEI,
 *                          bit 3 SEI. mtime counts clock cycles.
 *   store to 0xf000_0000   print a character
 *
 * LAT: cycles from a request to its answer, less one. RANDLAT: a random
 * number of them, up to LAT, per request. BUSY: the port is not ready
 * in one cycle of eight, at random.
 */

`timescale 1ns / 1ps

module tb_kakao32;

	parameter MEM_WORDS = 1048576;
	parameter LAT       = 0;
	parameter RANDLAT   = 0;
	parameter BUSY      = 0;
	parameter SEED      = 12345;
	parameter TIMEOUT   = 2000000;
	parameter FAST_MUL  = 0;
	parameter BTFN      = 0;
	parameter BTB_BITS  = 6;
	parameter FAST_XLATE = 1;
	parameter TRACE     = 0;

	reg clk, rst;

	wire        m_req, m_we, m_instr, m_rdy, m_ack;
	wire [31:0] m_adr, m_wdat, m_rdat;
	wire  [3:0] m_sel;

	reg [31:0] mem [0:MEM_WORDS-1];
	reg  [3:0] irq_level;
	reg [63:0] mtime;

	kakao32 #(
		.RESET_PC(32'h8000_0000),
		.FAST_MUL(FAST_MUL),
		.BTFN(BTFN),
		.BTB_BITS(BTB_BITS),
		.FAST_XLATE(FAST_XLATE)
	) cpu (
		.clk(clk), .rst(rst),
		.m_req(m_req), .m_adr(m_adr), .m_we(m_we), .m_sel(m_sel),
		.m_wdat(m_wdat), .m_instr(m_instr),
		.m_rdy(m_rdy), .m_ack(m_ack), .m_rdat(m_rdat),
		.mtime(mtime),
		.irq_msi(irq_level[0]), .irq_mti(irq_level[1]), .irq_mei(irq_level[2]),
		.irq_sei(irq_level[3])
	);

	initial clk = 0;
	always #5 clk = ~clk;

	integer seed, cycles, i;
	reg [1023:0] hexfile;
	reg [31:0] tohost;

	reg        p;                    // a request is pending
	integer    c;                    // cycles until its ack
	reg [31:0] a, dd;
	reg        w;
	reg  [3:0] s;
	reg        busy;

	wire [31:0] widx = (a - 32'h8000_0000) >> 2;

	assign m_ack  = p && (c == 0);
	assign m_rdy  = !busy && (!p || m_ack);
	assign m_rdat = (a[31:28] == 4'he || a[31:28] == 4'hf) ? 32'd0 :
	                mem[widx % MEM_WORDS];

	always @(posedge clk) begin
		if (rst) begin
			p <= 1'b0; c <= 0; busy <= 1'b0;
			irq_level <= 4'd0; mtime <= 64'd0;
		end else begin
			mtime <= mtime + 64'd1;
			busy <= BUSY && (($random(seed) & 7) == 0);
			if (m_ack && w) begin
				if ({ a[31:2], 2'b00 } == tohost) begin
					// (reported here, in the process that sees it: a flag
					// read by the initial block is lost under Verilator)
					if (dd == 32'd1)
						$display("PASS  (%0d cycles, %0d instructions)", cycles, cpu.minstret);
					else
						$display("FAIL  test %0d  (%0d cycles, pc in X=%08x)",
							dd >> 1, cycles, cpu.x_pc);
					$finish;
				end else if (a[31:28] == 4'he) begin
					if (a[7:0] == 8'h14) irq_level <= dd[3:0];
				end else if (a[31:28] == 4'hf) begin
					if (s[0]) $write("%c", dd[7:0]);
				end else begin
					if (s[0]) mem[widx % MEM_WORDS][7:0]   <= dd[7:0];
					if (s[1]) mem[widx % MEM_WORDS][15:8]  <= dd[15:8];
					if (s[2]) mem[widx % MEM_WORDS][23:16] <= dd[23:16];
					if (s[3]) mem[widx % MEM_WORDS][31:24] <= dd[31:24];
				end
			end
			if (p && c != 0) c <= c - 1;
			if (m_req && m_rdy) begin
				p <= 1'b1;
				a <= m_adr; w <= m_we; s <= m_sel; dd <= m_wdat;
				c <= RANDLAT ? ({$random(seed)} % (LAT + 1)) : LAT;
			end else if (m_ack) begin
				p <= 1'b0;
			end
		end
	end

	always @(posedge clk) begin
		if (!rst) cycles <= cycles + 1;
		if (cycles > TIMEOUT) begin
			$display("FAIL  timeout after %0d cycles, X pc=%08x valid=%0d mcause=%0d mepc=%08x",
				TIMEOUT, cpu.x_pc, cpu.x_valid, cpu.mcause_c, { cpu.mepc, 2'b00 });
			$finish;
		end
	end

	always @(posedge clk) begin
		if (!rst && TRACE && cpu.w_wr)
			$display("W %08x x%0d %08x", cpu.w_pc, cpu.w_rd, cpu.w_val);
		if (!rst && TRACE && cpu.trap_take)
			$display("T %08x cause %0d%s tval %08x -> %s", cpu.x_pc, cpu.trap_code, cpu.irq_take ? " (irq)" : "", cpu.exc_tval, cpu.trap_s ? "S" : "M");
	end

	initial begin
		seed = SEED;
		cycles = 0;
		for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;
		if (!$value$plusargs("hex=%s", hexfile)) begin
			$display("FAIL: no +hex=<file> given");
			$finish;
		end
		if (!$value$plusargs("tohost=%h", tohost)) tohost = 32'he000_0000;
		$readmemh(hexfile, mem);
		rst = 1;
		repeat (5) @(posedge clk);
		rst = 0;
	end

endmodule
