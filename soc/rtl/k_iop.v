/*
 * k_iop -- the I/O processor: a small RISC-V (picorv32, RV32I) with
 * its own memory and program, beside the CPU that runs Linux. It is
 * the terminal: what Linux writes to its console comes here a
 * character at a time and is drawn into the text mode (k_text.v),
 * and what is typed goes back the same way. Later it also runs the
 * USB host stack and stands behind the virtio devices; for now it has
 * the console and the screen.
 *
 * Its program is fw/iop, loaded into its memory from FW_HEX (a word a
 * line). What it sees:
 *
 *   0x0000_0000   its memory, RAM_WORDS words
 *   0x1000_0000   the text mode: cells from 0x0000, registers from
 *                 0x4000, the overlay's cells from 0x8000 (k_text.v)
 *   0x2000_0000   CON   read: [8] a character from the host waits,
 *                       [7:0] the character, [15:12] the console it
 *                       was sent on; reading takes it
 *   0x2000_0004   KEY   write: [7:0] a character for the host, typed
 *                       at console [11:8]
 *                       read: [9:0] the consoles that have not taken
 *                       their last one
 *   0x2000_0008   TICKS read: clock cycles since reset
 *   0x2000_000c   OUT   write: (simulation) a character to the log
 *   0x2000_0010   TERMS read: [7:0] how many consoles, and so terminals;
 *                 [15:8] HIST, the screens of cells the first terminal has
 *                 beyond its own, for what scrolls off it
 *   0x2000_0014   RESET write 0x52535421 ("RST!"): the whole machine
 *                       starts again, this processor too
 *   0x3000_0000   the virtio slots' requests and what goes with them
 *                 (k_virtio.v's registers for this side)
 *   0x4000_0000   the board's devices for it (x_*: the SD card's SPI
 *                 master, the network's), 64 KB
 *   0x8000_0000   the host's main memory, 512 MB, at the host's own
 *                 addresses, through the host's data cache (p_*:
 *                 k_cache.v's second port): the virtio queues and
 *                 buffers
 *   0xc000_0000   the USB host controller (Zeitlos's rtl/usb/usb_host.v,
 *                 outside this module: u_*), where Zeitlos's driver
 *                 expects it: registers from 0x000, its packet buffer
 *                 from 0x1000
 *
 * The cycle counter (rdcycle, rdcycleh) is there for the USB driver's
 * clock.
 *
 * The host's side is not a bus but its consoles: UART 0 itself,
 * tapped, and the consoles that are only registers (k_vcon.v). con_stb
 * comes with each character the host sends and the number of the
 * console (they queue here, FIFO_BITS deep; con_full holds the host's
 * transmitters off when the queue is full, so nothing is lost), and
 * key_stb puts a character into a console's receiver as if it had
 * come from a pin. UART 0's serial port goes on working beside the
 * screen.
 *
 * The CPU has the compressed instructions: its program is a quarter
 * smaller for them, and its memory is block RAM.
 */

