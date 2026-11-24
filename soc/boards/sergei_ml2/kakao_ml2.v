/*
 * kakao_ml2 -- the Kakao SOC on Sergei with a Sechzig ML2: kakao_soc
 * with Zeitlos's DDR3 controller and clocking for main memory (512 MB)
 * and the Sechzig UART for the console, 1 Mbaud 8N1.
 *
 * The clock is the DDR3's: 48 MHz divided from its 96 MHz edge clock
 * (ext/zeitlos/rtl/mem/ddr3_clk.v), so the SOC is in reset until that
 * PLL has locked. The boot ROM is soc/fw/kboot: it trains the DDR3,
 * takes OpenSBI, the kernel, the device tree and the root file system
 * over the UART, and starts OpenSBI.
 *
 * LED_B changes every 0.35 s while the clock runs.
 *
 * With TERMINAL, the hardware terminal: the console is also drawn on
 * the DDMI connector, 80 by 30 characters at 640x480 (DVI), by the
 * I/O processor (rtl/k_iop.v, rtl/k_text.v). The picture's clocks are
 * Zeitlos's (pll1: 25.2 and 126 MHz from the 48 MHz), and so is the
 * way onto the connector (gpu_ddmi and its encoders).
 *
 * The SD card is on Zeitlos's SPI master, and kboot boots from it.
 *
 * With USB (and TERMINAL), the two USB host ports are the I/O
 * processor's, through Zeitlos's host controller: a keyboard on either,
 * behind a hub or not, types on the terminal.
 */

