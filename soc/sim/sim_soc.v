/*
 * sim_soc -- kakao_soc (the CPU, the cache, the bus and its devices)
 * with a model of main memory and of the board, for booting Linux in
 * simulation with the cache in the way. The same shell as sim_top.v,
 * so sim_main.cpp drives either.
 *
 * Main memory answers as Zeitlos's DDR3 controller does, by the
 * numbers in its docs/ddr3.md: a read of a new 16-byte block after
 * RD_NEW cycles, further words of the block it holds after one; a
 * store is read-modify-write, WR cycles into the block it holds and
 * RD_NEW + WR into another; with WC, as it does with write combining
 * (below). It counts what it did (n_*, c_*), which sim_main.cpp prints.
 *
 * The board's own device is a LiteX UART at 0xf000_1000, the prebuilt
 * Kakao kernel's console; or with LXFRONT, as on the boards, the SOC's
 * own LiteX front on UART 0, and then Linux's console goes through
 * UART 0 and so to the terminal. UART 0's characters are taken where
 * they are written, not from its pin; what is typed goes in at its pin.
 */

`timescale 1ns / 1ps

module sim_soc #(
	parameter MEM_MB = 64,
	parameter CACHE_KB = 8,
	parameter RD_NEW = 10,
	parameter WR = 10,
	parameter WC = 0,
	parameter CPU64 = 0,			// kakao64
	parameter BOOT_HEX = "obj/boot",	// the boot memory (obj/boot64: where a 64 bit machine has things)
	parameter KCACHE = 0,
	parameter I_KB = 16,
	parameter D_KB = 16,
	parameter TERMINAL = 0,
	parameter TERMS = 1,			// consoles, each with a terminal
	parameter HIST = 0,
	parameter BTFN = 0,
	parameter FAST_MUL = 0,
	parameter BTB_BITS = 6,
	parameter TLB_BITS = 5,
	parameter LXFRONT = 0,			// the LiteX UART is the SOC's own front on UART 0
	parameter UART_PIPE = 0,		// UART 0 as a pipe of bytes, as with the USB console: what is
								// typed goes in there, and what is sent is taken one cycle in 16
	parameter RXPIN = 0,			// what is typed goes in at UART 0's pin (a kernel with the 8250 driver)
	parameter VIRTIO = 0,			// virtio slots: the first is the SD card (sd_card.v), SD_MB of it
`ifndef SIM_SD_MB
`define SIM_SD_MB 16
`endif
	parameter SD_MB = `SIM_SD_MB,		// (make ... SOCD=-DSIM_SD_MB=96)
	parameter FB = 0,				// a framebuffer in the top 4 MB of main memory (with TERMINAL
								// and KCACHE), shown from reset: +frame= writes the picture out
	parameter IOP_WORDS = 11264,
	parameter IOP_HEX = "../fw/iop/iop.hex"	// (without TERMINAL: iop-headless.hex, 2048 words)
) (
	input        clk,
	input        rst,
	input        rx_put,
	input  [7:0] rx_char,
	output       rx_busy,
	output reg       tx_put,
	output reg [7:0] tx_char,
	output       poweroff,
	// the network cable's other end (VIRTIO > 1: rmii_peer.v)
	output       eth_tx_stb,
	output [7:0] eth_tx_byte,
	output       eth_tx_end,
	input        eth_rx_go,
	input [11:0] eth_rx_len,
	output       eth_rx_busy,
	// the picture, a pixel every second cycle of clk (the simulation's
	// pixel clock is half of clk, 24 MHz for the boards' 25)
	output        vid_pclk,
	output  [7:0] vid_r,
	output  [7:0] vid_g,
	output  [7:0] vid_b,
	output        vid_hsync,
	output        vid_vsync,
	output        vid_blank
);

	reg pclk = 1'b0;
	always @(posedge clk) pclk <= !pclk;
	assign vid_pclk = pclk;

	// main memory's second port, the framebuffer's (below)
	wire         fb_stb;
	wire  [24:0] fb_adr;
	reg          fb_ack;
	reg  [127:0] fb_dat;

	localparam MEM_WORDS = MEM_MB * 262144;

	wire [26:0] mem_adr;
	wire [31:0] mem_dat_w;
	reg  [31:0] mem_dat_r;
	wire        mem_we, mem_stb;
	wire  [3:0] mem_sel;
	reg         mem_ack;

	wire [31:0] ext_adr, ext_dat_w;
	reg  [31:0] ext_dat_r;
	wire        ext_we, ext_stb;
	wire  [3:0] ext_sel;
	reg         ext_ack;

	wire        u_tx;

	kakao_soc #(
		.KCACHE(KCACHE), .I_KB(I_KB), .D_KB(D_KB), .BTFN(BTFN), .FAST_MUL(FAST_MUL), .BTB_BITS(BTB_BITS), .TLB_BITS(TLB_BITS),
		.CPU64(CPU64), .UART_PIPE(UART_PIPE), .TERMINAL(TERMINAL), .TERMS(TERMS), .HIST(HIST), .IOP_HEX(IOP_HEX), .FONT_HEX("obj/k_font.hex"),
		.VIRTIO(VIRTIO), .IOP_WORDS(IOP_WORDS),
		.FB(FB), .FB_AT(MEM_MB / 4 - 1), .FB_SHOW(FB),
		.CACHE_KB(CACHE_KB),
		.ROM_HEX(BOOT_HEX),
		.UART_DIV(2),
		.LITEUART(LXFRONT)
	) soc (
		.clk(clk), .rst(rst),
		.mem_adr_o(mem_adr), .mem_dat_o(mem_dat_w), .mem_dat_i(mem_dat_r),
		.mem_we_o(mem_we), .mem_sel_o(mem_sel), .mem_stb_o(mem_stb), .mem_ack_i(mem_ack),
		.reg_adr_o(), .reg_dat_o(), .reg_dat_i(32'hdd30_0083), .reg_we_o(),
		.reg_stb_o(), .reg_ack_i(1'b1),
		.ext_adr_o(ext_adr), .ext_dat_o(ext_dat_w), .ext_dat_i(ext_dat_r),
		.ext_we_o(ext_we), .ext_sel_o(ext_sel), .ext_stb_o(ext_stb), .ext_ack_i(ext_ack),
		.uart0_rx(u_rx), .uart0_tx(u_tx),
		.con_tx_valid(pp_tx_v), .con_tx_data(), .con_tx_ready(pp_tx_rdy),
		.con_rx_valid(pp_v), .con_rx_data(pp_d), .con_rx_ready(pp_rdy),
		.fb_stb_o(fb_stb), .fb_adr_o(fb_adr), .fb_ack_i(fb_ack), .fb_dat_i(fb_dat),
		.pclk(pclk), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
		.vid_hsync(vid_hsync), .vid_vsync(vid_vsync), .vid_blank(vid_blank),
		.iop_trap(iop_trap),
		.iox_adr_o(iox_adr), .iox_dat_o(iox_dat_w), .iox_dat_i(iox_dat_r),
		.iox_we_o(iox_we), .iox_sel_o(iox_sel), .iox_stb_o(iox_stb), .iox_ack_i(iox_ack),
		.mtime_o(), .poweroff_o(soc_off), .reset_o(soc_reset)
	);
	// a reset ends the simulation as a power-off does
	wire soc_off, soc_reset;
	reg  was_reset = 0;
	always @(posedge clk) if (soc_reset && !was_reset) begin
		was_reset <= 1'b1;
		$display("\nsim: the machine was RESET");
	end
	assign poweroff = soc_off || was_reset;

	// the I/O processor's board devices: the SD card on Zeitlos's SPI
	// master, as on the boards (anything else reads zero)
	wire [15:0] iox_adr;
	wire [31:0] iox_dat_w, iox_dat_r, sd_dat_r;
	wire        iox_we, iox_stb, iox_ack, sd_ack;
	wire  [3:0] iox_sel;
	wire        iox_sd = (iox_adr[15:12] == 4'd0) && (VIRTIO != 0);
	wire        iox_eth = (iox_adr[15:13] == 3'd1) && (VIRTIO > 1);
	wire [31:0] eth_dat_r;
	wire        eth_ack;
	reg         iox_nul;
	always @(posedge clk) iox_nul <= iox_stb && !iox_sd && !iox_eth && !iox_nul;
	assign iox_ack   = iox_sd ? sd_ack : iox_eth ? eth_ack : iox_nul;
	assign iox_dat_r = iox_sd ? sd_dat_r : iox_eth ? eth_dat_r : 32'd0;

	// the network: Zeitlos's RMII MAC at 0x2000, as on the boards, on
	// this clock as its reference clock
	generate if (VIRTIO > 1) begin : eth
		wire [1:0] txd, rxd;
		wire       tx_en, crs_dv;
		ethmac_rmii_wb mac_i (
			.wb_clk_i(clk), .wb_rst_i(rst),
			.wb_adr_i({ 21'd0, iox_adr[12:2] }), .wb_dat_i(iox_dat_w), .wb_dat_o(eth_dat_r),
			.wb_we_i(iox_we), .wb_sel_i(iox_sel), .wb_stb_i(iox_stb && iox_eth), .wb_ack_o(eth_ack),
			.wb_cyc_i(iox_stb && iox_eth),
			.eth_refclk(clk), .eth_rxd(rxd), .eth_txd(txd), .eth_tx_en(tx_en),
			.eth_crs_dv(crs_dv), .eth_rst_n(), .eth_int_o()
		);
		rmii_peer peer (
			.clk(clk), .rst(rst), .txd(txd), .tx_en(tx_en), .rxd(rxd), .crs_dv(crs_dv),
			.tx_stb(eth_tx_stb), .tx_byte(eth_tx_byte), .tx_end(eth_tx_end),
			.rx_go(eth_rx_go), .rx_len(eth_rx_len), .rx_busy(eth_rx_busy)
		);
	end else begin : noeth
		assign eth_dat_r = 32'd0;
		assign eth_ack = 1'b0;
		assign eth_tx_stb = 1'b0;
		assign eth_tx_byte = 8'd0;
		assign eth_tx_end = 1'b0;
		assign eth_rx_busy = 1'b0;
	end endgenerate

	generate if (VIRTIO != 0) begin : sd
		wire cs_n, sck, mosi, miso;
		spim_wb spi_i (
			.wb_clk_i(clk), .wb_rst_i(rst),
			.wb_adr_i({ 30'd0, iox_adr[3:2] }), .wb_dat_i(iox_dat_w), .wb_dat_o(sd_dat_r),
			.wb_we_i(iox_we), .wb_sel_i(iox_sel), .wb_stb_i(iox_stb && iox_sd), .wb_ack_o(sd_ack),
			.wb_cyc_i(iox_stb && iox_sd),
			.spi_cs_n(cs_n), .spi_sck(sck), .spi_mosi(mosi), .spi_miso(miso),
			.spi_int(1'b1), .dma_start_i(1'b0), .dma_busy_o()
		);
		sd_card card (
			.clk(clk), .rst(rst), .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso)
		);
	end else begin : nosd
		assign sd_ack = 1'b0;
		assign sd_dat_r = 32'd0;
	end endgenerate

	reg [31:0] ram [0:MEM_WORDS-1] /*verilator public*/;
	wire iop_trap /*verilator public*/;

	// -- main memory --
	reg  [7:0] m_wait;
	reg        m_busy;
	reg [24:0] m_blk;
	reg        m_blk_v;
	wire       m_same = m_blk_v && (m_blk == mem_adr[26:2]);

	// The framebuffer's port: a block read whole, 13 cycles as the DDR3
	// controller's (rtl/mem/k_ddr3_ctrl.v) takes with the row's closing, taken
	// before the CPU's request when both wait, and never in the middle
	// of an access or of a block's writing. It leaves the block register
	// alone, so what it reads is memory as it was written: a store
	// still in the block register reaches the screen a frame later.
	reg        f_busy;
	reg  [7:0] f_wait;
	wire       f_start = fb_stb && !fb_ack && !f_busy && !m_busy && (m_fl == 0);
	wire [25:0] f_w = { fb_adr[23:0], 2'b00 };
	reg [63:0] n_fb /*verilator public*/;

	// what main memory was asked, and the cycles it took
	reg [63:0] n_rd_new /*verilator public*/, n_rd_same /*verilator public*/;
	reg [63:0] n_wr_new /*verilator public*/, n_wr_same /*verilator public*/;
	reg [63:0] c_rd /*verilator public*/, c_wr /*verilator public*/;
	reg [63:0] n_flush /*verilator public*/;

	// with WC, the controller's write combining: the block register
	// takes stores (m_dirty: it holds a block not yet written, m_mask:
	// the words of it that were stored whole) and the block is written
	// when something else needs the controller or after 8 idle cycles,
	// with a read first unless all four words were stored
	reg        m_dirty, m_ndirty;
	reg  [3:0] m_mask, m_nmask, m_idle;
	reg  [7:0] m_fl;
	wire [3:0] m_wbit = (mem_sel == 4'b1111) ? (4'b0001 << mem_adr[1:0]) : 4'b0000;
	wire [7:0] m_flc  = (&m_mask) ? WR : RD_NEW + WR;

	// -- the LiteX UART --
	reg        rx_v;
	reg  [7:0] rx_c;
	// with LXFRONT what is typed goes in at UART 0's pin, two cycles
	// a bit, whether the host has taken the last one or not (as a
	// terminal at the other end would send it)
	reg  [9:0] p_sh;
	reg  [4:0] p_n;
	wire       pin = ((LXFRONT != 0) || (RXPIN != 0)) && (UART_PIPE == 0);
	wire       u_rx = (pin && p_n != 0) ? p_sh[0] : 1'b1;
	reg  [7:0] p_wait;
	assign rx_busy = (UART_PIPE != 0) ? pp_v : pin ? (p_n != 0 || p_wait != 0) : rx_v;
	// the pipe's other side
	wire       pp_tx_v, pp_rdy;
	reg        pp_v;
	reg  [7:0] pp_d;
	reg  [3:0] pp_c;
	wire       pp_tx_rdy = (pp_c == 4'd0);
	always @(posedge clk) begin
		pp_c <= pp_c + 4'd1;
		if (rst) pp_v <= 1'b0;
		else if (UART_PIPE != 0 && rx_put) begin pp_v <= 1'b1; pp_d <= rx_char; end
		else if (pp_v && pp_rdy) pp_v <= 1'b0;
	end
	always @(posedge clk) begin
		if (rst) begin p_n <= 0; p_wait <= 0; end
		else if (pin && rx_put) begin
			p_sh <= { 1'b1, rx_char, 1'b0 }; p_n <= 5'd20; p_wait <= 8'd40;
		end else if (p_n != 0) begin
			p_n <= p_n - 5'd1;
			if (p_n[0]) p_sh <= { 1'b1, p_sh[9:1] };
		end else if (p_wait != 0) p_wait <= p_wait - 8'd1;
	end
	wire is_lxu = (ext_adr[31:8] == 24'hf00010);

	always @(posedge clk) begin
		tx_put  <= 1'b0;
		mem_ack <= 1'b0;
		ext_ack <= 1'b0;
		if (rst) begin
			m_busy <= 1'b0;
			f_busy <= 1'b0; fb_ack <= 1'b0; n_fb <= 0;
			m_blk_v <= 1'b0;
			m_dirty <= 1'b0; m_mask <= 0; m_idle <= 0; m_fl <= 0; n_flush <= 0;
			n_rd_new <= 0; n_rd_same <= 0; n_wr_new <= 0; n_wr_same <= 0; c_rd <= 0; c_wr <= 0;
			rx_v <= 1'b0;
		end else begin
			if (rx_put) begin
				rx_v <= 1'b1;
				rx_c <= rx_char;
			end

			// (WC) the block register written after eight idle cycles
			if (m_fl != 0) m_fl <= m_fl - 8'd1;
			if (mem_stb || !m_dirty) m_idle <= 0;
			else if (m_idle == 4'd8) begin
				m_fl <= m_flc; m_dirty <= 1'b0; m_idle <= 0; n_flush <= n_flush + 1;
			end else m_idle <= m_idle + 4'd1;

			fb_ack <= 1'b0;
			if (f_start) begin
				f_busy <= 1'b1; f_wait <= RD_NEW + 2;	// (10 cycles to the data, 3 for the row to close)
				n_fb <= n_fb + 1;
			end else if (f_busy) begin
				if (f_wait != 0) f_wait <= f_wait - 8'd1;
				else begin
					f_busy <= 1'b0;
					fb_ack <= 1'b1;
					fb_dat <= { ram[f_w + 26'd3], ram[f_w + 26'd2], ram[f_w + 26'd1], ram[f_w] };
				end
			end

			if (mem_stb && !mem_ack) begin
				if (mem_we) c_wr <= c_wr + 1; else c_rd <= c_rd + 1;
				if (m_fl != 0 || f_busy || (f_start && !m_busy)) begin
					// still writing, or the framebuffer's block is being read
				end else if (!m_busy) begin
					m_busy <= 1'b1;
					if (mem_we) begin if (m_same) n_wr_same <= n_wr_same + 1; else n_wr_new <= n_wr_new + 1; end
					else begin if (m_same) n_rd_same <= n_rd_same + 1; else n_rd_new <= n_rd_new + 1; end
					if (!WC) begin
						m_wait <= mem_we ? (m_same ? WR - 1 : RD_NEW + WR - 1) : m_same ? 0 : RD_NEW - 1;
					end else if (mem_we) begin
						// a store is merged, after the block in the way is written
						if (m_dirty && !m_same) begin
							m_wait <= m_flc; n_flush <= n_flush + 1;
							m_nmask <= m_wbit;
						end else begin
							m_wait <= 0;
							m_nmask <= (m_dirty ? m_mask : 4'b0000) | m_wbit;
						end
						m_ndirty <= 1'b1;
					end else begin
						if (m_dirty && m_same && m_mask[mem_adr[1:0]]) begin
							m_wait <= 0; m_ndirty <= 1'b1; m_nmask <= m_mask;
						end else begin
							m_wait <= (m_dirty ? m_flc : 0) + (m_same ? 0 : RD_NEW - 1);
							if (m_dirty) n_flush <= n_flush + 1;
							m_ndirty <= 1'b0; m_nmask <= 4'b0000;
						end
					end
				end else if (m_wait != 0) begin
					m_wait <= m_wait - 8'd1;
				end else begin
					m_busy  <= 1'b0;
					mem_ack <= 1'b1;
					mem_dat_r <= (mem_adr < MEM_WORDS) ? ram[mem_adr[25:0]] : 32'd0;
					m_blk   <= mem_adr[26:2];
					m_blk_v <= 1'b1;
					if (WC) begin m_dirty <= m_ndirty; m_mask <= m_nmask; end
					if (mem_we && mem_adr < MEM_WORDS) begin
						if (mem_sel[0]) ram[mem_adr[25:0]][7:0]   <= mem_dat_w[7:0];
						if (mem_sel[1]) ram[mem_adr[25:0]][15:8]  <= mem_dat_w[15:8];
						if (mem_sel[2]) ram[mem_adr[25:0]][23:16] <= mem_dat_w[23:16];
						if (mem_sel[3]) ram[mem_adr[25:0]][31:24] <= mem_dat_w[31:24];
					end
				end
			end

			if (ext_stb && !ext_ack) begin
				ext_ack <= 1'b1;
				ext_dat_r <= !is_lxu ? 32'd0 :
					(ext_adr[7:2] == 6'd0) ? { 24'd0, rx_c } :
					(ext_adr[7:2] == 6'd2) ? { 31'd0, !rx_v } : 32'd0;
				if (is_lxu && ext_we) begin
					if (ext_adr[7:2] == 6'd0) begin
						tx_put  <= 1'b1;
						tx_char <= ext_dat_w[7:0];
					end
					if (ext_adr[7:2] == 6'd4 && ext_dat_w[1]) rx_v <= 1'b0;
				end
			end

			// UART 0, taken at its register
			if (soc.uart0_i.tap) begin
				tx_put  <= 1'b1;
				tx_char <= soc.uart0_i.wdat[7:0];
			end
		end
	end

`ifdef K_IRQ_DEBUG
	// what the interrupts do, from the first character typed
	integer dbg_n = 0;
	reg dbg_on = 0, d_u = 0, d_s = 0;
	always @(posedge clk) begin
		if (rx_put) dbg_on <= 1;
		d_u <= soc.uart0_irq; d_s <= soc.irq_sei;
		if (dbg_on && dbg_n < 400) begin
			if (rx_put) begin $display("[irq] typed %02x", rx_char); dbg_n <= dbg_n + 1; end
			if (d_u != soc.uart0_irq) begin $display("[irq] uart0 irq %b (ier %b rv %b thre_p %b)", soc.uart0_irq, soc.uart0_i.ier, soc.uart0_i.r_v, soc.uart0_i.thre_p); dbg_n <= dbg_n + 1; end
			if (d_s != soc.irq_sei) begin $display("[irq] S external %b (pend %b en1 %b serv %b thr1 %0d prio10 %0d)", soc.irq_sei, soc.plic_i.pend, soc.plic_i.en1, soc.plic_i.serv, soc.plic_i.thr1, soc.plic_i.prio[10]); dbg_n <= dbg_n + 1; end
			if (soc.plic_i.req) begin $display("[irq] plic %s %06x %08x", soc.plic_i.we ? "write" : "read ", { soc.plic_i.adr, 2'b00 }, soc.plic_i.we ? soc.plic_i.wdat : soc.plic_i.rdat); dbg_n <= dbg_n + 1; end
			if (soc.uart0_i.req) begin $display("[irq] uart %s adr2 %b sel %b %08x", soc.uart0_i.we ? "write" : "read ", soc.uart0_i.adr2, soc.uart0_i.sel, soc.uart0_i.we ? soc.uart0_i.wdat : soc.uart0_i.rdat); dbg_n <= dbg_n + 1; end
		end
	end
`endif

	// the terminal's screen at the end, as text: on the log and in
	// screen.txt
	generate if (TERMINAL) begin : scr
		integer f, x, y, t, at, tb, te;
		reg [7:0] c;
		reg [8*80-1:0] line;
		final begin
			f = $fopen("screen.txt", "w");
			if (iop_trap) $display("sim: the I/O processor has STOPPED");
`ifdef K_VIRTIO_LOG
			$display("sim: at the end: CPU %08x req %b; cache st %0d p_turn %b r_p %b; I/O processor %08x valid %b; PLIC pend %04x serv %04x",
				soc.c_adr, soc.c_req, soc.kc.cache_i.st, soc.kc.cache_i.p_turn, soc.kc.cache_i.r_p,
				soc.term.iop_i.mem_addr, soc.term.iop_i.mem_valid, soc.plic_i.pend, soc.plic_i.serv);
`endif
			// the terminal shown, as the text mode draws it; the others
			// from their first cell (right while they have not scrolled)
			for (t = 0; t < TERMS; t = t + 1) begin
				// (the first terminal's cells are HIST screens longer: its scroll buffer)
				tb = (t == 0) ? 0 : (t + HIST) * 2400;
				te = (t == 0) ? (1 + HIST) * 2400 : tb + 2400;
				if (tb == soc.term.text_i.base) begin
					$display("sim: the screen (terminal %0d):", t + 1);
					at = soc.term.text_i.start;
				end else begin
					$display("sim: terminal %0d, not shown:", t + 1);
					at = tb;
				end
				for (y = 0; y < 30; y = y + 1) begin
					for (x = 0; x < 80; x = x + 1) begin
						c = soc.term.text_i.cells[at + x][7:0];
						line[(79 - x) * 8 +: 8] = (c >= 8'h20 && c < 8'h7f) ? c : "#";
					end
					if (tb == soc.term.text_i.base || line != {80{8'h20}}) $display("  |%s|", line);
					if (tb == soc.term.text_i.base) $fwrite(f, "%s\n", line);
					at = at + 80;
					if (at == te) at = tb;
				end
			end
			$fclose(f);
		end
	end endgenerate

`ifdef K_TRAPS
	// (make ... SOCD=-DK_TRAPS: every trap kakao64 takes, and with
	// +kw every register write)
	reg kw;
	initial kw = $test$plusargs("kw");
	always @(posedge clk) if (!rst) begin
		if (soc.c64.cpu.trap_take)
			$display("T %016x cause %0d%s tval %016x instr %08x -> %s", soc.c64.cpu.x_pc, soc.c64.cpu.trap_code,
				soc.c64.cpu.irq_take ? " (irq)" : "", soc.c64.cpu.exc_tval, soc.c64.cpu.x_instr, soc.c64.cpu.trap_s ? "S" : "M");
		if (kw && soc.c64.cpu.w_wr)
			$display("W %016x x%0d %016x", soc.c64.cpu.w_pc, soc.c64.cpu.w_rd, soc.c64.cpu.w_val);
	end
`endif

endmodule
