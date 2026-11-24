/*
 * rmii_peer -- what is at the other end of the network cable, for the
 * simulation: the RMII pins on one side, whole frames for the
 * simulation's main program on the other (sim_main.cpp, which answers
 * ARP and pings).
 *
 * A frame the MAC sends comes out a byte at a time (tx_stb, tx_byte),
 * from its destination address to its checksum, and tx_end follows.
 * A frame to the MAC is put into rxf (with its checksum) and its
 * length into rx_len, and rx_go starts it; rx_busy until it has gone,
 * with the gap after it.
 *
 * Also what the MAC's pins are made of on the FPGA (the I/O cells'
 * flip-flops), as far as it uses them.
 */

`timescale 1ns / 1ps

module rmii_peer (
	input            clk,			// the reference clock
	input            rst,
	input      [1:0] txd,
	input            tx_en,
	output reg [1:0] rxd,
	output reg       crs_dv,

	output reg       tx_stb,
	output reg [7:0] tx_byte,
	output reg       tx_end,

	input            rx_go,
	input     [11:0] rx_len,
	output           rx_busy
);

	reg [7:0] rxf [0:2047] /*verilator public*/;

	// -- from the MAC: after the preamble's last byte (0xd5), bytes --
	reg  [1:0] t_n;
	reg  [7:0] t_sh;
	reg        t_in;				// past the preamble
	reg        t_en_q;
	wire [7:0] t_b = { txd, t_sh[7:2] };
	always @(posedge clk) begin
		tx_stb <= 1'b0;
		tx_end <= 1'b0;
		t_en_q <= tx_en;
		if (rst || !tx_en) begin
			t_n <= 0; t_in <= 1'b0;
			if (t_en_q && t_in) tx_end <= 1'b1;
		end else begin
			t_sh <= t_b;
			if (!t_in) begin
				// (the first bits of all go first: 0xd5 ends in 11)
				if (t_b == 8'hd5) begin t_in <= 1'b1; t_n <= 0; end
			end else begin
				t_n <= t_n + 2'd1;
				if (t_n == 2'd3) begin tx_stb <= 1'b1; tx_byte <= t_b; end
			end
		end
	end

	// -- to the MAC: seven bytes of 0x55, 0xd5, the frame, a gap --
	reg [11:0] r_i;					// 0..7 the preamble, then the frame's bytes
	reg  [1:0] r_n;
	reg  [1:0] r_st;				// 0 idle, 1 sending, 2 the gap
	reg  [7:0] r_gap;
	wire [7:0] r_b = (r_i < 12'd7) ? 8'h55 : (r_i == 12'd7) ? 8'hd5 : rxf[r_i - 12'd8];
	assign rx_busy = (r_st != 2'd0);
	always @(posedge clk) begin
		if (rst) begin
			r_st <= 0; crs_dv <= 1'b0; rxd <= 2'b00;
		end else case (r_st)
			2'd0: begin
				crs_dv <= 1'b0; rxd <= 2'b00;
				if (rx_go) begin r_st <= 2'd1; r_i <= 0; r_n <= 0; end
			end
			2'd1: begin
				crs_dv <= 1'b1;
				rxd <= r_b[2 * r_n +: 2];
				r_n <= r_n + 2'd1;
				if (r_n == 2'd3) begin
					r_i <= r_i + 12'd1;
					if (r_i == rx_len + 12'd7) begin r_st <= 2'd2; r_gap <= 8'd100; end
				end
			end
			default: begin
				crs_dv <= 1'b0; rxd <= 2'b00;
				r_gap <= r_gap - 8'd1;
				if (r_gap == 8'd0) r_st <= 2'd0;
			end
		endcase
	end

endmodule

// the ECP5's I/O cell flip-flops, as the MAC uses them
module IFS1P3DX (input SCLK, input SP, input CD, input D, output reg Q);
	initial Q = 1'b0;
	always @(posedge SCLK) if (CD) Q <= 1'b0; else if (SP) Q <= D;
endmodule

module OFS1P3DX (input SCLK, input SP, input CD, input D, output reg Q);
	initial Q = 1'b0;
	always @(posedge SCLK) if (CD) Q <= 1'b0; else if (SP) Q <= D;
endmodule
