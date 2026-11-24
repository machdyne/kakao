/*
 * tb_k_text -- k_text draws a screen: text in every colour, the boxes,
 * a scrolled ring and the cursor, one frame of it written to
 * obj/k_text.ppm; and the frame is checked against the font, pixel by
 * pixel, for the cells that were written.
 *
 *   make text
 */

`timescale 1ns / 1ps

module tb_k_text;

	reg clk = 0, pclk = 0, rst = 1;
	always #10.4 clk = !clk;		// 48 MHz
	always #19.8 pclk = !pclk;		// 25.2 MHz

	reg  [17:0] adr = 0;
	reg  [31:0] wdat = 0;
	wire [31:0] rdat;
	reg         we = 0, stb = 0;
	wire        ack;
	wire  [7:0] r, g, b;
	wire        hs, vs, bl;
	wire [10:0] hc, vc;

	k_text #(.TERMS(2), .FONT_HEX("obj/k_font.hex")) dut (
		.clk(clk), .rst(rst),
		.adr_i(adr), .dat_i(wdat), .dat_o(rdat), .we_i(we), .sel_i(4'b1111),
		.stb_i(stb), .ack_o(ack),
		.pclk(pclk), .red(r), .green(g), .blue(b), .hsync(hs), .vsync(vs), .blank(bl),
		.hc(hc), .vc(vc)
	);

	reg [7:0] font [0:4095];
	reg [15:0] shadow [0:4799];
	integer errors = 0;

	task wr(input [17:0] a, input [31:0] d);
		begin
			@(posedge clk); adr <= a; wdat <= d; we <= 1; stb <= 1;
			@(posedge clk); while (!ack) @(posedge clk);
			stb <= 0; we <= 0;
			if (!a[17]) shadow[a[16:2]] = d[15:0];
		end
	endtask

	task rd(input [17:0] a, output [31:0] d);
		begin
			@(posedge clk); adr <= a; we <= 0; stb <= 1;
			@(posedge clk); while (!ack) @(posedge clk);
			d = rdat; stb <= 0;
		end
	endtask

	localparam BASE = 2400;			// the second of two screens is shown,
	localparam TOPR = 27;			// its ring turned: rows 27, 28, 29, 0, 1, ...

	// the cell of a row and column of the picture: the second screen's,
	// its ring turned
	function [14:0] cell_at(input integer row, input integer col);
		cell_at = BASE + ((TOPR + row) % 30) * 80 + col;
	endfunction

	task put(input integer row, input integer col, input [7:0] c, input [7:0] attr);
		begin
			wr({ 1'b0, cell_at(row, col), 2'b00 }, { 16'd0, attr, c });
		end
	endtask

	task puts(input integer row, input integer col, input [8*80-1:0] s, input [7:0] attr);
		integer k, n;
		begin
			n = 0;
			for (k = 79; k >= 0; k = k - 1)
				if (s[k*8 +: 8] != 0) begin put(row, col + n, s[k*8 +: 8], attr); n = n + 1; end
		end
	endtask

	integer i, j, f, x, y;
	reg [31:0] d;
	reg [23:0] frame [0:640*480-1];

	// the PC's colours, as the module should make them
	function [23:0] rgb(input [3:0] c);
		reg [7:0] lo;
		begin
			lo = c[3] ? 8'h55 : 8'h00;
			rgb = { (c[2] ? 8'haa : 8'h00) | lo,
				(c == 4'd6) ? 8'h55 : ((c[1] ? 8'haa : 8'h00) | lo),
				(c[0] ? 8'haa : 8'h00) | lo };
		end
	endfunction

	reg [15:0] oshadow [0:4095];
	reg [23:0] palm [0:31];
	initial begin
		for (i = 0; i < 4096; i = i + 1) oshadow[i] = 16'd0;
		for (i = 0; i < 32; i = i + 1) palm[i] = rgb(i[3:0]);
	end

	// the frame against the font, the cells and (on) the overlay
	integer ptr_pos = 3 * 80 + 5;	// where the pointer is
	task check(input on, input dim);
		integer xx, yy;
		begin
			for (yy = 0; yy < 480; yy = yy + 1)
				for (xx = 0; xx < 640; xx = xx + 1) begin : px
					reg [15:0] c, o; reg dot, is_o; reg [23:0] want;
					c = shadow[cell_at(yy / 16, xx / 8)];
					o = oshadow[(yy / 16) * 80 + xx / 8];
					is_o = on && (o != 0);
					if (is_o) c = o; else if (on && dim) c = { 8'h08, c[7:0] };
					dot = font[{ c[7:0], 4'd0 } + (yy % 16)][7 - (xx % 8)];
					if (yy / 16 == 21 && xx / 8 == 27 && !is_o) dot = !dot;		// the cursor
					// the pointer, and the selection (the pointer within it is not exchanged twice)
					begin : inv
						integer pos; reg pi, si;
						pos = (yy / 16) * 80 + xx / 8;
						pi = (pos == ptr_pos);
						si = (pos >= 4 * 80 + 10) && (pos <= 5 * 80 + 20);
						if (!is_o && (pi ^ si)) dot = !dot;
					end
					want = palm[{ is_o, dot ? c[11:8] : c[15:12] }];
					if (frame[yy * 640 + xx] !== want) begin
						if (errors < 10) $display("FAIL(%0d%0d): c %04x o %04x dot %0d pixel %0d,%0d is %06x, should be %06x", on, dim, c, o, dot, xx, yy, frame[yy * 640 + xx], want);
						errors = errors + 1;
					end
				end
		end
	endtask

	// capture: the picture starts where blank falls
	integer cx = 0, cy = 0;
	reg capture = 0, bl_q = 1, vs_q = 1;
	integer hs_len = 0, vs_lines = 0, n_frames = 0;
	always @(posedge pclk) begin
		bl_q <= bl; vs_q <= vs;
		if (capture) begin
			if (!bl) begin
				frame[cy * 640 + cx] = { r, g, b };
				cx = cx + 1;
			end else if (!bl_q && bl) begin		// the end of a line
				if (cx != 640) begin $display("FAIL: a line of %0d pixels", cx); errors = errors + 1; end
				cx = 0; cy = cy + 1;
			end
		end
	end

	initial begin
		$readmemh("obj/k_font.hex", font);
		for (i = 0; i < 4800; i = i + 1) shadow[i] = 16'h0720;
		repeat (5) @(posedge clk);
		rst <= 0;

		rd(18'h2000c, d);
		if (d[31:16] !== 16'h7e88) begin $display("FAIL: status %08x", d); errors = errors + 1; end

		// the first screen full of #, which must not show; every cell of
		// the second a grey space
		for (i = 0; i < 2400; i = i + 1) wr({ 1'b0, i[14:0], 2'b00 }, 32'h4f23);
		for (i = 2400; i < 4800; i = i + 1) wr({ 1'b0, i[14:0], 2'b00 }, 32'h0720);
		wr(18'h20010, BASE);
		wr(18'h20014, BASE + 2400);
		wr(18'h20008, BASE + TOPR * 80);

		puts(0, 0, "Kakao -- kakao32 text mode, 80 x 30", 8'h0f);
		puts(1, 0, "0123456789012345678901234567890123456789012345678901234567890123456789012345678|", 8'h07);
		for (i = 0; i < 16; i = i + 1) begin
			puts(3 + i, 2, "The quick brown fox jumps over the lazy dog", { 4'h0, i[3:0] });
			puts(3 + i, 48, " colour on colour ", { i[3:0], ~i[3:0] });
		end
		// a box
		put(20, 2, 8'hda, 8'h0b); for (i = 3; i < 30; i = i + 1) put(20, i, 8'hc4, 8'h0b); put(20, 30, 8'hbf, 8'h0b);
		put(21, 2, 8'hb3, 8'h0b); puts(21, 4, "root@kakao:~# uname -m", 8'h0a); put(21, 30, 8'hb3, 8'h0b);
		put(22, 2, 8'hc0, 8'h0b); for (i = 3; i < 30; i = i + 1) put(22, i, 8'hc4, 8'h0b); put(22, 30, 8'hd9, 8'h0b);
		for (i = 0; i < 8; i = i + 1) put(24, 2 + i, 8'hb0 + (i % 3), 8'h0e);
		put(24, 12, 8'hdb, 8'h0c); put(24, 13, 8'hdc, 8'h0c); put(24, 14, 8'hdf, 8'h0c);
		puts(29, 0, "the bottom row", 8'h70);
		put(29, 79, "X", 8'h4f);

		// read one back
		rd({ 1'b0, cell_at(0, 0), 2'b00 }, d);
		if (d !== 32'h0000_0f4b) begin $display("FAIL: cell read %08x", d); errors = errors + 1; end

		// the cursor: a block after the prompt, not blinking
		wr(18'h20004, cell_at(21, 27));
		wr(18'h20000, 32'b1011);
		// the pointer on a cell, and two rows' worth selected
		wr(18'h20018, 32'h8000 | (3 * 80 + 5));
		wr(18'h2001c, 32'h8000_0000 | ((5 * 80 + 20) << 16) | (4 * 80 + 10));

		// two frames go by, the second is kept
		@(negedge vs); @(posedge vs);
		@(negedge vs); cx = 0; cy = 0; capture = 1;
		@(negedge vs); capture = 0;
		if (cy != 480) begin $display("FAIL: %0d lines", cy); errors = errors + 1; end

		check(0, 0);

		// the overlay: a box over rows 5..10, its own colours, the rest
		// dimmed; and a colour of each changed
		for (y = 5; y <= 10; y = y + 1)
			for (x = 20; x <= 50; x = x + 1) begin
				oshadow[y * 80 + x] = (y == 5 || y == 10) ? 16'h6fc4 : (x == 20 || x == 50) ? 16'h6fb3 : (16'h6e00 | (8'h41 + x - 20));
				wr(18'h30000 + ((y * 80 + x) << 2), { 16'd0, oshadow[y * 80 + x] });
			end
		oshadow[24 * 80 + 79] = 16'h6f58;		// the overlay's last cell
		wr(18'h30000 + ((24 * 80 + 79) << 2), 32'h6f58);
		oshadow[7 * 80 + 30] = 16'h0020;		// a black space is a cell too
		wr(18'h30000 + ((7 * 80 + 30) << 2), 32'h0020);
		palm[8] = 24'h123456;  wr(18'h20080 + (8 << 2), 32'h123456);
		palm[16 + 6] = 24'habcdef; wr(18'h20080 + (22 << 2), 32'habcdef);
		wr(18'h20000, 32'b111011);
		@(negedge vs); @(posedge vs);
		@(negedge vs); cx = 0; cy = 0; capture = 1;
		@(negedge vs); capture = 0;
		check(1, 1);

		// the overlay off again: the screen as it was, but for the colour
		ptr_pos = 5 * 80 + 2;
		wr(18'h20018, 32'h8000 | ptr_pos);
		wr(18'h20000, 32'b101011);
		@(negedge vs); @(posedge vs);
		@(negedge vs); cx = 0; cy = 0; capture = 1;
		@(negedge vs); capture = 0;
		check(0, 0);

		// (the picture kept is the one with the overlay)
		wr(18'h20000, 32'b111011);
		@(negedge vs); @(posedge vs);
		@(negedge vs); cx = 0; cy = 0; capture = 1;
		@(negedge vs); capture = 0;

		f = $fopen("obj/k_text.ppm", "w");
		$fwrite(f, "P3\n640 480\n255\n");
		for (i = 0; i < 640 * 480; i = i + 1)
			$fwrite(f, "%0d %0d %0d\n", frame[i][23:16], frame[i][15:8], frame[i][7:0]);
		$fclose(f);

		if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
		$finish;
	end

	// the timing of the syncs: 800 clocks a line, 96 of them hsync
	integer h_per = 0, h_low = 0, h_cnt = 0, l_cnt = 0;
	reg hs_q = 1;
	always @(posedge pclk) begin
		hs_q <= hs;
		h_cnt = h_cnt + 1;
		if (!hs) l_cnt = l_cnt + 1;
		if (hs_q && !hs) begin
			if (h_per > 2 && (h_cnt != 800 || l_cnt != 97)) begin
				$display("FAIL: a line of %0d clocks, hsync %0d", h_cnt, l_cnt - 1); errors = errors + 1;
			end
			h_per = h_per + 1; h_cnt = 0; l_cnt = 1;
		end
	end

endmodule
