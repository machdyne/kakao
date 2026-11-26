/*
 * kakao_soc -- the Kakao SOC, as far as it goes: kakao32, the cache,
 * and the devices that are the same on every board. The board's top
 * level adds the clock, main memory behind the mem_* port (DDR3 or
 * SDRAM, with its own registers behind reg_*), and the pins.
 *
 * The machine is QEMU's RISC-V virt, as soc/docs/design.md lays it out:
 *
 *   0x0000_1000   boot memory: block RAM, ROM_WORDS words, writable (the
 *                 boot program's data and stack are in it too), loaded
 *                 from ROM_HEX.0.hex .. ROM_HEX.3.hex, a byte lane each
 *   0x0010_0000   reset and power-off (a write of 0x5555: poweroff_o)
 *   0x0200_0000   CLINT
 *   0x0c00_0000   PLIC (k_plic.v): source 10 is UART 0, sources 1 to 9
 *                 the consoles after it
 *   0x1000_0100   ... 0x1000_0900: with TERMS, TERMS - 1 more consoles,
 *                 16550s of which only the registers exist (k_vcon.v):
 *                 each is a terminal of the I/O processor's
 *   0x0300_0100   the cache's registers: word 4 (0x0300_0110) bit 0
 *                 turns it on (k_cache.v; with Zeitlos's cache, its
 *                 data side, and bit 2 its write buffer)
 *   0x0300_0700   main memory's registers (reg_*, four words)
 *   0x1000_0000   UART 0
 *   0xf000_1000   UART 0 again, through a LiteX UART's registers (with
 *                 LITEUART): the prebuilt Kakao kernel has no other
 *                 console driver
 *   0x0300_1000   with FB, the framebuffer's registers: word 0 bit 0 is
 *                 8 bits a pixel (16 without it), bits 31..16 the blocks
 *                 that came too late for the screen, counted; from
 *                 0x0300_1400 the 256 colours of the 8 bit picture, a
 *                 word each, 0x00rrggbb (write only)
 *   0x8000_0000   main memory, up to 512 MB
 *   anything else the board's own devices (ext_*)
 *
 * With TERMINAL, the I/O processor and the text mode (k_iop.v,
 * k_text.v): the terminal, on UART 0's characters.
 *
 * With FB (and TERMINAL, and KCACHE), a framebuffer: 4 MB of main
 * memory, the ones whose address bits 28..22 are FB_AT, are not cached
 * (k_cache.v), and 640 by 480 pixels from their beginning are read out
 * as the screen is drawn (k_fb.v) and shown where a terminal would be
 * when the I/O processor says so (k_text.v's GRAPHICS). The memory
 * behind mem_* then has a second port, fb_*, on which a whole block of
 * 16 bytes is read at once, and which it answers before mem_*.
 *
 *   0x1000_1000   the virtio slots, VIRTIO of them, 4 KB each (k_virtio.v;
 *                 with TERMINAL: the I/O processor is the devices):
 *                 PLIC sources 12 and up
 *
 * The cache is k_cache.v with KCACHE, and without it Zeitlos's
 * wb_cache_one as it is, which was the first to work and is kept to
 * compare with. Zeitlos's has Zeitlos's memory map built in, main
 * memory at 0x4000_0000 and its own registers at 0x7000_0100, so for
 * it the CPU's addresses are moved on the way in, and the bus behind
 * either cache has main memory at 0x4000_0000.
 */

