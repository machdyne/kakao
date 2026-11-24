/*
 * tb_soc_sdram -- the SOC on Zeitlos's SDRAM controller as it is on the
 * boards with 32 MB (mem/sdram_kianv.v, at 48 MHz, a word at a time),
 * and Zeitlos's model of the SDRAM, which counts every violation of
 * its protocol. The program in the boot memory is fw/memtest, as in
 * tb_soc_ddr3.v.
 *
 *   make sdram         (Icarus)
 */

`timescale 1ns / 1ps

module tb_soc_sdram;

	parameter MAX = 9000000;		// cycles

	reg clk = 0, rst = 1;
	always #10.417 clk = ~clk;		// 48 MHz

	wire [26:0] mem_adr;
	wire [31:0] mem_dat_w, mem_dat_r;
	wire        mem_we, mem_stb, mem_ack;
	wire  [3:0] mem_sel;
	wire        ext_stb;
	reg         ext_ack = 0;
	always @(posedge clk) ext_ack <= ext_stb && !ext_ack;

	kakao_soc #(
		.KCACHE(1), .I_KB(16), .D_KB(16), .CACHE_KB(32),
		.ROM_WORDS(4096), .ROM_HEX("../fw/memtest/memtest"),
		.UART_DIV(2), .LITEUART(0)
	) soc (
		.clk(clk), .rst(rst),
		.mem_adr_o(mem_adr), .mem_dat_o(mem_dat_w), .mem_dat_i(mem_dat_r),
		.mem_we_o(mem_we), .mem_sel_o(mem_sel), .mem_stb_o(mem_stb), .mem_ack_i(mem_ack),
		.reg_adr_o(), .reg_dat_o(), .reg_dat_i(32'd0), .reg_we_o(), .reg_stb_o(), .reg_ack_i(1'b1),
		.ext_adr_o(), .ext_dat_o(), .ext_dat_i(32'd0), .ext_we_o(), .ext_sel_o(),
		.ext_stb_o(ext_stb), .ext_ack_i(ext_ack),
		.uart0_rx(1'b1), .uart0_tx(),
		.con_tx_valid(), .con_tx_data(), .con_tx_ready(1'b0),
		.con_rx_valid(1'b0), .con_rx_data(8'd0), .con_rx_ready(),
		.pclk(1'b0), .vid_r(), .vid_g(), .vid_b(), .vid_hsync(), .vid_vsync(), .vid_blank(),
		.iop_trap(), .usb_dp(), .usb_dm(),
		.iox_adr_o(), .iox_dat_o(), .iox_dat_i(32'd0), .iox_we_o(), .iox_sel_o(), .iox_stb_o(), .iox_ack_i(1'b0),
		.mtime_o(), .poweroff_o(), .reset_o()
	);

	wire        s_clk, s_cke, s_csn, s_wen, s_rasn, s_casn;
	wire  [1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq;

	// as boards/kakao_top.v has it
	sdram_wb #(.SDRAM_CLK_FREQ(48), .BURST(0)) sdram (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i({ mem_adr[22:0], 2'b00 }), .wb_dat_i(mem_dat_w), .wb_dat_o(mem_dat_r),
		.wb_we_i(mem_we), .wb_sel_i(mem_sel), .wb_stb_i(mem_stb),
		.wb_ack_o(mem_ack), .wb_cyc_i(mem_stb), .wb_cti_i(3'b000),
		.sdram_clk(s_clk), .sdram_cke(s_cke),
		.sdram_dqm(s_dqm), .sdram_addr(s_a), .sdram_ba(s_ba),
		.sdram_csn(s_csn), .sdram_wen(s_wen), .sdram_rasn(s_rasn), .sdram_casn(s_casn),
		.sdram_dq(s_dq)
	);

	// (4 MB of it are there: the test stays below 1 MB)
	sdram_model #(.MEM_WORDS(2097152)) mem (
		.clk(s_clk), .cke(s_cke), .csn(s_csn),
		.rasn(s_rasn), .casn(s_casn), .wen(s_wen),
		.dqm(s_dqm), .ba(s_ba), .addr(s_a), .dq(s_dq)
	);

	integer cycles = 0, n_rd = 0, n_wr = 0;
	reg [8*8-1:0] last = 0;
	reg done = 0;
	always @(posedge clk) begin
		cycles <= cycles + 1;
		if (mem_stb && mem_ack) begin
			if (mem_we) n_wr <= n_wr + 1; else n_rd <= n_rd + 1;
		end
		if (soc.uart0_i.tap) begin
			$write("%c", soc.uart0_i.wdat[7:0]);
			$fflush;
			last <= { last[55:0], soc.uart0_i.wdat[7:0] };
			if (soc.uart0_i.wdat[7:0] == 8'h0a) done <= 1;
		end
		if (done || cycles == MAX) begin
			$display("[tb] %0d cycles, %0d reads and %0d writes of the SDRAM, %0d protocol errors",
				cycles, n_rd, n_wr, mem.errors);
			if (last[39:8] == "PASS" && mem.errors == 0) $display("[tb] PASS");
			else $display("[tb] FAIL");
			$finish;
		end
	end

	initial begin
		repeat (20) @(posedge clk);
		rst = 0;
	end

endmodule
