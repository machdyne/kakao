/*
 * kakao_top -- the Kakao SOC on one of Machdyne's ECP5 boards. Which
 * board is the pin file's and these (boards/Makefile sets them):
 *
 *   K_MEM_DDR3    main memory is 512 MB of DDR3, through Zeitlos's
 *                 controller and its clocking: the SOC's 48 MHz is
 *                 divided from the DDR3's 96 MHz edge clock, and the SOC
 *                 is in reset until that PLL has locked
 *   K_MEM_SDRAM   main memory is 32 MB of SDRAM, through Zeitlos's
 *                 controller; the SOC's clock is the board's 48 MHz
 *   K_VIDEO       the board has a DDMI connector: the terminal's picture
 *                 goes there, 640x480 as DVI (Zeitlos's pll1: 25.2 and
 *                 126 MHz from the 48 MHz, and its gpu_ddmi)
 *   K_USB         the board has USB host ports: the terminal's keyboard
 *   K_ETH         the board has an RMII Ethernet PHY: Zeitlos's MAC for
 *                 the I/O processor, which is Linux's network device.
 *                 With ETH_RMII_DRIVE_REFCLK (the MAC's own name for it)
 *                 the PHY's 50 MHz comes from here (Zeitlos's pll0);
 *                 without, the PHY makes it
 *
 * The pins have the names Zeitlos's pin files give them
 * (ext/zeitlos/boards), which are the same on every board.
 *
 * Every board has the Sechzig or its own UART for console 0 (1 Mbaud
 * 8N1) and the SD card on Zeitlos's SPI master; the boot ROM is
 * fw/kboot, which boots from the card or loads over the UART.
 *
 * With TERMINAL (K_VIDEO and K_USB), the hardware terminal: the
 * console is also drawn on the DDMI connector, 80 by 30 characters, by
 * the I/O processor (rtl/k_iop.v, rtl/k_text.v), a USB keyboard on
 * either host port types on it, and there are TERMS consoles in all,
 * each with its own terminal (Super with a digit changes between them).
 *
 * LED_B changes every 0.35 s while the clock runs.
 */

module kakao_top #(
	// (K_CPU64: kakao64, and kboot built for it)
`ifdef K_MEM_SDRAM
`ifdef K_CPU64
	parameter ROM_HEX = "kboot64-sdram",
`else
	parameter ROM_HEX = "kboot-sdram",	// fw/kboot, MEM=sdram: 8 KB
`endif
	parameter ROM_WORDS = 2048,
`else
`ifdef K_CPU64
	parameter ROM_HEX = "kboot64",
`else
	parameter ROM_HEX = "kboot",		// fw/kboot: 16 KB
`endif
	parameter ROM_WORDS = 4096,
`endif
`ifdef K_CPU64
	parameter CPU64 = 1,
`else
	parameter CPU64 = 0,
`endif
	parameter KCACHE = 1,			// 1: k_cache (and the DDR3's write combining); 0: Zeitlos's cache
	parameter I_KB = 16,			// k_cache's instruction and data caches
	parameter D_KB = 16,
	parameter BTFN = 0,				// the CPU's static branch prediction
	parameter TLB_BITS = 5,			// ...and its TLB: 2^TLB_BITS entries
	parameter FAST_MUL = 0,			// ...and its multiplier in DSP blocks
	parameter TERMINAL = 1,
	parameter TERMS = 1,			// consoles, each with a terminal
	parameter HIST = 0,				// screens of scroll buffer for the first
	parameter USB = 1,				// the terminal's keyboard: the USB host ports
	parameter VIRTIO = 2,			// virtio slots (the SD card as a disk, the network)
	parameter IOP_WORDS = 11264,		// the I/O processor's memory, in words
	// (K_IOP_HEADLESS: a board without a terminal, whose I/O processor
	// is the virtio devices alone)
`ifdef K_IOP_HEADLESS
	parameter IOP_HEX = "../iop/iop-headless.hex",
`else
	parameter IOP_HEX = "../iop/iop.hex",
`endif
	parameter FONT_HEX = "../iop/k_font.hex"
) (
	input         CLK_48,
`ifdef K_USB_CDC
	// the console is a USB serial port on the USB-C socket
	inout         usb_ufp_dp,
	inout         usb_ufp_dm,
	output        usb_ufp_pull,
`else
	output        UART0_TX,
	input         UART0_RX,
`endif
	output        LED_B,

	output        SD_SCK,
	output        SD_MOSI,
	output        SD_SS,
	input         SD_MISO,

