/*
 * tb_soc_rom -- kakao_soc with nothing behind it, running a program
 * from its boot memory that prints PASS or FAIL on UART 0 (fw/plictest).
 *
 *   make rom ROM=plictest
 */

`timescale 1ns / 1ps

module tb_soc_rom;

	parameter ROM = "../fw/plictest/plictest";
	parameter MAX = 2000000;

	reg clk = 0, rst = 1;
	always #10 clk = !clk;

	wire mem_stb, ext_stb;
	reg  mem_ack = 0, ext_ack = 0;
	always @(posedge clk) begin
		mem_ack <= mem_stb && !mem_ack;
		ext_ack <= ext_stb && !ext_ack;
	end

	kakao_soc #(
		.KCACHE(1), .ROM_WORDS(4096), .ROM_HEX(ROM), .UART_DIV(2), .LITEUART(0)
	) soc (
		.clk(clk), .rst(rst),
		.mem_adr_o(), .mem_dat_o(), .mem_dat_i(32'd0), .mem_we_o(), .mem_sel_o(),
		.mem_stb_o(mem_stb), .mem_ack_i(mem_ack),
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

	integer cycles = 0;
	reg [8*8-1:0] last = 0;
	reg done = 0;
	always @(posedge clk) begin
		cycles <= cycles + 1;
		if (soc.uart0_i.tap) begin
			$write("%c", soc.uart0_i.wdat[7:0]);
			last <= { last[55:0], soc.uart0_i.wdat[7:0] };
			if (soc.uart0_i.wdat[7:0] == 8'h0a) done <= 1;
		end
		if (done || cycles == MAX) begin
			if (last[39:8] == "PASS") $display("[tb] PASS, %0d cycles", cycles);
			else $display("[tb] FAIL%s", cycles == MAX ? " (out of time)" : "");
			$finish;
		end
	end

	initial begin
		repeat (20) @(posedge clk);
		rst = 0;
	end

endmodule
