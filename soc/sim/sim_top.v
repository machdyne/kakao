/*
 * sim_top -- kakao32 with just enough of the Kakao SOC around it to
 * boot Linux in simulation (Verilator; see README.md here):
 *
 *   0x0000_1000   a three-instruction boot stub: a0 = 0 (the hart),
 *                 a1 = the device tree's address, jump to 0x8000_0000
 *   0x0010_0000   the reset/power-off device: a write of 0x5555 ends
 *                 the simulation
 *   0x0200_0000   CLINT: msip, mtimecmp (0x4000), mtime (0xbff8),
 *                 mtime counting clock cycles
 *   0x1000_0000   a 16550, as far as a polling driver goes: writes to
 *                 THR are printed, LSR says the transmitter is empty
 *                 and whether a character waits, RBR gives it
 *   0xf000_1000   a LiteX UART, as far as its polling driver goes
 *                 (the prebuilt Kakao kernel's console)
 *   0x8000_0000   memory, MEM_MB megabytes, answering the next cycle
 *
 * Characters typed at the simulation arrive on both UARTs (rx_put).
 */

`timescale 1ns / 1ps

module sim_top #(
	parameter MEM_MB = 64,
	parameter [31:0] DTB_ADDR = 32'h83e0_0000
) (
	input        clk,
	input        rst,
	// a character from the outside, for one cycle
	input        rx_put,
	input  [7:0] rx_char,
	output       rx_busy,			// the last one has not been read yet
	// a character to the outside, for one cycle
	output reg       tx_put,
	output reg [7:0] tx_char,
	output reg       poweroff
);

	localparam MEM_WORDS = MEM_MB * 262144;

	wire        m_req, m_we, m_instr;
	wire [31:0] m_adr, m_wdat;
	wire  [3:0] m_sel;
	reg         m_ack;
	reg  [31:0] m_rdat;

	reg  [63:0] mtime, mtimecmp;
	reg         msip;

	kakao32 #(
		.RESET_PC(32'h0000_1000)
	) cpu (
		.clk(clk), .rst(rst),
		.m_req(m_req), .m_adr(m_adr), .m_we(m_we), .m_sel(m_sel),
		.m_wdat(m_wdat), .m_instr(m_instr),
		.m_rdy(1'b1), .m_ack(m_ack), .m_rdat(m_rdat),
		.mtime(mtime),
		.irq_msi(msip), .irq_mti(mtime >= mtimecmp), .irq_mei(1'b0),
		.irq_sei(1'b0)
	);

	reg [31:0] ram [0:MEM_WORDS-1] /*verilator public*/;

	reg        rx_v;
	reg  [7:0] rx_c;
	assign rx_busy = rx_v;

	wire is_ram   = (m_adr[31:28] == 4'h8) && (m_adr[27:2] < MEM_WORDS);
	wire is_clint = (m_adr[31:16] == 16'h0200);
	wire is_uart  = (m_adr[31:8]  == 24'h100000);
	wire is_lxu   = (m_adr[31:8]  == 24'hf00010);
	wire is_test  = (m_adr[31:12] == 20'h00100);
	wire is_rom   = (m_adr[31:12] == 20'h00001);

	wire [31:0] rom_q =
		(m_adr[11:2] == 10'd0) ? { DTB_ADDR[31:12], 5'd11, 7'b0110111 } :	// lui a1, dtb
		(m_adr[11:2] == 10'd1) ? 32'h0000_0513 :							// li a0, 0
		(m_adr[11:2] == 10'd2) ? 32'h8000_02b7 :							// lui t0, 0x80000
		                         32'h0002_8067;								// jr t0

	// the 16550's byte registers, in the lanes of their word
	wire [31:0] uart_q =
		(m_adr[7:2] == 6'd0) ? { 24'd0, rx_c } :					// RBR
		(m_adr[7:2] == 6'd1) ? { 16'd0, 7'b0110000, rx_v, 8'd0 } :	// LSR at byte 5
		32'd0;
	wire [31:0] lxu_q =
		(m_adr[7:2] == 6'd0) ? { 24'd0, rx_c } :		// RXTX
		(m_adr[7:2] == 6'd2) ? { 31'd0, !rx_v } :		// RXEMPTY
		32'd0;										// TXFULL and the rest
	wire [31:0] clint_q =
		(m_adr[15:2] == 14'h0000) ? { 31'd0, msip } :
		(m_adr[15:2] == 14'h1000) ? mtimecmp[31:0] :
		(m_adr[15:2] == 14'h1001) ? mtimecmp[63:32] :
		(m_adr[15:2] == 14'h2ffe) ? mtime[31:0] :
		(m_adr[15:2] == 14'h2fff) ? mtime[63:32] : 32'd0;

	always @(posedge clk) begin
		tx_put <= 1'b0;
		mtime  <= mtime + 64'd1;
		if (rst) begin
			m_ack <= 1'b0;
			mtime <= 64'd0;
			mtimecmp <= 64'hffff_ffff_ffff_ffff;
			msip <= 1'b0;
			rx_v <= 1'b0;
			poweroff <= 1'b0;
		end else begin
			m_ack <= m_req;
			if (rx_put) begin
				rx_v <= 1'b1;
				rx_c <= rx_char;
			end
			if (m_req) begin
				m_rdat <= is_ram ? ram[m_adr[27:2]] :
				          is_rom ? rom_q : is_clint ? clint_q :
				          is_uart ? uart_q : is_lxu ? lxu_q : 32'd0;
				// reading the character takes it (the 16550); the LiteX
				// UART's is taken by a write to its EV_PENDING
				if (!m_we && is_uart && m_adr[7:2] == 6'd0 && m_sel[0]) rx_v <= 1'b0;
				if (m_we) begin
					if (is_ram) begin
						if (m_sel[0]) ram[m_adr[27:2]][7:0]   <= m_wdat[7:0];
						if (m_sel[1]) ram[m_adr[27:2]][15:8]  <= m_wdat[15:8];
						if (m_sel[2]) ram[m_adr[27:2]][23:16] <= m_wdat[23:16];
						if (m_sel[3]) ram[m_adr[27:2]][31:24] <= m_wdat[31:24];
					end
					if (is_clint) begin
						if (m_adr[15:2] == 14'h0000) msip <= m_wdat[0];
						if (m_adr[15:2] == 14'h1000) mtimecmp[31:0]  <= m_wdat;
						if (m_adr[15:2] == 14'h1001) mtimecmp[63:32] <= m_wdat;
						if (m_adr[15:2] == 14'h2ffe) mtime[31:0]  <= m_wdat;
						if (m_adr[15:2] == 14'h2fff) mtime[63:32] <= m_wdat;
					end
					if ((is_uart || is_lxu) && m_adr[7:2] == 6'd0 && m_sel[0]) begin
						tx_put  <= 1'b1;
						tx_char <= m_wdat[7:0];
					end
					if (is_lxu && m_adr[7:2] == 6'd4 && m_wdat[1]) rx_v <= 1'b0;
					if (is_test && m_wdat[15:0] == 16'h5555) poweroff <= 1'b1;
				end
			end
		end
	end

endmodule