`ifdef K_USB
	inout   [1:0] usb_host_dp,
	inout   [1:0] usb_host_dm,
`endif

`ifdef K_ETH
`ifdef ETH_RMII_DRIVE_REFCLK
	output        ETH_REFCLK,
`else
	input         ETH_REFCLK,
`endif
	input   [1:0] ETH_RXD,
	output  [1:0] ETH_TXD,
	output        ETH_TX_EN,
	input         ETH_CRS_DV,
	output        ETH_RST_N,
`endif

`ifdef K_VIDEO
	output        DDMI_CK_P,
	output        DDMI_D0_P,
	output        DDMI_D1_P,
	output        DDMI_D2_P,
`endif

`ifdef K_MEM_SDRAM
	output [12:0] sdram_a,
	output  [1:0] sdram_ba,
	output        sdram_ras_n,
	output        sdram_cas_n,
	output        sdram_we_n,
	output        sdram_cs_n,
	output        sdram_cke,
	output        sdram_clock,
	output  [1:0] sdram_dm,
	inout  [15:0] sdram_dq
`else
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
`endif
);

`ifdef K_MEM_SDRAM

	wire clk = CLK_48;

	// reset: for 2^16 cycles from power-on
	reg [16:0] rst_c = 17'd0;
	wire rst = !rst_c[16];
	wire soc_reset;
	always @(posedge clk) begin
		if (soc_reset) rst_c <= 17'd0;
		else if (rst) rst_c <= rst_c + 17'd1;
	end

`else

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

	// reset: for 2^16 cycles once the PLL has locked, and again when
	// the SOC asks for it
	reg [16:0] rst_c = 17'd0;
	wire rst = !rst_c[16];
	wire soc_reset;
	always @(posedge clk) begin
		if (!locked || soc_reset) rst_c <= 17'd0;	// (soc_reset: below)
		else if (rst) rst_c <= rst_c + 17'd1;
	end

