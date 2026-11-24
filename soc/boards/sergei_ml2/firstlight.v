/*
 * firstlight -- kakao32 alive on a board, before there is a SOC:
 * the CPU on the board's 48 MHz clock with 64 KB of block RAM, the
 * CLINT and the UART, running soc/fw/firstlight from that RAM. (With
 * FIRSTLIGHT_PLL24 defined, at 24 MHz through a PLL instead, and
 * UART_DIV 24: the fallback if the 48 MHz build misbehaves, since its
 * timing margin is a few percent.) It
 * tests the CPU on the FPGA (arithmetic, traps, the timer interrupt,
 * the atomics, Sv32 in S-mode) and reports on the console, 1 Mbaud
 * 8N1, then echoes what is typed. LED_B changes every 0.35 s (0.7 s
 * at 24 MHz) while the clock runs.
 *
 * Nothing here is specific to Sergei ML2 but the pin file.
 */

module firstlight #(
	parameter UART_DIV = 48,		// clock / 1 Mbaud
	parameter FW_PREFIX = "firstlight"
) (
	input  CLK_48,
	output UART0_TX,
	input  UART0_RX,
	output LED_B
);

	wire clk, locked;

`ifndef FIRSTLIGHT_PLL24
	assign clk = CLK_48;
	assign locked = 1'b1;
`else
	// 48 MHz / 2 * 25 = 600 MHz in the VCO, / 25 = 24 MHz (ecppll)
	(* FREQUENCY_PIN_CLKI="48" *)
	(* FREQUENCY_PIN_CLKOP="24" *)
	(* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
	EHXPLLL #(
		.PLLRST_ENA("DISABLED"),
		.INTFB_WAKE("DISABLED"),
		.STDBY_ENABLE("DISABLED"),
		.DPHASE_SOURCE("DISABLED"),
		.OUTDIVIDER_MUXA("DIVA"),
		.OUTDIVIDER_MUXB("DIVB"),
		.OUTDIVIDER_MUXC("DIVC"),
		.OUTDIVIDER_MUXD("DIVD"),
		.CLKI_DIV(2),
		.CLKOP_ENABLE("ENABLED"),
		.CLKOP_DIV(25),
		.CLKOP_CPHASE(12),
		.CLKOP_FPHASE(0),
		.FEEDBK_PATH("CLKOP"),
		.CLKFB_DIV(1)
	) pll_i (
		.RST(1'b0),
		.STDBY(1'b0),
		.CLKI(CLK_48),
		.CLKOP(clk),
		.CLKFB(clk),
		.CLKINTFB(),
		.PHASESEL0(1'b0),
		.PHASESEL1(1'b0),
		.PHASEDIR(1'b1),
		.PHASESTEP(1'b1),
		.PHASELOADREG(1'b1),
		.PLLWAKESYNC(1'b0),
		.ENCLKOP(1'b0),
		.LOCK(locked)
	);
`endif

	// reset: for 2^16 cycles once the PLL has locked
	reg [16:0] rst_c = 17'd0;
	wire rst = !rst_c[16];
	always @(posedge clk) begin
		if (!locked) rst_c <= 17'd0;
		else if (rst) rst_c <= rst_c + 17'd1;
	end

	wire        m_req, m_we, m_instr;
	wire [31:0] m_adr, m_wdat;
	wire  [3:0] m_sel;
	reg         m_ack;

	wire [63:0] mtime;
	wire        irq_msi, irq_mti;

	wire [31:0] m_rdat;

	kakao32 #(
		.RESET_PC(32'h8000_0000)
	) cpu (
		.clk(clk), .rst(rst),
		.m_req(m_req), .m_adr(m_adr), .m_we(m_we), .m_sel(m_sel),
		.m_wdat(m_wdat), .m_instr(m_instr),
		.m_rdy(1'b1), .m_ack(m_ack), .m_rdat(m_rdat),
		.mtime(mtime),
		.irq_msi(irq_msi), .irq_mti(irq_mti), .irq_mei(1'b0), .irq_sei(1'b0)
	);

	wire is_ram   = (m_adr[31:16] == 16'h8000);
	wire is_clint = (m_adr[31:16] == 16'h0200);
	wire is_uart  = (m_adr[31:8]  == 24'h100000);

	// 64 KB in four byte lanes, each its own block RAM
	reg [7:0] ram0 [0:16383];
	reg [7:0] ram1 [0:16383];
	reg [7:0] ram2 [0:16383];
	reg [7:0] ram3 [0:16383];
	reg [31:0] ram_q;

	initial begin
		$readmemh({FW_PREFIX, ".0.hex"}, ram0);
		$readmemh({FW_PREFIX, ".1.hex"}, ram1);
		$readmemh({FW_PREFIX, ".2.hex"}, ram2);
		$readmemh({FW_PREFIX, ".3.hex"}, ram3);
	end

	wire ram_we = m_req && m_we && is_ram;
	always @(posedge clk) begin
		if (ram_we && m_sel[0]) ram0[m_adr[15:2]] <= m_wdat[7:0];
		if (ram_we && m_sel[1]) ram1[m_adr[15:2]] <= m_wdat[15:8];
		if (ram_we && m_sel[2]) ram2[m_adr[15:2]] <= m_wdat[23:16];
		if (ram_we && m_sel[3]) ram3[m_adr[15:2]] <= m_wdat[31:24];
		ram_q <= { ram3[m_adr[15:2]], ram2[m_adr[15:2]], ram1[m_adr[15:2]], ram0[m_adr[15:2]] };
	end

	wire [31:0] clint_q, uart_q;

	k_clint clint_i (
		.clk(clk), .rst(rst),
		.req(m_req && is_clint), .we(m_we), .adr(m_adr[15:2]),
		.wdat(m_wdat), .rdat(clint_q),
		.mtime(mtime), .irq_msi(irq_msi), .irq_mti(irq_mti)
	);

	k_uart #(.DIV(UART_DIV)) uart_i (
		.clk(clk), .rst(rst),
		.req(m_req && is_uart), .we(m_we), .adr2(m_adr[2]), .sel(m_sel),
		.wdat(m_wdat), .rdat(uart_q),
		.lx(1'b0), .irq(),
		.st_rxv(), .st_rxd(), .st_txbusy(),
		.tap(), .hold(1'b0), .inj(1'b0), .inj_d(8'd0),
		.rx(UART0_RX), .tx(UART0_TX)
	);

	// every request is answered the next cycle
	reg  [1:0] q_dev;
	reg [31:0] q_io;
	always @(posedge clk) begin
		m_ack <= !rst && m_req;
		q_dev <= is_ram ? 2'd0 : 2'd1;
		q_io  <= is_clint ? clint_q : is_uart ? uart_q : 32'd0;
	end
	assign m_rdat = (q_dev == 2'd0) ? ram_q : q_io;

	assign LED_B = mtime[24];

endmodule
