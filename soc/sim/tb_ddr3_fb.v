/*
 * The scan-out port of the DDR3 controller (rtl/mem/k_ddr3_ctrl.v, fb_*)
 * against Zeitlos's model of the DRAM, which checks the protocol's
 * timing: blocks are read on it at the rate a screen of 640 by 480
 * pixels of 16 bits reads them while a line is drawn, one every 16
 * cycles, while the bus reads and writes other memory --
 * the same rows and others, stores that combine and stores that do
 * not. Every block must come as it was written, the bus's own data
 * must stay right, the model must have nothing to complain of, and no
 * block may take longer than the reader's queue allows.
 *
 *   make ddr3fb        (in soc/sim)
 */

`timescale 1ps/1ps

module tb_ddr3_fb;

	localparam TCK_PS = 10417;
	localparam ROW_BITS = 15;
	localparam COL_BITS = 10;
	localparam BANK_BITS = 3;
	localparam ROW_ALIAS = 6;
	localparam NFB = 96;			// the blocks of the "screen"
	localparam [24:0] FB_AT = 25'h1fc0000 >> 2;	// far from where the bus works...
	localparam LATE = 64;			// cycles: k_fb.v's queue holds 8 blocks, 128 cycles of picture

	reg ck, clk, rst;
	reg  [26:0] wb_adr;
	reg  [31:0] wb_dat_w;
	wire [31:0] wb_dat_r;
	reg         wb_we, wb_stb;
	reg   [3:0] wb_sel;
	wire        wb_ack;
	reg         fb_stb;
	reg  [24:0] fb_adr;
	wire        fb_ack;
	wire [127:0] fb_dat;
	wire init_done, rd_timeout;

	wire c_reset_n, c_cke, c_odt, c_cs_n, c_ras_n, c_cas_n, c_we_n;
	wire [15:0] c_a;
	wire [2:0] c_ba;
	wire c_wren, c_rden, c_rvalid;
	wire [127:0] c_wdata, c_rdata;
	wire [15:0] c_wmask;

	wire d_reset_n, d_cke, d_odt, d_cs_n, d_ras_n, d_cas_n, d_we_n;
	wire [15:0] d_a;
	wire [2:0] d_ba;
	wire [1:0] d_dm;
	wire [15:0] d_dq;
	wire [1:0] d_dqs;

	integer errors, i, k, n, seed, worst, t, nblk;
	reg [31:0] got;
	reg [31:0] shadow [0:255];
	reg fb_go, fb_done;

	initial begin ck = 1'b0; forever #(TCK_PS / 2) ck = ~ck; end
	initial begin
		clk = 1'b0;
		@(negedge ck);
		forever begin @(posedge ck); clk = 1'b1; @(posedge ck); clk = 1'b0; end
	end

	k_ddr3_ctrl #(
		.ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS),
		.TRFC_NS(260), .CLK_MHZ(48), .WCOMBINE(1), .INIT_DIV(1000)
	) dut (
		.clk_i(clk), .rst_i(rst),
		.wb_adr_i(wb_adr), .wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r),
		.wb_we_i(wb_we), .wb_sel_i(wb_sel), .wb_stb_i(wb_stb), .wb_cyc_i(wb_stb),
		.wb_ack_o(wb_ack),
		.fb_stb_i(fb_stb), .fb_adr_i(fb_adr), .fb_ack_o(fb_ack), .fb_dat_o(fb_dat),
		.phy_ready_i(1'b1), .init_done_o(init_done), .rd_timeout_o(rd_timeout),
		.no_refresh_i(1'b0), .wr_noread_i(1'b0), .rdbuf_off_i(1'b0),
		.phy_reset_n_o(c_reset_n), .phy_cke_o(c_cke), .phy_odt_o(c_odt),
		.phy_cs_n_o(c_cs_n), .phy_ras_n_o(c_ras_n), .phy_cas_n_o(c_cas_n),
		.phy_we_n_o(c_we_n), .phy_a_o(c_a), .phy_ba_o(c_ba),
		.phy_wren_o(c_wren), .phy_wdata_o(c_wdata), .phy_wmask_o(c_wmask),
		.phy_rden_o(c_rden), .phy_rvalid_i(c_rvalid), .phy_rdata_i(c_rdata)
	);

	ddr3_phy_sim #(
		.TCK_PS(TCK_PS),
		.CL(6),
		.CWL(6)
	) phy (
		.clk_i(clk),
		.ck_i(ck),
		.rst_i(rst),
		.ctl_reset_n_i(c_reset_n),
		.ctl_cke_i(c_cke),
		.ctl_odt_i(c_odt),
		.ctl_cs_n_i(c_cs_n),
		.ctl_ras_n_i(c_ras_n),
		.ctl_cas_n_i(c_cas_n),
		.ctl_we_n_i(c_we_n),
		.ctl_a_i(c_a),
		.ctl_ba_i(c_ba),
		.ctl_wren_i(c_wren),
		.ctl_wdata_i(c_wdata),
		.ctl_wmask_i(c_wmask),
		.ctl_rden_i(c_rden),
		.ctl_rvalid_o(c_rvalid),
		.ctl_rdata_o(c_rdata),
		.ddr_reset_n(d_reset_n),
		.ddr_cke(d_cke),
		.ddr_odt(d_odt),
		.ddr_cs_n(d_cs_n),
		.ddr_ras_n(d_ras_n),
		.ddr_cas_n(d_cas_n),
		.ddr_we_n(d_we_n),
		.ddr_a(d_a),
		.ddr_ba(d_ba),
		.ddr_dm(d_dm),
		.ddr_dq(d_dq),
		.ddr_dqs(d_dqs)
	);

	ddr3_model #(
		.ROW_BITS(ROW_BITS),
		.COL_BITS(COL_BITS),
		.BANK_BITS(BANK_BITS),
		.ROW_ALIAS(ROW_ALIAS),
		.TCK_PS(TCK_PS)
	) dram (
		.ck(ck),
		.reset_n(d_reset_n),
		.cke(d_cke),
		.cs_n(d_cs_n),
		.ras_n(d_ras_n),
		.cas_n(d_cas_n),
		.we_n(d_we_n),
		.a(d_a),
		.ba(d_ba),
		.dm(d_dm),
		.dq(d_dq),
		.dqs(d_dqs)
	);

	task wb_write;
		input [26:0] addr;
		input [31:0] data;
		input  [3:0] sel;
	begin
		@(posedge clk);
		wb_adr <= addr; wb_dat_w <= data; wb_sel <= sel; wb_we <= 1'b1; wb_stb <= 1'b1;
		@(posedge clk);
		while (!wb_ack) @(posedge clk);
		wb_stb <= 1'b0; wb_we <= 1'b0;
		@(posedge clk);
	end
	endtask

	task wb_read;
		input [26:0] addr;
		output [31:0] data;
	begin
		@(posedge clk);
		wb_adr <= addr; wb_sel <= 4'hf; wb_we <= 1'b0; wb_stb <= 1'b1;
		@(posedge clk);
		while (!wb_ack) @(posedge clk);
		data = wb_dat_r;
		wb_stb <= 1'b0;
		@(posedge clk);
	end
	endtask

	// what the screen's word w holds
	function [31:0] pat;
		input [31:0] w;
		pat = 32'hfb000000 ^ (w * 32'h9e3779b1);
	endfunction

	// the reader: the screen's blocks, round and round, one every 16
	// cycles (or as soon as the last has come, when that was later)
	integer fb_t, fb_n, fb_b;
	initial begin
		fb_stb = 1'b0; fb_adr = 25'd0; fb_done = 1'b0; worst = 0; nblk = 0;
		wait (fb_go === 1'b1);
		fb_b = 0;
		while (fb_go) begin
			@(posedge clk);
			fb_adr <= FB_AT + fb_b; fb_stb <= 1'b1;
			fb_t = 0;
			@(posedge clk);
			while (!fb_ack) begin fb_t = fb_t + 1; @(posedge clk); end
			fb_stb <= 1'b0;
			if (fb_t > worst) worst = fb_t;
			nblk = nblk + 1;
			for (fb_n = 0; fb_n < 4; fb_n = fb_n + 1)
				if (fb_dat[fb_n*32 +: 32] !== pat(fb_b * 4 + fb_n)) begin
					if (errors < 10)
						$display("  FAIL screen block %0d word %0d: %08h, not %08h",
							fb_b, fb_n, fb_dat[fb_n*32 +: 32], pat(fb_b * 4 + fb_n));
					errors = errors + 1;
				end
			fb_b = (fb_b + 1) % NFB;
			while (fb_t < 14) begin fb_t = fb_t + 1; @(posedge clk); end
		end
		fb_done = 1'b1;
	end

	initial begin
		errors = 0; seed = 7; fb_go = 1'b0;
		wb_stb = 1'b0; wb_we = 1'b0; wb_adr = 27'd0; wb_dat_w = 32'd0; wb_sel = 4'd0;
		rst = 1'b1;
		repeat (8) @(posedge clk);
		rst = 1'b0;
		wait (init_done);
		repeat (4) @(posedge clk);

		// the screen, written through the bus
		for (i = 0; i < NFB * 4; i = i + 1)
			wb_write({ FB_AT, 2'b00 } + i, pat(i), 4'hf);
		// (and let the last block reach the DRAM)
		repeat (40) @(posedge clk);
		for (i = 0; i < 256; i = i + 1) shadow[i] = 32'hxxxxxxxx;

		fb_go = 1'b1;
		// the bus meanwhile: 256 words in two places, one of them in
		// the screen's own rows (its bank, the blocks after it)
		for (n = 0; n < 3000; n = n + 1) begin
			k = $random(seed) & 255;
			t = $random(seed);
			if (t[1:0] == 2'd0 && shadow[k] !== 32'hxxxxxxxx) begin
				wb_read(k[7] ? { FB_AT, 2'b00 } + NFB * 4 + k[6:0] : 27'h0004000 + k[6:0], got);
				if (got !== shadow[k]) begin
					if (errors < 10) $display("  FAIL bus word %0d: %08h, not %08h", k, got, shadow[k]);
					errors = errors + 1;
				end
			end else begin
				wb_write(k[7] ? { FB_AT, 2'b00 } + NFB * 4 + k[6:0] : 27'h0004000 + k[6:0], t, 4'hf);
				shadow[k] = t;
			end
			// now and then the bus rests, and a combined block goes out
			if (t[9:6] == 4'd0) repeat (20) @(posedge clk);
		end
		fb_go = 1'b0;
		wait (fb_done);

		$display("screen: %0d blocks read, the slowest %0d cycles", nblk, worst);
		if (worst > LATE) begin
			$display("  FAIL: a block took more than %0d cycles", LATE);
			errors = errors + 1;
		end
		if (rd_timeout) begin $display("  FAIL: a read timed out"); errors = errors + 1; end
		if (dram.errors != 0) $display("  FAIL: the model reports %0d errors", dram.errors);
		errors = errors + dram.errors;
		if (errors == 0) $display("== PASS: no errors ==");
		else $display("== FAIL: %0d error(s) ==", errors);
		$finish;
	end

	initial begin
		#(64'd40000000000);
		$display("== FAIL: timed out == state %0d ret %0d wb_stb %b we %b adr %h fb_stb %b fb_ack %b n %0d nblk %0d busy %b dirty %b", dut.state, dut.ret_state, wb_stb, wb_we, wb_adr, fb_stb, fb_ack, n, nblk, dut.req_busy, dut.wc_dirty);
		$finish;
	end

endmodule