module k_iop #(
	parameter RAM_WORDS = 11264,
	parameter TERMS     = 1,
	parameter HIST      = 0,		// screens of scroll buffer for the first terminal
	parameter USB       = 0,			// 1: something answers on u_*
	parameter FW_HEX    = "iop.hex",
	parameter FIFO_BITS = 8
) (
	input         clk,
	input         rst,

	input         con_stb,
	input   [7:0] con_dat,
	input   [3:0] con_id,
	output        con_full,
	output reg    key_stb,
	output reg [7:0] key_dat,
	output reg [3:0] key_id,
	input   [9:0] key_busy,
	output reg    reset_o,			// one cycle: reset the machine

	output [17:0] t_adr_o,
	output [31:0] t_dat_o,
	input  [31:0] t_dat_i,
	output        t_we_o,
	output  [3:0] t_sel_o,
	output        t_stb_o,
	input         t_ack_i,

	output [10:0] u_adr_o,
	output [31:0] u_dat_o,
	input  [31:0] u_dat_i,
	output        u_we_o,
	output  [3:0] u_sel_o,
	output        u_stb_o,
	input         u_ack_i,

	// the virtio slots (k_virtio.v)
	output        v_req,
	output        v_we,
	output  [2:0] v_adr,
	output [31:0] v_wdat,
	input  [31:0] v_rdat,

	// the host's main memory (k_cache.v's second port)
	output        p_req,
	output [28:0] p_adr,
	output        p_we,
	output  [3:0] p_sel,
	output [31:0] p_wdat,
	input         p_ack,
	input  [31:0] p_rdat,

	// the board's devices
	output [15:0] x_adr_o,
	output [31:0] x_dat_o,
	input  [31:0] x_dat_i,
	output        x_we_o,
	output  [3:0] x_sel_o,
	output        x_stb_o,
	input         x_ack_i,

	output        trap				// the program has stopped: a fault in it
);

	wire        mem_valid, mem_instr;
	reg         mem_ready;
	wire [31:0] mem_addr, mem_wdata;
	wire  [3:0] mem_wstrb;
	reg  [31:0] mem_rdata;

	// What the CPU reads goes through a register, and the answer comes
	// with it, a cycle after the memory's or the device's own: from a
	// block RAM's output (its own memory's, the text mode's) straight
	// into picorv32's decoding was the SOC's longest path as often as
	// the cache's was. act is a request that has not been answered yet.
	reg         raw_ready;
	reg  [31:0] raw_rdata;
	wire        act = mem_valid && !mem_ready;

	picorv32 #(
		.ENABLE_COUNTERS(1),
		.ENABLE_COUNTERS64(1),
		.ENABLE_REGS_16_31(1),
		.ENABLE_REGS_DUALPORT(1),
		.TWO_STAGE_SHIFT(1),
		.BARREL_SHIFTER(0),
		.TWO_CYCLE_COMPARE(0),
		.TWO_CYCLE_ALU(0),
		.COMPRESSED_ISA(1),
		.CATCH_MISALIGN(0),
		.CATCH_ILLINSN(1),
		.ENABLE_MUL(0),
		.ENABLE_DIV(0),
		.ENABLE_IRQ(0),
		.PROGADDR_RESET(32'h0000_0000),
		.STACKADDR(RAM_WORDS * 4)
	) cpu (
		.clk(clk), .resetn(!rst), .trap(trap),
		.mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
		.mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
		.mem_rdata(mem_rdata),
		.mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
		.pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
		.pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
		.irq(32'd0), .eoi(),
		.trace_valid(), .trace_data()
	);

	wire s_ram  = (mem_addr[31:28] == 4'h0);
	wire s_text = (mem_addr[31:28] == 4'h1);
	wire s_reg  = (mem_addr[31:28] == 4'h2);
	wire s_usb  = (mem_addr[31:28] == 4'hc) && (USB != 0);
	wire s_virt = (mem_addr[31:28] == 4'h3);
	wire s_ext  = (mem_addr[31:28] == 4'h4);
	wire s_main = (mem_addr[31:29] == 3'b100);

	// -- the virtio slots: a word a cycle, the answer the cycle after --
	reg  virt_ack;
	assign v_req  = act && s_virt && !virt_ack;
	assign v_we   = |mem_wstrb;
	assign v_adr  = mem_addr[4:2];
	assign v_wdat = mem_wdata;
	always @(posedge clk) virt_ack <= v_req && !rst;

	// -- the host's memory --
	assign p_req  = act && s_main;
	assign p_adr  = { mem_addr[28:2], 2'b00 };
	assign p_we   = |mem_wstrb;
	assign p_sel  = (|mem_wstrb) ? mem_wstrb : 4'b1111;
	assign p_wdat = mem_wdata;

	// -- the board's devices: a read is of the whole word --
	assign x_adr_o = mem_addr[15:0];
	assign x_dat_o = mem_wdata;
	assign x_we_o  = |mem_wstrb;
	assign x_sel_o = (|mem_wstrb) ? mem_wstrb : 4'b1111;
	assign x_stb_o = act && s_ext;

	// -- its memory --
	localparam RB = $clog2(RAM_WORDS);
	reg [31:0] ram [0:RAM_WORDS-1];
	reg [31:0] ram_q;
	reg        ram_ack;
	initial $readmemh(FW_HEX, ram);
	wire ram_req = act && s_ram && !ram_ack;
	always @(posedge clk) begin
		if (ram_req && mem_wstrb[0]) ram[mem_addr[2 +: RB]][7:0]   <= mem_wdata[7:0];
		if (ram_req && mem_wstrb[1]) ram[mem_addr[2 +: RB]][15:8]  <= mem_wdata[15:8];
		if (ram_req && mem_wstrb[2]) ram[mem_addr[2 +: RB]][23:16] <= mem_wdata[23:16];
		if (ram_req && mem_wstrb[3]) ram[mem_addr[2 +: RB]][31:24] <= mem_wdata[31:24];
		ram_q   <= ram[mem_addr[2 +: RB]];
		ram_ack <= ram_req && !rst;
	end

	// -- the text mode --
	assign t_adr_o = mem_addr[17:0];
	assign t_dat_o = mem_wdata;
	assign t_we_o  = |mem_wstrb;
	assign t_sel_o = mem_wstrb;
	assign t_stb_o = act && s_text;

	// -- the USB host controller: a read is of the whole word --
	assign u_adr_o = mem_addr[12:2];
	assign u_dat_o = mem_wdata;
	assign u_we_o  = |mem_wstrb;
	assign u_sel_o = (|mem_wstrb) ? mem_wstrb : 4'b1111;
	assign u_stb_o = act && s_usb;

	// -- the queue of characters from the host --
	// (small, and not in a block RAM: when it is full the consoles wait)
	(* ram_style = "distributed" *)
	reg [11:0] fifo [0:(1<<FIFO_BITS)-1];
	reg [11:0] f_q;
	reg [FIFO_BITS:0] f_wr, f_rd, f_wr_q;		// (a bit more: full and empty differ)
	wire f_have = (f_rd != f_wr_q);				// and f_q is its first
	assign con_full = (f_wr[FIFO_BITS-1:0] == f_rd[FIFO_BITS-1:0]) && (f_wr[FIFO_BITS] != f_rd[FIFO_BITS]);

	// -- the registers --
	reg        reg_ack;
	reg [31:0] reg_q;
	reg [31:0] ticks;
	wire reg_req = act && s_reg && !reg_ack;
	wire reg_wr  = reg_req && mem_wstrb[0];
	wire con_pop = reg_req && !(|mem_wstrb) && (mem_addr[4:2] == 3'd0) && f_have;

	always @(posedge clk) begin
		if (con_stb && !con_full) fifo[f_wr[FIFO_BITS-1:0]] <= { con_id, con_dat };
		f_q <= fifo[con_pop ? f_rd[FIFO_BITS-1:0] + 1'b1 : f_rd[FIFO_BITS-1:0]];
	end

	always @(posedge clk) begin
		key_stb <= 1'b0;
		reset_o <= 1'b0;
		ticks   <= ticks + 32'd1;
		reg_ack <= reg_req;
		f_wr_q  <= f_wr;
		case (mem_addr[4:2])
			3'd0: reg_q <= { 16'd0, f_q[11:8], 3'd0, f_have, f_q[7:0] };
			3'd1: reg_q <= { 22'd0, key_busy[9:1], key_busy[0] || key_stb };
			3'd2: reg_q <= ticks;
			3'd4: reg_q <= (HIST << 8) | TERMS;
			default: reg_q <= 32'd0;
		endcase
		if (rst) begin
			f_wr <= 0; f_rd <= 0; f_wr_q <= 0;
			ticks <= 32'd0;
			reg_ack <= 1'b0;
		end else begin
			if (con_stb && !con_full) f_wr <= f_wr + 1'b1;
			if (con_pop) f_rd <= f_rd + 1'b1;
			if (reg_wr && mem_addr[4:2] == 3'd5 && mem_wdata == 32'h5253_5421) reset_o <= 1'b1;
			if (reg_wr && mem_addr[4:2] == 3'd1) begin
				key_stb <= 1'b1;
				key_dat <= mem_wdata[7:0];
				key_id  <= mem_wdata[11:8];
			end
`ifndef SYNTHESIS_ONLY
`ifdef K_IOP_LOG
			if (reg_wr && mem_addr[4:2] == 3'd3) $write("%c", mem_wdata[7:0]);
`endif
`endif
		end
	end

	always @(*) begin
		raw_ready = s_ram ? ram_ack : s_text ? t_ack_i : s_reg ? reg_ack : s_usb ? u_ack_i :
			s_virt ? virt_ack : s_main ? p_ack : s_ext ? x_ack_i : 1'b1;
		// (where nothing is, zero: the USB driver looks for its controller)
		raw_rdata = s_ram ? ram_q : s_text ? t_dat_i : s_usb ? u_dat_i : s_reg ? reg_q :
			s_virt ? v_rdat : s_main ? p_rdat : s_ext ? x_dat_i : 32'd0;
	end

	always @(posedge clk) begin
		mem_ready <= act && raw_ready && !rst;
		mem_rdata <= raw_rdata;
	end

endmodule
