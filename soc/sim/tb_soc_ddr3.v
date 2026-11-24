/*
 * tb_soc_ddr3 -- the SOC on Zeitlos's DDR3 controller as it is on the
 * boards (ddr3_ctrl.v, with its write combining), through Zeitlos's
 * behavioural PHY to its DRAM model, which fails the run on any
 * violation of the DDR3 protocol. The program in the boot memory is
 * fw/memtest. This is what the simulation of Linux cannot show: that
 * k_cache and the real controller understand each other.
 *
 *   make ddr3          (Icarus; KC=0 for Zeitlos's cache, WC=0 for the
 *                       controller without write combining)
 */

`timescale 1ps / 1ps

module tb_soc_ddr3;

	parameter KC = 1;
	parameter WC = 1;
	parameter MAX = 6000000;		// cycles

	localparam TCK_PS = 10417;		// 96 MHz DRAM clock, 48 MHz for the rest
	reg ck = 0, clk = 0, rst = 1;
	initial forever #(TCK_PS / 2) ck = ~ck;
	initial begin
		@(negedge ck);
		forever begin
			@(posedge ck); clk = 1'b1;
			@(posedge ck); clk = 1'b0;
		end
	end

	wire [26:0] mem_adr;
	wire [31:0] mem_dat_w, mem_dat_r;
	wire        mem_we, mem_stb, mem_ack;
	wire  [3:0] mem_sel;
	wire        init_done;
	wire        ext_stb;
	reg         ext_ack = 0;
	always @(posedge clk) ext_ack <= ext_stb && !ext_ack;

	// the SOC waits for the DRAM's initialisation (on the board, kboot does)
	wire soc_rst = rst || !init_done;

	kakao_soc #(
		.KCACHE(KC), .I_KB(16), .D_KB(16), .CACHE_KB(32),
		.ROM_WORDS(4096), .ROM_HEX("../fw/memtest/memtest"),
		.UART_DIV(2), .LITEUART(0)
	) soc (
		.clk(clk), .rst(soc_rst),
		.mem_adr_o(mem_adr), .mem_dat_o(mem_dat_w), .mem_dat_i(mem_dat_r),
		.mem_we_o(mem_we), .mem_sel_o(mem_sel), .mem_stb_o(mem_stb), .mem_ack_i(mem_ack),
		.reg_adr_o(), .reg_dat_o(), .reg_dat_i(32'd0), .reg_we_o(), .reg_stb_o(), .reg_ack_i(1'b1),
		.ext_adr_o(), .ext_dat_o(), .ext_dat_i(32'd0), .ext_we_o(), .ext_sel_o(),
		.ext_stb_o(ext_stb), .ext_ack_i(ext_ack),
		.uart0_rx(1'b1), .uart0_tx(),
		.con_tx_valid(), .con_tx_data(), .con_tx_ready(1'b0),
		.con_rx_valid(1'b0), .con_rx_data(8'd0), .con_rx_ready(),
		.pclk(1'b0), .vid_r(), .vid_g(), .vid_b(), .vid_hsync(), .vid_vsync(), .vid_blank(),
		.iop_trap(),
		.iox_adr_o(), .iox_dat_o(), .iox_dat_i(32'd0), .iox_we_o(), .iox_sel_o(), .iox_stb_o(), .iox_ack_i(1'b0),
		.mtime_o(), .poweroff_o(), .reset_o()
	);

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

	// (the board's parameters, but for the waits of initialisation)
	ddr3_ctrl #(.ROW_BITS(15), .COL_BITS(10), .BANK_BITS(3), .TRFC_NS(260),
		.CLK_MHZ(48), .INIT_DIV(1000), .WCOMBINE(WC)) ctrl (
		.clk_i(clk), .rst_i(rst),
		.wb_adr_i(mem_adr),
		.wb_dat_i(mem_dat_w), .wb_dat_o(mem_dat_r), .wb_we_i(mem_we), .wb_sel_i(mem_sel),
		.wb_stb_i(mem_stb), .wb_cyc_i(mem_stb), .wb_ack_o(mem_ack),
		.phy_ready_i(1'b1), .init_done_o(init_done), .rd_timeout_o(),
		.no_refresh_i(1'b0), .wr_noread_i(1'b0), .rdbuf_off_i(1'b0),
		.phy_reset_n_o(c_reset_n), .phy_cke_o(c_cke), .phy_odt_o(c_odt),
		.phy_cs_n_o(c_cs_n), .phy_ras_n_o(c_ras_n), .phy_cas_n_o(c_cas_n),
		.phy_we_n_o(c_we_n), .phy_a_o(c_a), .phy_ba_o(c_ba),
		.phy_wren_o(c_wren), .phy_wdata_o(c_wdata), .phy_wmask_o(c_wmask),
		.phy_rden_o(c_rden), .phy_rvalid_i(c_rvalid), .phy_rdata_i(c_rdata)
	);
	ddr3_phy_sim #(.TCK_PS(TCK_PS), .CL(6), .CWL(6)) phy (
		.clk_i(clk), .ck_i(ck), .rst_i(rst),
		.ctl_reset_n_i(c_reset_n), .ctl_cke_i(c_cke), .ctl_odt_i(c_odt),
		.ctl_cs_n_i(c_cs_n), .ctl_ras_n_i(c_ras_n), .ctl_cas_n_i(c_cas_n),
		.ctl_we_n_i(c_we_n), .ctl_a_i(c_a), .ctl_ba_i(c_ba),
		.ctl_wren_i(c_wren), .ctl_wdata_i(c_wdata), .ctl_wmask_i(c_wmask),
		.ctl_rden_i(c_rden), .ctl_rvalid_o(c_rvalid), .ctl_rdata_o(c_rdata),
		.ddr_reset_n(d_reset_n), .ddr_cke(d_cke), .ddr_odt(d_odt),
		.ddr_cs_n(d_cs_n), .ddr_ras_n(d_ras_n), .ddr_cas_n(d_cas_n),
		.ddr_we_n(d_we_n), .ddr_a(d_a), .ddr_ba(d_ba), .ddr_dm(d_dm),
		.ddr_dq(d_dq), .ddr_dqs(d_dqs)
	);
	// (128 rows of the 32768: the program stays within them)
	ddr3_model #(.ROW_BITS(15), .COL_BITS(10), .BANK_BITS(3), .ROW_ALIAS(7),
		.TCK_PS(TCK_PS)) dram (
		.ck(ck), .reset_n(d_reset_n), .cke(d_cke), .cs_n(d_cs_n),
		.ras_n(d_ras_n), .cas_n(d_cas_n), .we_n(d_we_n), .a(d_a), .ba(d_ba),
		.dm(d_dm), .dq(d_dq), .dqs(d_dqs)
	);

	// what the program prints, and the end
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
			$display("[tb] %0d cycles; the controller answered %0d reads and %0d writes; the DRAM model counted %0d violations",
				cycles, n_rd, n_wr, dram.errors);
			if (last[39:8] == "PASS" && dram.errors == 0) $display("[tb] PASS");
			else $display("[tb] FAIL%s", cycles == MAX ? " (out of time)" : "");
			$finish;
		end
	end

	initial begin
		repeat (20) @(posedge clk);
		rst = 0;
	end

endmodule