`endif

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

	// ...and the I/O processor's: the same SPI master, at its 0x4000_0000,
	// when the card is Linux's disk. The master is the CPU's until the
	// I/O processor first asks for it, and the I/O processor's from then
	// on (to the CPU it then reads zero): kboot is done with the card
	// before Linux looks for its disk.
	wire [15:0] iox_adr;
	wire [31:0] iox_dat_w;
	wire        iox_stb, iox_we;
	wire  [3:0] iox_sel;
	reg         iox_nul, sd_iop;
	wire        x_sd = (iox_adr[15:12] == 4'd0);
	// (the network's MAC, below, at 0x4000_2000)
	wire        x_eth;
	wire [31:0] eth_dat_r;
	wire        eth_ack;
	always @(posedge clk) begin
		nul_ack <= ext_stb && !(s_sd && !sd_iop) && !nul_ack;
		iox_nul <= iox_stb && !x_sd && !x_eth && !iox_nul;
		if (rst) sd_iop <= 1'b0;
		else if (iox_stb && x_sd && !(ext_stb && s_sd)) sd_iop <= 1'b1;
	end
	wire        sd_stb = sd_iop ? (iox_stb && x_sd) : (ext_stb && s_sd);

	spim_wb sd_i (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i({ 30'd0, sd_iop ? iox_adr[3:2] : ext_adr[3:2] }),
		.wb_dat_i(sd_iop ? iox_dat_w : ext_dat_w), .wb_dat_o(sd_dat_r),
		.wb_we_i(sd_iop ? iox_we : ext_we), .wb_sel_i(sd_iop ? iox_sel : ext_sel),
		.wb_stb_i(sd_stb), .wb_ack_o(sd_ack),
		.wb_cyc_i(sd_stb),
		.spi_cs_n(SD_SS), .spi_sck(SD_SCK), .spi_mosi(SD_MOSI), .spi_miso(SD_MISO),
		.spi_int(1'b1), .dma_start_i(1'b0), .dma_busy_o()
	);

	// the network: Zeitlos's RMII MAC, the I/O processor's
`ifdef K_ETH
	assign x_eth = (iox_adr[15:13] == 3'd1);
	wire eth_refclk;
`ifdef ETH_RMII_DRIVE_REFCLK
	// the PHY's clock from here: 50 MHz, out through an I/O cell, as
	// the MAC's own outputs go (see there)
	pll0 pll0_i (.clkin(CLK_48), .clkout0(), .clkout1(), .clkout2(eth_refclk), .clkout3(), .locked());
	ODDRX1F eth_refclk_oddr (.SCLK(eth_refclk), .RST(1'b0), .D0(1'b1), .D1(1'b0), .Q(ETH_REFCLK));
`else
	assign eth_refclk = ETH_REFCLK;
`endif
	ethmac_rmii_wb eth_i (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i({ 21'd0, iox_adr[12:2] }), .wb_dat_i(iox_dat_w), .wb_dat_o(eth_dat_r),
		.wb_we_i(iox_we), .wb_sel_i(iox_sel), .wb_stb_i(iox_stb && x_eth), .wb_ack_o(eth_ack),
		.wb_cyc_i(iox_stb && x_eth),
		.eth_refclk(eth_refclk), .eth_rxd(ETH_RXD), .eth_txd(ETH_TXD), .eth_tx_en(ETH_TX_EN),
		.eth_crs_dv(ETH_CRS_DV), .eth_rst_n(ETH_RST_N), .eth_int_o()
	);
`else
	assign x_eth = 1'b0;
	assign eth_dat_r = 32'd0;
	assign eth_ack = 1'b0;
`endif

	// ---- the console over USB ----
	// (K_USB_CDC: the boards whose serial console is the USB-C socket.
	// Zeitlos's CDC-ACM device, a byte each way; it stays attached through
	// a reset of the machine, so the host's port does not go away on a
	// reboot)
	wire       con_tx_valid, con_tx_ready, con_rx_valid, con_rx_ready;
	wire [7:0] con_tx_data, con_rx_data;
`ifdef K_USB_CDC
	reg [12:0] cdc_c = 13'd0;
	wire cdc_rst = !cdc_c[12];
	always @(posedge clk) if (cdc_rst) cdc_c <= cdc_c + 13'd1;
	wire cdc_pu, cdc_tx_en, cdc_dp_tx, cdc_dn_tx;
	// No host (a charger, a cable for power alone): nothing takes what
	// the machine prints, and it must not wait for that. As in Zeitlos:
	// two seconds after power on with no frame from a host and no
	// configuration, what is printed is dropped, until a host turns up.
	wire        cdc_ready, cdc_conf;
	wire [10:0] cdc_frame;
	reg  [10:0] cdc_last = 11'd0;
	reg  [26:0] host_c = 27'd0;
	reg         host_seen = 1'b0;
	wire        no_host = !host_seen && host_c == 27'd96_000_000;
	always @(posedge clk) begin
		cdc_last <= cdc_frame;
		if (cdc_rst) begin host_c <= 27'd0; host_seen <= 1'b0; end
		else begin
			if (cdc_conf || cdc_frame != cdc_last) host_seen <= 1'b1;
			if (host_c != 27'd96_000_000) host_c <= host_c + 27'd1;
		end
	end
	assign con_tx_ready = cdc_ready || no_host;
	usb_cdc #(
		.VENDORID(16'h16d0), .PRODUCTID(16'h116d),
		.CHANNELS(1),
		.IN_BULK_MAXPACKETSIZE(8), .OUT_BULK_MAXPACKETSIZE(8),
		.BIT_SAMPLES(4),
		.USE_APP_CLK(0), .APP_CLK_FREQ(48)
	) cdc (
		.clk_i(clk), .rstn_i(!cdc_rst), .app_clk_i(clk),
		.out_data_o(con_rx_data), .out_valid_o(con_rx_valid), .out_ready_i(con_rx_ready),
		.in_data_i(con_tx_data), .in_valid_i(con_tx_valid && !no_host), .in_ready_o(cdc_ready),
		.frame_o(cdc_frame), .configured_o(cdc_conf),
		.dp_pu_o(cdc_pu), .tx_en_o(cdc_tx_en), .dp_tx_o(cdc_dp_tx), .dn_tx_o(cdc_dn_tx),
		.dp_rx_i(usb_ufp_dp), .dn_rx_i(usb_ufp_dm)
	);
	assign usb_ufp_dp = cdc_tx_en ? cdc_dp_tx : 1'bz;
	assign usb_ufp_dm = cdc_tx_en ? cdc_dn_tx : 1'bz;
	assign usb_ufp_pull = cdc_pu ? 1'b1 : 1'bz;
`else
	assign con_tx_ready = 1'b1;
	assign con_rx_valid = 1'b0;
	assign con_rx_data = 8'd0;
`endif

	kakao_soc #(
		.CPU64(CPU64), .KCACHE(KCACHE), .I_KB(I_KB), .D_KB(D_KB), .BTFN(BTFN), .TLB_BITS(TLB_BITS), .FAST_MUL(FAST_MUL),
		.TERMINAL(TERMINAL), .TERMS(TERMS), .HIST(HIST), .IOP_HEX(IOP_HEX), .FONT_HEX(FONT_HEX),
		.USB(USB), .IOP_WORDS(IOP_WORDS), .VIRTIO(VIRTIO),
		.CACHE_KB(32),
		.ROM_WORDS(ROM_WORDS),
		.ROM_HEX(ROM_HEX),
		.UART_DIV(48),
`ifdef K_USB_CDC
		.UART_PIPE(1)
`else
		.UART_PIPE(0)
`endif
	) soc (
		.clk(clk), .rst(rst),
		.mem_adr_o(mem_adr), .mem_dat_o(mem_dat_w), .mem_dat_i(mem_dat_r),
		.mem_we_o(mem_we), .mem_sel_o(mem_sel), .mem_stb_o(mem_stb), .mem_ack_i(mem_ack),
		.reg_adr_o(reg_adr), .reg_dat_o(reg_dat_w), .reg_dat_i(reg_dat_r),
		.reg_we_o(reg_we), .reg_stb_o(reg_stb), .reg_ack_i(reg_ack),
		.ext_adr_o(ext_adr), .ext_dat_o(ext_dat_w), .ext_dat_i((s_sd && !sd_iop) ? sd_dat_r : 32'd0),
		.ext_we_o(ext_we), .ext_sel_o(ext_sel),
		.ext_stb_o(ext_stb), .ext_ack_i((s_sd && !sd_iop) ? sd_ack : nul_ack),
		.iox_adr_o(iox_adr), .iox_dat_o(iox_dat_w), .iox_dat_i(x_sd ? sd_dat_r : x_eth ? eth_dat_r : 32'd0),
		.iox_we_o(iox_we), .iox_sel_o(iox_sel),
		.iox_stb_o(iox_stb), .iox_ack_i(x_sd ? (sd_iop && sd_ack) : x_eth ? eth_ack : iox_nul),
`ifdef K_USB_CDC
		.uart0_rx(1'b1), .uart0_tx(),
`else
		.uart0_rx(UART0_RX), .uart0_tx(UART0_TX),
`endif
		.con_tx_valid(con_tx_valid), .con_tx_data(con_tx_data), .con_tx_ready(con_tx_ready),
		.con_rx_valid(con_rx_valid), .con_rx_data(con_rx_data), .con_rx_ready(con_rx_ready),
		.pclk(pclk), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
		.vid_hsync(vid_hs), .vid_vsync(vid_vs), .vid_blank(vid_bl),
		.iop_trap(),
`ifdef K_USB
		.usb_dp(usb_host_dp), .usb_dm(usb_host_dm),
`else
		.usb_dp(), .usb_dm(),
`endif
		.mtime_o(mtime), .poweroff_o(), .reset_o(soc_reset)
	);

`ifdef K_MEM_SDRAM

	// 32 MB: the controller's addresses are of bytes; it has no
	// registers of its own
	wire sdram_ck;
	assign sdram_clock = sdram_ck;
	assign reg_dat_r = 32'd0;
	assign reg_ack = reg_stb;

	sdram_wb #(
		.SDRAM_CLK_FREQ(48),
		.BURST(0)
	) sdram_i (
		.wb_clk_i(clk),
		.wb_rst_i(rst),
		.wb_adr_i({ mem_adr[22:0], 2'b00 }),
		.wb_dat_i(mem_dat_w),
		.wb_dat_o(mem_dat_r),
		.wb_we_i(mem_we),
		.wb_sel_i(mem_sel),
		.wb_stb_i(mem_stb),
		.wb_ack_o(mem_ack),
		.wb_cyc_i(mem_stb),
		.wb_cti_i(3'b000),
		.sdram_clk(sdram_ck),
		.sdram_cke(sdram_cke),
		.sdram_csn(sdram_cs_n),
		.sdram_rasn(sdram_ras_n),
		.sdram_casn(sdram_cas_n),
		.sdram_wen(sdram_we_n),
		.sdram_addr(sdram_a),
		.sdram_ba(sdram_ba),
		.sdram_dq(sdram_dq),
		.sdram_dqm(sdram_dm)
	);

`else

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

`endif

	assign LED_B = mtime[24];

	// ------------------------------------------------------------
	// the terminal's picture, onto the DDMI connector as DVI
	// ------------------------------------------------------------

`ifdef K_VIDEO
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
`else
	assign pclk = 1'b0;
	assign bclk = 1'b0;
`endif

endmodule
