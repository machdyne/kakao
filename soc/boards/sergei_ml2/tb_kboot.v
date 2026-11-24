/*
 * tb_kboot -- kboot's loader on kakao_soc, with a plain memory where
 * the DDR3 would be (so the trainer finds a memory that needs no
 * training, and says what it says about that) and a host on the UART
 * that does what tools/kload.py does: loads a twelve-byte program and
 * starts it. The program prints 'K'.
 */

`timescale 1ns / 1ps

module tb_kboot;

	parameter DIV = 48;		// 1 Mbaud at 48 MHz: the loader has to keep up
	parameter KC = 1;		// k_cache (0: Zeitlos's)
	parameter SD = "";		// a card's image: then it boots from that
	parameter CPU64 = 0;		// kakao64, and kboot built for it
	parameter KROM = "../../fw/kboot/kboot";

	reg clk = 0;
	always #5 clk = ~clk;
	reg rst = 1;

	wire tx;
	reg  rx = 1;

	wire [26:0] ma; wire [31:0] mw; reg [31:0] mr; wire mwe, mstb; wire [3:0] msel; reg mack = 0;
	reg [31:0] ram [0:1048575];
	integer i;
	initial for (i = 0; i < 1048576; i = i + 1) ram[i] = 0;
	always @(posedge clk) begin
		mack <= mstb && !mack;
		mr <= ram[ma[19:0]];
		if (mstb && mwe && !mack) begin
			if (msel[0]) ram[ma[19:0]][7:0]   <= mw[7:0];
			if (msel[1]) ram[ma[19:0]][15:8]  <= mw[15:8];
			if (msel[2]) ram[ma[19:0]][23:16] <= mw[23:16];
			if (msel[3]) ram[ma[19:0]][31:24] <= mw[31:24];
		end
	end

	// main memory's registers: STATUS says ready, TUNE and CTRL hold
	wire [1:0] ra; wire [31:0] rw; wire rwe, rstb; reg rack = 0;
	reg [31:0] tune = 32'h0882_2333, ctrl = 0;
	always @(posedge clk) begin
		rack <= rstb && !rack;
		if (rstb && rwe && !rack) begin
			if (ra == 2'd1) tune <= rw;
			if (ra == 2'd2) ctrl <= rw;
		end
	end
	wire [31:0] rr = (ra == 2'd0) ? 32'hdd30_0083 : (ra == 2'd1) ? tune : ctrl;

	// the board's SD card, on Zeitlos's SPI master as on the board
	wire [31:0] xa, xw, sd_r; wire es, xwe, sd_ack; wire [3:0] xsel; reg ea = 0;
	wire s_sd = (xa[31:8] == 24'h030008);
	always @(posedge clk) ea <= es && !s_sd && !ea;
	wire sd_cs, sd_sck, sd_mosi, sd_miso;
	pullup (sd_miso);
	spim_wb sd_i (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i({ 30'd0, xa[3:2] }), .wb_dat_i(xw), .wb_dat_o(sd_r),
		.wb_we_i(xwe), .wb_sel_i(xsel), .wb_stb_i(es && s_sd), .wb_ack_o(sd_ack), .wb_cyc_i(es && s_sd),
		.spi_cs_n(sd_cs), .spi_sck(sd_sck), .spi_mosi(sd_mosi), .spi_miso(sd_miso),
		.spi_int(1'b1), .dma_start_i(1'b0), .dma_busy_o()
	);
	generate if (SD != "") begin : card
		// (the clock here is 100 MHz, so "400 kHz" is 1200 ns a bit)
		sd_model #(.IMAGE(SD), .FAST_NS(1100)) sd (.cs_n(sd_cs), .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso));
	end endgenerate

	kakao_soc #(
		.KCACHE(KC), .CACHE_KB(8), .ROM_WORDS(4096), .ROM_HEX(KROM), .CPU64(CPU64), .UART_DIV(DIV)
	) soc (
		.clk(clk), .rst(rst),
		.mem_adr_o(ma), .mem_dat_o(mw), .mem_dat_i(mr), .mem_we_o(mwe), .mem_sel_o(msel),
		.mem_stb_o(mstb), .mem_ack_i(mack),
		.reg_adr_o(ra), .reg_dat_o(rw), .reg_dat_i(rr), .reg_we_o(rwe), .reg_stb_o(rstb), .reg_ack_i(rack),
		.ext_adr_o(xa), .ext_dat_o(xw), .ext_dat_i(s_sd ? sd_r : 32'd0), .ext_we_o(xwe), .ext_sel_o(xsel),
		.ext_stb_o(es), .ext_ack_i(s_sd ? sd_ack : ea),
		.uart0_rx(rx), .uart0_tx(tx),
		.con_tx_valid(), .con_tx_data(), .con_tx_ready(1'b0),
		.con_rx_valid(1'b0), .con_rx_data(8'd0), .con_rx_ready(),
		.pclk(1'b0), .vid_r(), .vid_g(), .vid_b(), .vid_hsync(), .vid_vsync(), .vid_blank(), .iop_trap(),
		.iox_adr_o(), .iox_dat_o(), .iox_dat_i(32'd0), .iox_we_o(), .iox_sel_o(), .iox_stb_o(), .iox_ack_i(1'b0),
		.mtime_o(), .poweroff_o(), .reset_o()
	);

	// the host's receiver
	integer k;
	reg [7:0] c;
	reg [8*16-1:0] tail = 0;
	integer got_k = 0;
	always begin
		@(negedge tx);
		repeat (DIV + DIV / 2) @(posedge clk);
		for (k = 0; k < 8; k = k + 1) begin
			c[k] = tx;
			repeat (DIV) @(posedge clk);
		end
		$write("%c", c);
		tail = { tail[8*15-1:0], c };
		if (c == "K" && (got_k || SD != "")) begin
			$display("\n[tb] the loaded program ran: PASS");
			$finish;
		end
	end

	task send(input [7:0] ch);
		integer n;
		begin
			rx = 0; repeat (DIV) @(posedge clk);
			for (n = 0; n < 8; n = n + 1) begin
				rx = ch[n]; repeat (DIV) @(posedge clk);
			end
			rx = 1; repeat (DIV) @(posedge clk);
		end
	endtask
	task send32(input [31:0] v);
		begin send(v[7:0]); send(v[15:8]); send(v[23:16]); send(v[31:24]); end
	endtask

	initial begin
		repeat (20) @(posedge clk);
		rst = 0;
		wait (tail[8*7-1:0] == "ready\r\n");
		repeat (200) @(posedge clk);
		if (SD != "") begin
			// (it would have booted by itself had the memory come up)
			send("S");
			wait (0);
		end
		// li a0, 'K'; lui a1, 0x10000; sb a0, 0(a1); j .
		send("L"); send32(32'h8000_0000); send32(32'd16);
		send32(32'h04b0_0513); send32(32'h1000_05b7); send32(32'h00a5_8023); send32(32'h0000_006f);
		// sum of those sixteen bytes: 0x0000034f
		wait (tail[8*14-1:0] == "sum 0000034f\r\n");
		repeat (200) @(posedge clk);
		got_k = 1;
		send("G");
	end

	initial begin
		repeat (60000000) @(posedge clk);
		$display("\n[tb] TIMEOUT: FAIL");
		$finish;
	end

endmodule
