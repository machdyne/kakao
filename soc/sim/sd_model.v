/*
 * sd_model -- an SD card in SPI mode, as far as a boot loader goes:
 * CMD0, CMD8, CMD55 + ACMD41 (ready at the third try), CMD58, CMD16,
 * CMD17 (read a block). Its contents are the file IMAGE, read as it is
 * asked for. SDHC=1: addresses are blocks; 0: bytes.
 *
 * It complains of a command it does not know, of one before CMD0, of
 * a read past the image's end, and of a clock faster than 400 kHz
 * before it is ready (FAST_NS: the shortest clock period allowed
 * then).
 */

`timescale 1ns / 1ps

module sd_model #(
	parameter IMAGE = "card.img",
	parameter SDHC = 1,
	parameter FAST_NS = 2400
) (
	input  cs_n,
	input  sck,
	input  mosi,
	output miso
);

	integer fd, n, k, errors = 0, blocks_read = 0;
	reg [7:0] tx [0:527];			// what is still to send
	integer tx_n = 0, tx_i = 0;
	reg [7:0] sh_in, sh_out = 8'hff;
	integer bits = 0;
	reg [47:0] cmd;
	integer cmd_n = 0;
	reg idle = 0, ready = 0, app = 0;
	integer tries = 0;
	realtime t_rise = 0;

	assign miso = cs_n ? 1'bz : sh_out[7];

	initial begin
		fd = $fopen(IMAGE, "rb");
		if (fd == 0) begin $display("[sd] cannot open %s", IMAGE); errors = errors + 1; end
	end

	task answer(input [7:0] r1);
		begin tx[0] = 8'hff; tx[1] = r1; tx_n = 2; tx_i = 0; end
	endtask

	task command;
		reg [5:0] c;
		reg [31:0] arg;
		integer off;
		begin
			c = cmd[45:40]; arg = cmd[39:8];
			if (!idle && c != 0) begin
				$display("[sd] CMD%0d before CMD0", c); errors = errors + 1;
			end
			if (app && c == 41) begin
				tries = tries + 1;
				ready = (tries >= 3);
				answer(ready ? 8'h00 : 8'h01);
			end else case (c)
				0: begin idle = 1; ready = 0; tries = 0; answer(8'h01); end
				8: begin
					answer(8'h01);
					tx[2] = 8'h00; tx[3] = 8'h00; tx[4] = 8'h01; tx[5] = arg[7:0]; tx_n = 6;
				end
				55: answer(ready ? 8'h00 : 8'h01);
				58: begin
					answer(ready ? 8'h00 : 8'h01);
					tx[2] = SDHC ? 8'hc0 : 8'h80; tx[3] = 8'hff; tx[4] = 8'h80; tx[5] = 8'h00; tx_n = 6;
				end
				16: answer(arg == 512 ? 8'h00 : 8'h40);
				17: begin
					if (!ready) begin $display("[sd] a read before the card is ready"); errors = errors + 1; end
					off = SDHC ? arg * 512 : arg;
					k = $fseek(fd, off, 0);
					answer(8'h00);
					tx[2] = 8'hff; tx[3] = 8'hff; tx[4] = 8'hfe;
					for (n = 0; n < 512; n = n + 1) begin
						k = $fgetc(fd);
						if (k < 0) begin
							if (n == 0) begin $display("[sd] read past the end: block %0d", off / 512); errors = errors + 1; end
							k = 0;
						end
						tx[5 + n] = k[7:0];
					end
					tx[517] = 8'h12; tx[518] = 8'h34;
					tx_n = 519;
					blocks_read = blocks_read + 1;
				end
				default: begin
					$display("[sd] CMD%0d is not known here", c); errors = errors + 1;
					answer(8'h04);
				end
			endcase
			app = (c == 55);
		end
	endtask

	always @(posedge sck) begin
		if (!ready && t_rise != 0 && ($realtime - t_rise) < FAST_NS) begin
			if (errors < 5) $display("[sd] clocked at %0t ns a bit before it is ready", $realtime - t_rise);
			errors = errors + 1;
		end
		t_rise = $realtime;
		if (!cs_n) begin
			sh_in = { sh_in[6:0], mosi };
			bits = bits + 1;
			if (bits == 8) begin
				bits = 0;
				// a command starts with 01 and is six bytes; nothing is
				// listened to while an answer is going out
				if (cmd_n != 0 || (tx_i >= tx_n && sh_in[7:6] == 2'b01)) begin
					cmd = { cmd[39:0], sh_in };
					cmd_n = cmd_n + 1;
					if (cmd_n == 6) begin cmd_n = 0; command; end
				end
			end
		end
	end

	always @(negedge sck or posedge cs_n) begin
		if (cs_n) begin
			bits = 0; cmd_n = 0; sh_out = 8'hff; tx_n = 0; tx_i = 0;
		end else if (bits == 0) begin
			if (tx_i < tx_n) begin sh_out = tx[tx_i]; tx_i = tx_i + 1; end
			else sh_out = 8'hff;
		end else
			sh_out = { sh_out[6:0], 1'b1 };
	end

endmodule
