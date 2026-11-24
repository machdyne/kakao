/*
 * sd_card -- an SDHC card in SPI mode with a clock, for the simulations
 * that Verilator runs (sd_model.v is the one with delays, for kboot's):
 * CMD0, CMD8, CMD55 + ACMD41 (ready at the third try), CMD58, CMD9
 * (its size), CMD17 and CMD24 (read and write a block; after a write it
 * is busy for a while). Its contents are img, which the simulation's
 * main program fills and can write out again.
 *
 * sck is looked at on clk: it must be slower than half of clk.
 */

`timescale 1ns / 1ps

module sd_card #(
`ifndef SIM_SD_MB
`define SIM_SD_MB 16
`endif
	// (a multiple of 1024. Its size is set with -DSIM_SD_MB=, not as a
	// parameter where it is used: the simulation's C++ names this module)
	parameter SECTORS = `SIM_SD_MB * 2048,
`ifndef SIM_SD_LOW_MB
`define SIM_SD_LOW_MB `SIM_SD_MB
`define SIM_SD_HI_MB `SIM_SD_MB
`define SIM_SD_HILEN_MB 0
`endif
	// A card larger than the simulation can hold: of its SIM_SD_MB
	// megabytes only the first SIM_SD_LOW_MB and the SIM_SD_HILEN_MB
	// from megabyte SIM_SD_HI_MB on are there, one after the other in
	// img; the rest reads as zeros and is not written. For blocks with
	// large numbers, which a small card never has.
	parameter LOW = `SIM_SD_LOW_MB * 2048,
	parameter HIB = `SIM_SD_HI_MB * 2048,
	parameter HIL = `SIM_SD_HILEN_MB * 2048,
	parameter BUSY = 40				// bytes of "busy" after a block is written
) (
	input      clk,
	input      rst,
	input      cs_n,
	input      sck,
	input      mosi,
	output     miso
);

	reg [7:0] img [0:(LOW+HIL)*512-1] /*verilator public*/;
	wire        in_low = (blk < LOW);
	wire        in_hi  = (blk >= HIB) && (blk < HIB + HIL);
	wire        in_gap = !in_low && !in_hi;
	wire [31:0] iblk   = in_low ? blk : LOW + (blk - HIB);
	integer n_rd /*verilator public*/, n_wr /*verilator public*/, errors /*verilator public*/;

	reg        sck_q;
	reg  [7:0] sh_in, tx;
	reg  [2:0] bits;
	reg        fresh;				// tx was put there whole: its first bit is still to go out
	wire [7:0] rx = { sh_in[6:0], mosi };
	assign miso = cs_n ? 1'b1 : tx[7];

	localparam P_CMD = 0, P_RSP = 1, P_RD = 2, P_WRTOK = 3, P_WRDAT = 4, P_BUSY = 5;
	reg  [2:0] ph;
	reg [47:0] cmd;
	reg  [2:0] cmd_n;
	reg  [7:0] rsp [0:7];
	reg  [3:0] rsp_n, rsp_i;
	reg  [1:0] after;				// after the answer: 0 nothing, 1 a block read, 2 a block written, 3 the CSD
	reg [31:0] blk;
	reg [10:0] cnt;
	reg        idle, ready, app;
	reg  [1:0] tries;

	wire [5:0]  c   = cmd[45:40];
	wire [31:0] arg = cmd[39:8];
	wire [21:0] c_size = SECTORS / 1024 - 1;

	function [7:0] csd(input [3:0] i);
		case (i)
			4'd0: csd = 8'h40;
			4'd7: csd = { 2'b00, c_size[21:16] };
			4'd8: csd = c_size[15:8];
			4'd9: csd = c_size[7:0];
			default: csd = 8'h00;
		endcase
	endfunction

	initial begin n_rd = 0; n_wr = 0; errors = 0; end

	always @(posedge clk) begin
		sck_q <= sck;
		if (rst || cs_n) begin
			bits <= 0; tx <= 8'hff; fresh <= 1'b1;
			if (rst) begin
				ph <= P_CMD; cmd_n <= 0; idle <= 0; ready <= 0; app <= 0; tries <= 0;
			end else if (ph != P_BUSY) begin
				ph <= P_CMD; cmd_n <= 0;
			end
		end else if (!sck && sck_q) begin
			fresh <= 1'b0;
			if (!fresh) tx <= { tx[6:0], 1'b1 };
		end else if (sck && !sck_q) begin
			sh_in <= rx;
			bits <= bits + 3'd1;
			if (bits == 3'd7) begin
				// a byte is in: rx. What goes out with the next is put
				// into tx here
				tx <= 8'hff;
				fresh <= 1'b1;
				case (ph)
				P_CMD: begin
					if (cmd_n != 0 || rx[7:6] == 2'b01) begin
						cmd <= { cmd[39:0], rx };
						cmd_n <= cmd_n + 3'd1;
						if (cmd_n == 3'd5) begin
							cmd_n <= 0;
							ph <= P_RSP; rsp_i <= 0; rsp_n <= 1; after <= 0;
						end
					end
				end
				P_RSP: begin
					// (cmd is whole now; the answer's first byte comes
					// after one of all ones)
					if (rsp_i == 0) begin
						rsp_i <= 1;
						rsp[1] <= 8'h00; rsp[2] <= 8'h00; rsp[3] <= 8'h00; rsp[4] <= 8'h00;
						app <= 1'b0;
						if (!idle && c != 6'd0) begin
							$display("[sd] CMD%0d before CMD0", c); errors = errors + 1;
						end
						if (app && c == 6'd41) begin
							tries <= tries + 2'd1;
							if (tries == 2'd2) ready <= 1'b1;
							rsp[0] <= (tries == 2'd2) ? 8'h00 : 8'h01;
						end else case (c)
							6'd0:  begin idle <= 1'b1; ready <= 1'b0; tries <= 0; rsp[0] <= 8'h01; end
							6'd8:  begin rsp[0] <= 8'h01; rsp[3] <= 8'h01; rsp[4] <= 8'haa; rsp_n <= 5; end
							6'd55: begin app <= 1'b1; rsp[0] <= ready ? 8'h00 : 8'h01; end
							6'd58: begin rsp[0] <= ready ? 8'h00 : 8'h01; rsp[1] <= 8'hc0; rsp[2] <= 8'hff; rsp[3] <= 8'h80; rsp_n <= 5; end
							6'd16: rsp[0] <= 8'h00;
							6'd9:  begin rsp[0] <= 8'h00; after <= 2'd3; end
							6'd17, 6'd24: begin
								blk <= arg;
								if (!ready || arg >= SECTORS) begin
									$display("[sd] CMD%0d of block %0d: not ready, or past the end", c, arg);
									errors = errors + 1;
									rsp[0] <= 8'h40;
								end else begin
									rsp[0] <= 8'h00;
									after <= (c == 6'd17) ? 2'd1 : 2'd2;
								end
							end
							default: begin
								$display("[sd] CMD%0d is not known here", c); errors = errors + 1;
								rsp[0] <= 8'h04;
							end
						endcase
					end else begin
						tx <= rsp[rsp_i - 4'd1];
						rsp_i <= rsp_i + 4'd1;
						if (rsp_i == rsp_n) begin
							cnt <= 0;
							ph <= (after == 2'd1 || after == 2'd3) ? P_RD : (after == 2'd2) ? P_WRTOK : P_CMD;
						end
					end
				end
				P_RD: begin
					// two bytes of waiting, the token, the data, two of CRC
					cnt <= cnt + 11'd1;
					if (cnt == 11'd2) tx <= 8'hfe;
					else if (cnt >= 11'd3 && after == 2'd3 && cnt < 11'd19) tx <= csd(cnt - 11'd3);
					else if (cnt >= 11'd3 && after == 2'd1 && cnt < 11'd515) tx <= in_gap ? 8'h00 : img[iblk * 512 + cnt - 3];
					if (cnt == (after == 2'd3 ? 11'd20 : 11'd516)) begin
						ph <= P_CMD;
						if (after == 2'd1) n_rd = n_rd + 1;
					end
				end
				P_WRTOK: begin
					if (rx == 8'hfe) begin ph <= P_WRDAT; cnt <= 0; end
				end
				P_WRDAT: begin
					cnt <= cnt + 11'd1;
					if (cnt < 11'd512 && !in_gap) img[iblk * 512 + cnt] <= rx;
					if (cnt == 11'd513) begin
						tx <= 8'he5;				// the data was taken
						ph <= P_BUSY; cnt <= 0;
						n_wr = n_wr + 1;
					end
				end
				P_BUSY: begin
					cnt <= cnt + 11'd1;
					tx <= 8'h00;
					if (cnt == BUSY) begin tx <= 8'hff; ph <= P_CMD; end
				end
				default: ph <= P_CMD;
				endcase
			end
		end
	end

endmodule