module kakao_ml2 #(
	parameter ROM_HEX = "kboot",
	parameter KCACHE = 1,			// 1: k_cache and the DDR3's write combining; 0: Zeitlos's cache
	parameter I_KB = 16,			// k_cache's instruction and data caches
	parameter D_KB = 16,
	parameter BTFN = 0,				// the CPU's static branch prediction
	parameter FAST_MUL = 0,			// ...and its multiplier in DSP blocks
	parameter TERMINAL = 1,
	parameter USB = 1,				// the terminal's keyboard: the two USB host ports
	parameter IOP_WORDS = 12288,	// the I/O processor's memory, in words
	parameter IOP_HEX = "../iop/iop.hex",
	parameter FONT_HEX = "../iop/k_font.hex"
) (
	input         CLK_48,
	output        UART0_TX,
	input         UART0_RX,
	output        LED_B,

	output        SD_SCK,
	output        SD_MOSI,
	output        SD_SS,
	input         SD_MISO,

	inout   [1:0] usb_host_dp,
	inout   [1:0] usb_host_dm,

	output        DDMI_CK_P,
	output        DDMI_D0_P,
	output        DDMI_D1_P,
	output        DDMI_D2_P,

	output [15:0] ddr3_a,
	output  [2:0] ddr3_ba,
	output        ddr3_ras_n,
	output        ddr3_cas_n,
	output        ddr3_we_n,
	output        ddr3_cs_n,
	output        ddr3_cke,
	output        ddr3_odt,
	output        ddr3_reset_n,
	output  [1:0] ddr3_dm,
	inout  [15:0] ddr3_dq,
	inout   [1:0] ddr3_dqs_p,
	output        ddr3_clk_p
);

	wire clk, eclk, ddrdel, pause, phy_rst, phy_ready, locked;

	ddr3_clk ddr3_clk_i (
		.clk48_i(CLK_48),
		.rst_i(1'b0),
		.sys_clk_o(clk),
		.eclk_o(eclk),
		.ddrdel_o(ddrdel),
		.pause_o(pause),
		.phy_rst_o(phy_rst),
		.ready_o(phy_ready),
		.locked_o(locked)
	);

	// reset: for 2^16 cycles once the PLL has locked
	reg [16:0] rst_c = 17'd0;
	wire rst = !rst_c[16];
	always @(posedge clk) begin
		if (!locked) rst_c <= 17'd0;
		else if (rst) rst_c <= rst_c + 17'd1;
	end

	wire [26:0] mem_adr;
	wire [31:0] mem_dat_w, mem_dat_r;
	wire        mem_we, mem_stb, mem_ack;
	wire  [3:0] mem_sel;

	wire  [1:0] reg_adr;
	wire [31:0] reg_dat_w, reg_dat_r;
	wire        reg_we, reg_stb, reg_ack;

	wire [63:0] mtime;

	// the picture
	wire        pclk, bclk;
	wire  [7:0] vid_r, vid_g, vid_b;
	wire        vid_hs, vid_vs, vid_bl;

	// the board's own devices: the SD card, on Zeitlos's SPI master, at
	// 0x0300_0800 (kboot boots from it); any other such address reads zero
	wire [31:0] ext_adr, ext_dat_w, sd_dat_r;
	wire        ext_stb, ext_we, sd_ack;
	wire  [3:0] ext_sel;
	reg         nul_ack;
	wire        s_sd = (ext_adr[31:8] == 24'h030008);
	always @(posedge clk) nul_ack <= ext_stb && !s_sd && !nul_ack;

	spim_wb sd_i (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i({ 30'd0, ext_adr[3:2] }), .wb_dat_i(ext_dat_w), .wb_dat_o(sd_dat_r),
		.wb_we_i(ext_we), .wb_sel_i(ext_sel), .wb_stb_i(ext_stb && s_sd), .wb_ack_o(sd_ack),
		.wb_cyc_i(ext_stb && s_sd),
		.spi_cs_n(SD_SS), .spi_sck(SD_SCK), .spi_mosi(SD_MOSI), .spi_miso(SD_MISO),
		.spi_int(1'b1), .dma_start_i(1'b0), .dma_busy_o()
	);

	kakao_soc #(
		.KCACHE(KCACHE), .I_KB(I_KB), .D_KB(D_KB), .BTFN(BTFN), .FAST_MUL(FAST_MUL),
		.TERMINAL(TERMINAL), .IOP_HEX(IOP_HEX), .FONT_HEX(FONT_HEX),
		.USB(USB), .IOP_WORDS(IOP_WORDS),
		.CACHE_KB(32),
		.ROM_WORDS(4096),
		.ROM_HEX(ROM_HEX),
		.UART_DIV(48)
	) soc (
		.clk(clk), .rst(rst),
		.mem_adr_o(mem_adr), .mem_dat_o(mem_dat_w), .mem_dat_i(mem_dat_r),
		.mem_we_o(mem_we), .mem_sel_o(mem_sel), .mem_stb_o(mem_stb), .mem_ack_i(mem_ack),
		.reg_adr_o(reg_adr), .reg_dat_o(reg_dat_w), .reg_dat_i(reg_dat_r),
		.reg_we_o(reg_we), .reg_stb_o(reg_stb), .reg_ack_i(reg_ack),
		.ext_adr_o(ext_adr), .ext_dat_o(ext_dat_w), .ext_dat_i(s_sd ? sd_dat_r : 32'd0),
		.ext_we_o(ext_we), .ext_sel_o(ext_sel),
		.ext_stb_o(ext_stb), .ext_ack_i(s_sd ? sd_ack : nul_ack),
		.uart0_rx(UART0_RX), .uart0_tx(UART0_TX),
		.pclk(pclk), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
		.vid_hsync(vid_hs), .vid_vsync(vid_vs), .vid_blank(vid_bl),
		.iop_trap(),
		.usb_dp(usb_host_dp), .usb_dm(usb_host_dm),
		.mtime_o(mtime), .poweroff_o()
	);

	ddr3 #(
		.ROW_BITS(15),
		.TRFC_NS(260),
		.WCOMBINE(KCACHE)
	) ddr3_i (
		.clk_i(clk),
		.rst_i(rst),
		.eclk_i(eclk),
		.ddrdel_i(ddrdel),
		.pause_i(pause),
		.phy_rst_i(phy_rst),
		.phy_ready_i(phy_ready),
		.pll_locked_i(locked),

		.wb_adr_i(mem_adr),
		.wb_dat_i(mem_dat_w),
		.wb_dat_o(mem_dat_r),
		.wb_we_i(mem_we),
		.wb_sel_i(mem_sel),
		.wb_stb_i(mem_stb),
		.wb_cyc_i(mem_stb),
		.wb_ack_o(mem_ack),

		.reg_adr_i(reg_adr),
		.reg_dat_i(reg_dat_w),
		.reg_dat_o(reg_dat_r),
		.reg_we_i(reg_we),
		.reg_stb_i(reg_stb),
		.reg_cyc_i(reg_stb),
		.reg_ack_o(reg_ack),

		.ddr3_a(ddr3_a), .ddr3_ba(ddr3_ba),
		.ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
		.ddr3_we_n(ddr3_we_n), .ddr3_cs_n(ddr3_cs_n),
		.ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
		.ddr3_reset_n(ddr3_reset_n),
		.ddr3_dm(ddr3_dm), .ddr3_dq(ddr3_dq),
		.ddr3_dqs_p(ddr3_dqs_p), .ddr3_clk_p(ddr3_clk_p)
	);

	assign LED_B = mtime[24];

	// ------------------------------------------------------------
	// the terminal's picture, onto the DDMI connector as DVI
	// ------------------------------------------------------------

	generate if (TERMINAL) begin : video

		wire pll1_locked;
		pll1 pll1_i (.clkin(CLK_48), .clkout0(bclk), .clkout1(pclk), .locked(pll1_locked));

		wire [1:0] t_r, t_g, t_b, t_c;
		gpu_ddmi #(.ISLANDS(0)) ddmi_i (
			.pclk(pclk), .tmds_clk(bclk),
			.hc(11'd0), .vc(11'd0),
			.islands_en(1'b0), .sound_en(1'b0), .fs_code(4'd0),
			.acr_n(20'd0), .acr_cts(20'd0),
			.aud_clk(clk), .aud_we(1'b0), .aud_wdata(32'd0),
			.in_vga_red(vid_r), .in_vga_green(vid_g), .in_vga_blue(vid_b),
			.in_vga_blank(vid_bl), .in_vga_vsync(vid_vs), .in_vga_hsync(vid_hs),
			.out_tmds_red(t_r), .out_tmds_green(t_g), .out_tmds_blue(t_b), .out_tmds_clk(t_c)
		);

		// two bits a 126 MHz clock; lanes as Zeitlos has them: D2 red,
		// D1 green, D0 blue (and the syncs)
		ODDRX1F o_ck (.D0(t_c[0]), .D1(t_c[1]), .Q(DDMI_CK_P), .SCLK(bclk), .RST(1'b0));
		ODDRX1F o_d2 (.D0(t_r[0]), .D1(t_r[1]), .Q(DDMI_D2_P), .SCLK(bclk), .RST(1'b0));
		ODDRX1F o_d1 (.D0(t_g[0]), .D1(t_g[1]), .Q(DDMI_D1_P), .SCLK(bclk), .RST(1'b0));
		ODDRX1F o_d0 (.D0(t_b[0]), .D1(t_b[1]), .Q(DDMI_D0_P), .SCLK(bclk), .RST(1'b0));

	end else begin : novideo

		assign pclk = 1'b0;
		assign bclk = 1'b0;
		assign { DDMI_CK_P, DDMI_D0_P, DDMI_D1_P, DDMI_D2_P } = 4'b0000;

	end endgenerate

endmodule