module kakao_soc #(
	parameter CPU64     = 0,		// 1: kakao64, on the cache through k_port64
	parameter KCACHE    = 0,		// 1: k_cache (I_KB, D_KB); 0: Zeitlos's (CACHE_KB)
	parameter CACHE_KB  = 8,
	parameter I_KB      = 16,
	parameter D_KB      = 16,
	parameter ROM_WORDS = 1024,
	parameter ROM_HEX   = "boot",
	parameter UART_DIV  = 48,
	parameter LITEUART  = 1,
	parameter CLINT_TICK = 1,
	parameter BTFN      = 0,		// the CPU's static branch prediction
	parameter FAST_MUL  = 0,
	parameter BTB_BITS  = 6,
	parameter TLB_BITS  = 5,		// ...and its TLB: 2^TLB_BITS entries		// ...and its branch target buffer (0: none)		// ...and its multiplier in DSP blocks, not 32 steps
	parameter UART_PIPE = 0,		// 1: UART 0 is a pipe of bytes (con_*), not pins
	parameter TERMINAL  = 0,		// 1: the I/O processor and the text mode
	parameter IOP_HEX   = "iop.hex",
	parameter IOP_WORDS = 11264,		// the I/O processor's memory, in words (fw/iop: RAM_BYTES)
	parameter TERMS     = 1,		// with TERMINAL: consoles, each with a terminal (1..10)
	parameter HIST      = 0,		// ...and screens of scroll buffer for the first (0..3)
	parameter USB       = 0,		// 1: with TERMINAL, its USB host controller: the keyboard
	parameter VIRTIO    = 0,		// with KCACHE: virtio slots, 0..4. Without TERMINAL the
								// I/O processor is there for them alone (IOP_HEX is then
								// fw/iop's iop-headless.hex, and IOP_WORDS its size)
	parameter FB        = 0,		// 1: with TERMINAL and KCACHE, a framebuffer in main memory
	parameter [6:0] FB_AT = 7'h7f,	// ...its 4 MB: address bits 28..22 (0x7f: the top of 512 MB)
	parameter FB_SHOW   = 0,		// ...shown from reset (a simulation without a keyboard)
	parameter USB_T_MS  = 48000,	// clock cycles a millisecond (the USB core needs 48 MHz)
	parameter FONT_HEX  = "k_font.hex"
) (
	input         clk,
	input         rst,

	// main memory: a Wishbone master, word addresses, 512 MB
	output [26:0] mem_adr_o,
	output [31:0] mem_dat_o,
	input  [31:0] mem_dat_i,
	output        mem_we_o,
	output  [3:0] mem_sel_o,
	output        mem_stb_o,
	input         mem_ack_i,

	// main memory's second port (FB): a block of 16 bytes read at once,
	// the lowest address in the lowest bits; fb_stb is held until fb_ack
	output        fb_stb_o,
	output [24:0] fb_adr_o,
	input         fb_ack_i,
	input [127:0] fb_dat_i,

	// main memory's registers
	output  [1:0] reg_adr_o,
	output [31:0] reg_dat_o,
	input  [31:0] reg_dat_i,
	output        reg_we_o,
	output        reg_stb_o,
	input         reg_ack_i,

	// everything this module does not decode itself: the board's own
	// devices, full addresses
	output [31:0] ext_adr_o,
	output [31:0] ext_dat_o,
	input  [31:0] ext_dat_i,
	output        ext_we_o,
	output  [3:0] ext_sel_o,
	output        ext_stb_o,
	input         ext_ack_i,

	input         uart0_rx,
	output        uart0_tx,
	// UART_PIPE: UART 0 has no pins, and its bytes go here (the USB
	// console: k_uart.v says how)
	output        con_tx_valid,
	output  [7:0] con_tx_data,
	input         con_tx_ready,
	input         con_rx_valid,
	input   [7:0] con_rx_data,
	output        con_rx_ready,

	// the terminal's picture (TERMINAL): 640x480 on the pixel clock
	input         pclk,
	output  [7:0] vid_r,
	output  [7:0] vid_g,
	output  [7:0] vid_b,
	output        vid_hsync,
	output        vid_vsync,
	output        vid_blank,
	output        iop_trap,

	// the I/O processor's USB host ports (USB)
	inout   [1:0] usb_dp,
	inout   [1:0] usb_dm,

	// the I/O processor's devices on the board (the SD card, the
	// network): a Wishbone master, 64 KB
	output [15:0] iox_adr_o,
	output [31:0] iox_dat_o,
	input  [31:0] iox_dat_i,
	output        iox_we_o,
	output  [3:0] iox_sel_o,
	output        iox_stb_o,
	input         iox_ack_i,

	output [63:0] mtime_o,
	output reg    poweroff_o,
	// one cycle: the machine is to be reset, all of it (the host has
	// written 0x7777 to the test device, as OpenSBI does for a reboot,
	// or it was asked for in the terminal's menus)
	output reg    reset_o
);

	// ------------------------------------------------------------
	// the CPU
	// ------------------------------------------------------------

	wire        c_req, c_we, c_instr, c_rdy, c_ack, c_idle;
	wire [31:0] c_adr, c_wdat, c_rdat;
	wire  [3:0] c_sel;
	wire [63:0] mtime;
	wire        irq_msi, irq_mti, irq_mei, irq_sei;
	wire        c_fencei;

	// the I/O processor's way to main memory
	wire        p_req, p_we, p_ack;
	wire        virt_hold;			// the CPU's access waits for the I/O processor
	wire [28:0] p_adr;
	wire  [3:0] p_sel;
	wire [31:0] p_wdat, p_rdat;

	assign mtime_o = mtime;

	generate if (CPU64 != 0) begin : c64

		wire        x_req, x_we, x_instr, x_rdy, x_ack;
		wire [31:0] x_adr;
		wire  [7:0] x_sel;
		wire        x_dbl;
		wire [63:0] x_wdat, x_rdat;

		kakao64 #(
			.RESET_PC(64'h0000_0000_0000_1000),
			.BTFN(BTFN),
			.FAST_MUL(FAST_MUL),
			.BTB_BITS(BTB_BITS),
			.TLB_BITS(TLB_BITS)
		) cpu (
			.clk(clk), .rst(rst),
			.m_req(x_req), .m_adr(x_adr), .m_dbl(x_dbl), .m_we(x_we), .m_sel(x_sel),
			.m_wdat(x_wdat), .m_instr(x_instr),
			.m_rdy(x_rdy), .m_ack(x_ack), .m_rdat(x_rdat),
			.fencei(c_fencei),
			.mtime(mtime),
			.irq_msi(irq_msi), .irq_mti(irq_mti), .irq_mei(irq_mei), .irq_sei(irq_sei)
		);

		k_port64 port_i (
			.clk(clk), .rst(rst),
			.m_req(x_req), .m_adr(x_adr), .m_dbl(x_dbl), .m_we(x_we), .m_sel(x_sel),
			.m_wdat(x_wdat), .m_instr(x_instr),
			.m_rdy(x_rdy), .m_ack(x_ack), .m_rdat(x_rdat),
			.c_req(c_req), .c_adr(c_adr), .c_we(c_we), .c_sel(c_sel),
			.c_wdat(c_wdat), .c_instr(c_instr),
			.c_rdy(c_rdy), .c_ack(c_ack), .c_rdat(c_rdat)
		);

	end else begin : c32

		kakao32 #(
			.RESET_PC(32'h0000_1000),
			.BTFN(BTFN),
			.FAST_MUL(FAST_MUL),
			.BTB_BITS(BTB_BITS),
			.TLB_BITS(TLB_BITS)
		) cpu (
			.clk(clk), .rst(rst),
			.m_req(c_req), .m_adr(c_adr), .m_we(c_we), .m_sel(c_sel),
			.m_wdat(c_wdat), .m_instr(c_instr),
			.m_rdy(c_rdy), .m_ack(c_ack), .m_rdat(c_rdat),
			.fencei(c_fencei),
			.mtime(mtime),
			.irq_msi(irq_msi), .irq_mti(irq_mti), .irq_mei(irq_mei), .irq_sei(irq_sei)
		);

	end endgenerate

	// ------------------------------------------------------------
	// the cache, with the CPU's addresses moved to its map
	// ------------------------------------------------------------

	wire [31:0] m_adr, m_dat_w;
	reg  [31:0] m_dat_r;
	wire        m_we, m_stb, m_cyc;
	wire  [3:0] m_sel;
	reg         m_ack;

	generate if (KCACHE) begin : kc

		// Kakao's own, with the CPU's addresses as they are
		wire [31:0] a;
		k_cache #(
			.I_KB(I_KB), .D_KB(D_KB),
			.FB(FB), .FB_AT(FB_AT)
		) cache_i (
			.clk(clk), .rst(rst),
			.c_req(c_req), .c_adr(c_adr), .c_we(c_we), .c_sel(c_sel),
			.c_wdat(c_wdat), .c_instr(c_instr),
			.c_rdy(c_rdy), .c_idle(c_idle), .c_ack(c_ack), .c_rdat(c_rdat),
			.c_fencei(c_fencei),
			.p_req(p_req), .p_adr(p_adr), .p_we(p_we), .p_sel(p_sel), .p_wdat(p_wdat),
			.p_ack(p_ack), .p_rdat(p_rdat),
			.m_adr_o(a), .m_dat_o(m_dat_w), .m_dat_i(m_dat_r),
			.m_we_o(m_we), .m_sel_o(m_sel), .m_stb_o(m_stb), .m_ack_i(m_ack),
			.m_hold_i(virt_hold)
		);
		assign m_cyc = m_stb;
		// the bus below has main memory where Zeitlos's cache puts it
		assign m_adr =
			(a[31:29] == 3'b100) ? { 3'b010, a[28:0] } :
			(a[31:29] == 3'b010) ? 32'h0000_0000 : a;

	end else begin : zc

		// (Zeitlos's cache does not say when it is idle apart from ready)
		assign c_idle = c_rdy;

		wire [31:0] k_adr =
			(c_adr[31:29] == 3'b100)      ? { 3'b010, c_adr[28:0] } :
			(c_adr[31:8] == 24'h030001)   ? { 24'h700001, c_adr[7:0] } :
			(c_adr[31:29] == 3'b010 ||
			 c_adr[31:28] == 4'h7)        ? 32'h0000_0000 :
			                                c_adr;

		wb_cache_one #(
			.MAIN_512(1),
			.KB(CACHE_KB),
			.LINE_WORDS(4),
			.WBUF_DEPTH(2),
			.BURST(0),
			.SNOOP(0),
			.STAT_BRAM(1)
		) cache_i (
			.wb_clk_i(clk), .wb_rst_i(rst),
			.c_req(c_req), .c_adr(k_adr), .c_we(c_we), .c_sel(c_sel),
			.c_wdat(c_wdat), .c_instr(c_instr),
			.c_rdy(c_rdy), .c_ack(c_ack), .c_rdat(c_rdat),
			.m_adr_o(m_adr), .m_dat_o(m_dat_w), .m_dat_i(m_dat_r),
			.m_we_o(m_we), .m_sel_o(m_sel), .m_stb_o(m_stb), .m_cyc_o(m_cyc),
			.m_cti_o(), .m_bte_o(), .m_ack_i(m_ack), .m_instr_o(),
			.snoop_stb_i(1'b0), .snoop_adr_i(32'h0),
			.c_cfg_hit(),
			.mpu_iveto(1'b0), .mpu_veto(1'b0), .mpu_reg(1'b0), .mpu_dat(32'h0)
		);
		// (no second port on this one: no virtio with it)
		assign p_ack = p_req;
		assign p_rdat = 32'd0;

	end endgenerate

	// ------------------------------------------------------------
	// the bus behind the cache
	// ------------------------------------------------------------

	wire s_mem   = (m_adr[31:29] == 3'b010);
	wire s_rom   = (m_adr[31:16] == 16'h0000) && (m_adr[15:12] != 4'h0);
	wire s_test  = (m_adr[31:12] == 20'h00100);
	wire s_clint = (m_adr[31:16] == 16'h0200);
	wire s_mreg  = (m_adr[31:8]  == 24'h030007);
	wire s_uart0 = (m_adr[31:8]  == 24'h100000);
	wire s_plic  = (m_adr[31:26] == 6'b000011);

	wire s_lxu   = LITEUART && (m_adr[31:8] == 24'hf00010);
	wire s_vcon  = (TERMINAL != 0) && (TERMS > 1) && (m_adr[31:12] == 20'h10000) && (m_adr[11:8] != 4'd0);
	wire s_virt  = (VIRTIO != 0) && (m_adr[31:16] == 16'h1000) && (m_adr[15:12] != 4'd0);
	wire s_fbr   = (FB != 0) && (m_adr[31:12] == 20'h03001);
	wire s_ext   = !(s_mem || s_rom || s_test || s_clint || s_mreg || s_uart0 || s_vcon || s_lxu || s_plic || s_virt || s_fbr);

	wire stb = m_stb && m_cyc;

	assign ext_adr_o = m_adr;
	assign ext_dat_o = m_dat_w;
	assign ext_we_o  = m_we;
	assign ext_sel_o = m_sel;
	assign ext_stb_o = stb && s_ext;

	assign mem_adr_o = m_adr[28:2];
	assign mem_dat_o = m_dat_w;
	assign mem_we_o  = m_we;
	assign mem_sel_o = m_sel;
	assign mem_stb_o = stb && s_mem;

	assign reg_adr_o = m_adr[3:2];
	assign reg_dat_o = m_dat_w;
	assign reg_we_o  = m_we;
	assign reg_stb_o = stb && s_mreg;

	// the devices here answer the cycle after a request; `first` is
	// that request's one cycle
	reg  io_ack;
	wire s_io  = !s_mem && !s_mreg && !s_ext && !s_virt;
	wire first = stb && s_io && !io_ack;

	wire [31:0] rom_a = m_adr - 32'h0000_1000;
	reg  [7:0] rom0 [0:ROM_WORDS-1];
	reg  [7:0] rom1 [0:ROM_WORDS-1];
	reg  [7:0] rom2 [0:ROM_WORDS-1];
	reg  [7:0] rom3 [0:ROM_WORDS-1];
	reg [31:0] rom_q;
	initial begin
		$readmemh({ROM_HEX, ".0.hex"}, rom0);
		$readmemh({ROM_HEX, ".1.hex"}, rom1);
		$readmemh({ROM_HEX, ".2.hex"}, rom2);
		$readmemh({ROM_HEX, ".3.hex"}, rom3);
	end
	wire [$clog2(ROM_WORDS)-1:0] rom_i = rom_a[2 +: $clog2(ROM_WORDS)];
	wire rom_we = first && s_rom && m_we;
	always @(posedge clk) begin
		if (rom_we && m_sel[0]) rom0[rom_i] <= m_dat_w[7:0];
		if (rom_we && m_sel[1]) rom1[rom_i] <= m_dat_w[15:8];
		if (rom_we && m_sel[2]) rom2[rom_i] <= m_dat_w[23:16];
		if (rom_we && m_sel[3]) rom3[rom_i] <= m_dat_w[31:24];
		rom_q <= { rom3[rom_i], rom2[rom_i], rom1[rom_i], rom0[rom_i] };
	end

	wire [31:0] clint_q, uart0_q;

	// the framebuffer's registers (FB). The count of late blocks comes
	// from the pixel clock as it is: it is read for curiosity, and a
	// value caught in the middle of changing is a wrong number once.
	reg         fb_deep8;
	wire [15:0] fb_under;
	wire [31:0] fbr_q = { fb_under, 15'd0, fb_deep8 };
	always @(posedge clk) begin
		if (rst) fb_deep8 <= 1'b0;
		else if (first && s_fbr && m_we && !m_adr[10] && m_adr[9:2] == 8'd0 && m_sel[0])
			fb_deep8 <= m_dat_w[0];
	end

	k_clint #(.TICK(CLINT_TICK), .HOLD_HI(CPU64)) clint_i (
		.clk(clk), .rst(rst),
		.req(first && s_clint), .we(m_we), .adr(m_adr[15:2]),
		.wdat(m_dat_w), .rdat(clint_q),
		.mtime(mtime), .irq_msi(irq_msi), .irq_mti(irq_mti)
	);

	// the interrupt controller: source 10 is UART 0, as on QEMU's virt
	wire [31:0] plic_q;
	k_plic plic_i (
		.clk(clk), .rst(rst),
		.req(first && s_plic), .we(m_we), .adr(m_adr[25:2]),
		.wdat(m_dat_w), .rdat(plic_q),
		.src({ virt_irq, 1'b0, uart0_irq, vcon_irq }),
		.irq_m(irq_mei), .irq_s(irq_sei)
	);

	// The LiteX UART's registers, a word each: 0 RXTX, 1 TXFULL,
	// 2 RXEMPTY, 4 EV_PENDING (a write with bit 1 takes the character).
	// They become requests to the 16550: a write of RXTX is a write of
	// THR, the taking is a read of RBR.
	wire        u_rxv, u_txbusy;
	wire  [7:0] u_rxd;
	wire lxu_tx  = first && s_lxu && m_we && (m_adr[7:2] == 6'd0);
	wire lxu_pop = first && s_lxu && m_we && (m_adr[7:2] == 6'd4) && m_dat_w[1];
	wire [31:0] lxu_q =
		(m_adr[7:2] == 6'd0) ? { 24'd0, u_rxd } :
		(m_adr[7:2] == 6'd1) ? { 31'd0, u_txbusy } :
		(m_adr[7:2] == 6'd2) ? { 31'd0, !u_rxv } : 32'd0;

	wire        uart0_irq;
	// (the terminal's taps, below)
	wire       con_stb, con_full, key_stb;
	wire [7:0] key_dat;
	wire [3:0] key_id;
	wire [8:0] vcon_irq;
	wire [31:0] vcon_q;
	wire [3:0] virt_irq;
	wire        iop_reset;
	wire        virt_ack;
	wire [31:0] virt_q;

	k_uart #(.DIV(UART_DIV), .PIPE(UART_PIPE)) uart0_i (
		.clk(clk), .rst(rst),
		.req((first && s_uart0) || lxu_tx || lxu_pop),
		.we(s_lxu ? lxu_tx : m_we),
		.adr2(s_lxu ? 1'b0 : m_adr[2]),
		.sel(s_lxu ? 4'b0001 : m_sel),
		.lx(s_lxu),
		.wdat(m_dat_w), .rdat(uart0_q),
		.st_rxv(u_rxv), .st_rxd(u_rxd), .st_txbusy(u_txbusy),
		.irq(uart0_irq),
		.tap(con_stb), .hold(con_full), .inj(key_stb && key_id == 4'd0), .inj_d(key_dat),
		.rx(uart0_rx), .tx(uart0_tx),
		.p_tx_valid(con_tx_valid), .p_tx_data(con_tx_data), .p_tx_ready(con_tx_ready),
		.p_rx_valid(con_rx_valid), .p_rx_data(con_rx_data), .p_rx_ready(con_rx_ready)
	);

	// ------------------------------------------------------------
	// the terminal: what goes out of UART 0 is also drawn on the
	// screen by the I/O processor, and what it has to say comes in
	// as if received
	// ------------------------------------------------------------

	// the virtio slots' side of the I/O processor
	wire        vi_req, vi_we;
	wire  [2:0] vi_adr;
	wire [31:0] vi_wdat, vi_rdat;

	generate if (TERMINAL) begin : term

		wire [17:0] t_adr;
		wire [31:0] t_dat_w, t_dat_r;
		wire        t_we, t_stb, t_ack;
		wire  [3:0] t_sel;

		wire [10:0] ub_adr;
		wire [31:0] ub_dat_w, ub_dat_r;
		wire        ub_we, ub_stb, ub_ack;
		wire  [3:0] ub_sel;

		// all the consoles' characters, with their numbers, and where
		// the keys go
		wire       q_stb;
		wire [3:0] q_id;
		wire [7:0] q_dat;
		wire [8:0] vkey_busy;

		if (TERMS > 1) begin : vcon
			k_vcon #(.N(TERMS - 1)) vcon_i (
				.clk(clk), .rst(rst),
				.req(first && s_vcon), .we(m_we), .port(m_adr[11:8]), .adr2(m_adr[2]),
				.sel(m_sel), .wdat(m_dat_w), .rdat(vcon_q), .irq(vcon_irq),
				.tap0(con_stb), .tap0_d(m_dat_w[7:0]),
				.out_stb(q_stb), .out_id(q_id), .out_d(q_dat), .full(con_full),
				.key_stb(key_stb), .key_id(key_id), .key_d(key_dat), .key_busy(vkey_busy)
			);
		end else begin : novcon
			assign q_stb = con_stb;
			assign q_id = 4'd0;
			assign q_dat = m_dat_w[7:0];
			assign vkey_busy = 9'd0;
			assign vcon_irq = 9'd0;
			assign vcon_q = 32'd0;
		end

		k_iop #(.FW_HEX(IOP_HEX), .RAM_WORDS(IOP_WORDS), .USB(USB), .TERMS(TERMS), .HIST(HIST)) iop_i (
			.clk(clk), .rst(rst),
			.con_stb(q_stb), .con_dat(q_dat), .con_id(q_id), .con_full(con_full),
			.key_stb(key_stb), .key_dat(key_dat), .key_id(key_id), .key_busy({ vkey_busy, u_rxv }),
			.t_adr_o(t_adr), .t_dat_o(t_dat_w), .t_dat_i(t_dat_r),
			.t_we_o(t_we), .t_sel_o(t_sel), .t_stb_o(t_stb), .t_ack_i(t_ack),
			.u_adr_o(ub_adr), .u_dat_o(ub_dat_w), .u_dat_i(ub_dat_r),
			.u_we_o(ub_we), .u_sel_o(ub_sel), .u_stb_o(ub_stb), .u_ack_i(ub_ack),
			.v_req(vi_req), .v_we(vi_we), .v_adr(vi_adr), .v_wdat(vi_wdat), .v_rdat(vi_rdat),
			.p_req(p_req), .p_adr(p_adr), .p_we(p_we), .p_sel(p_sel), .p_wdat(p_wdat),
			.p_ack(p_ack), .p_rdat(p_rdat),
			.x_adr_o(iox_adr_o), .x_dat_o(iox_dat_o), .x_dat_i(iox_dat_i),
			.x_we_o(iox_we_o), .x_sel_o(iox_sel_o), .x_stb_o(iox_stb_o), .x_ack_i(iox_ack_i),
			.reset_o(iop_reset),
			.trap(iop_trap)
		);

		// Zeitlos's USB host controller, as Zeitlos has it: two ports,
		// hubs and all in its driver, which the I/O processor runs
		// (fw/iop). Its pointer and its interrupts are not used here.
		// (K_USB: built with Zeitlos's rtl/usb files; builds without
		// them have USB 0)
`ifdef K_USB
		if (USB) begin : usb
			usb_host #(
				.PORTS(2), .T_MS(USB_T_MS), .T_FRAME(48000)
			) host_i (
				.wb_clk_i(clk), .wb_rst_i(rst),
				.wb_adr_i(ub_adr), .wb_dat_i(ub_dat_w), .wb_dat_o(ub_dat_r),
				.wb_we_i(ub_we), .wb_sel_i(ub_sel), .wb_stb_i(ub_stb),
				.wb_ack_o(ub_ack), .wb_cyc_i(ub_stb),
				.usb_dp(usb_dp), .usb_dm(usb_dm),
				.curs_max_x(11'd639), .curs_max_y(10'd479),
				.curs_x0(), .curs_y0(), .curs_x1(), .curs_y1(),
				.typ0(), .typ1(),
				.tx_active_o(), .tx_port_o(), .line0_o(),
				.hid0_int_o(), .hid1_int_o(), .int_o()
			);
		end else
`endif
		begin : nousb
			assign ub_dat_r = 32'd0;
			assign ub_ack = ub_stb;
		end

		wire [10:0] t_hc, t_vc;
		wire        t_show;
		wire [23:0] t_fbrgb;

		k_text #(.TERMS(TERMS + HIST), .FONT_HEX(FONT_HEX), .FB(FB), .FB_SHOW(FB_SHOW)) text_i (
			.clk(clk), .rst(rst),
			.adr_i(t_adr), .dat_i(t_dat_w), .dat_o(t_dat_r), .we_i(t_we), .sel_i(t_sel),
			.stb_i(t_stb), .ack_o(t_ack),
			.pclk(pclk), .red(vid_r), .green(vid_g), .blue(vid_b),
			.hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank), .hc(t_hc), .vc(t_vc),
			.fb_show(t_show), .fb_rgb(t_fbrgb)
		);

		if (FB != 0) begin : fb
			wire [15:0] under;
			k_fb #(.BASE({ FB_AT, 18'd0 })) fb_i (
				.clk(clk), .rst(rst),
				.show(t_show), .deep8(fb_deep8),
				.m_stb(fb_stb_o), .m_adr(fb_adr_o), .m_ack(fb_ack_i), .m_dat(fb_dat_i),
				.pal_we(first && s_fbr && m_we && m_adr[10]), .pal_a(m_adr[9:2]), .pal_d(m_dat_w[23:0]),
				.pclk(pclk), .hc(t_hc), .vc(t_vc), .rgb(t_fbrgb),
				.underruns(under)
			);
			assign fb_under = under;
		end else begin : nofb
			assign t_fbrgb = 24'd0;
			assign fb_stb_o = 1'b0;
			assign fb_adr_o = 25'd0;
			assign fb_under = 16'd0;
		end

	end else begin : noterm

		assign con_full = 1'b0;
		assign key_stb = 1'b0;
		assign key_dat = 8'd0;
		assign key_id = 4'd0;
		assign vcon_irq = 9'd0;
		assign vcon_q = 32'd0;
		assign { vid_r, vid_g, vid_b } = 24'd0;
		assign fb_stb_o = 1'b0;
		assign fb_adr_o = 25'd0;
		assign fb_under = 16'd0;
		assign vid_hsync = 1'b1;
		assign vid_vsync = 1'b1;
		assign vid_blank = 1'b1;

		// without a terminal the I/O processor is there for the virtio
		// devices alone (fw/iop/headless.c): no text mode, no USB, no
		// consoles
		if (VIRTIO != 0) begin : head
			wire t_stb, u_stb;
			k_iop #(.FW_HEX(IOP_HEX), .RAM_WORDS(IOP_WORDS), .USB(0), .TERMS(1)) iop_i (
				.clk(clk), .rst(rst),
				.con_stb(1'b0), .con_dat(8'd0), .con_id(4'd0), .con_full(),
				.key_stb(), .key_dat(), .key_id(), .key_busy(10'd0),
				.t_adr_o(), .t_dat_o(), .t_dat_i(32'd0),
				.t_we_o(), .t_sel_o(), .t_stb_o(t_stb), .t_ack_i(t_stb),
				.u_adr_o(), .u_dat_o(), .u_dat_i(32'd0),
				.u_we_o(), .u_sel_o(), .u_stb_o(u_stb), .u_ack_i(u_stb),
				.v_req(vi_req), .v_we(vi_we), .v_adr(vi_adr), .v_wdat(vi_wdat), .v_rdat(vi_rdat),
				.p_req(p_req), .p_adr(p_adr), .p_we(p_we), .p_sel(p_sel), .p_wdat(p_wdat),
				.p_ack(p_ack), .p_rdat(p_rdat),
				.x_adr_o(iox_adr_o), .x_dat_o(iox_dat_o), .x_dat_i(iox_dat_i),
				.x_we_o(iox_we_o), .x_sel_o(iox_sel_o), .x_stb_o(iox_stb_o), .x_ack_i(iox_ack_i),
				.reset_o(iop_reset),
				.trap(iop_trap)
			);
		end else begin : nohead
			assign iop_trap = 1'b0;
			assign iop_reset = 1'b0;
			assign vi_req = 1'b0;
			assign vi_we = 1'b0;
			assign vi_adr = 3'd0;
			assign vi_wdat = 32'd0;
			assign p_req = 1'b0;
			assign p_adr = 29'd0;
			assign p_we = 1'b0;
			assign p_sel = 4'd0;
			assign p_wdat = 32'd0;
			assign iox_adr_o = 16'd0;
			assign iox_dat_o = 32'd0;
			assign iox_we_o = 1'b0;
			assign iox_sel_o = 4'd0;
			assign iox_stb_o = 1'b0;
		end

	end endgenerate

	// the virtio slots: the host's registers of the devices the I/O
	// processor is

	generate if (VIRTIO != 0) begin : virt
		wire [VIRTIO-1:0] irq;
		wire vhold;
		assign virt_hold = vhold && s_virt;
		wire [3:0] slot = m_adr[15:12] - 4'd1;
		k_virtio #(.N(VIRTIO)) virtio_i (
			.clk(clk), .rst(rst),
			.h_stb(stb && s_virt), .h_we(m_we), .h_slot(slot[3] ? 3'd7 : slot[2:0]),
			.h_adr(m_adr[11:2]), .h_sel(m_sel), .h_wdat(m_dat_w),
			.h_ack(virt_ack), .h_rdat(virt_q), .h_hold(vhold), .irq(irq),
			.i_req(vi_req), .i_we(vi_we), .i_adr(vi_adr), .i_wdat(vi_wdat), .i_rdat(vi_rdat)
		);
		assign virt_irq = irq;
	end else begin : novirt
		assign virt_irq = 4'd0;
		assign virt_ack = 1'b0;
		assign virt_q = 32'd0;
		assign vi_rdat = 32'd0;
		assign virt_hold = 1'b0;
	end endgenerate


	reg [31:0] io_q;
	reg        io_rom;
	always @(posedge clk) begin
		io_rom <= s_rom;
		io_q   <= s_clint ? clint_q : s_uart0 ? uart0_q : s_vcon ? vcon_q : s_lxu ? lxu_q : s_plic ? plic_q :
		          s_fbr ? fbr_q : 32'd0;
		if (rst) begin
			io_ack <= 1'b0;
			poweroff_o <= 1'b0;
			reset_o <= 1'b0;
		end else begin
			io_ack <= first;
			reset_o <= iop_reset || (first && s_test && m_we && m_dat_w[15:0] == 16'h7777);
			if (first && s_test && m_we && m_dat_w[15:0] == 16'h5555) poweroff_o <= 1'b1;
		end
	end

	always @(*) begin
		m_ack   = s_mem ? mem_ack_i : s_mreg ? reg_ack_i : s_ext ? ext_ack_i : s_virt ? virt_ack : io_ack;
		m_dat_r = s_mem ? mem_dat_i : s_mreg ? reg_dat_i : s_ext ? ext_dat_i : s_virt ? virt_q :
		          io_rom ? rom_q : io_q;
	end

endmodule
