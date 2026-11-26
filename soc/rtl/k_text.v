/*
 * k_text -- the text mode: a screen of 80 columns by 30 rows of 8x16
 * characters in 16 colours, 640x480 at 60 Hz, chosen from TERMS screens
 * of cells; and an overlay over it. It belongs to the I/O processor
 * (k_iop.v), which sees this on its bus (clk; a request is stb,
 * answered by ack the next cycle):
 *
 *   0x00000 .. 0x1fffc   the cells, a word each: TERMS screens of 2400
 *                        (30 rows of 80, row after row), one after the
 *                        other. [7:0] the character, [11:8] its
 *                        colour, [15:12] the background's.
 *   0x20000  CTRL        [0] the screen is on (off: black, syncs go on)
 *                        [1] the cursor is shown   [2] and blinks
 *                        [3] it is a block (otherwise the two bottom lines)
 *                        [4] the overlay is shown
 *                        [5] ...and what is not under it is dimmed
 *   0x20004  CURSOR      the cell the cursor is on: its number
 *   0x20008  START       the cell at the top left of the picture
 *   0x2000c  STATUS      [0] vertical blanking, [15:8] frames counted,
 *                        [31:16] 0x7e88 (read only)
 *   0x20010  BASE        the first cell of the screen shown, and
 *   0x20014  END         the one after its last: the picture's rows go
 *                        on from START, 80 cells each, and from END
 *                        back to BASE
 *   0x20018  POINTER     [11:0] a cell of the picture (row * 80 + column)
 *                        shown with its two colours exchanged: the
 *                        mouse's pointer; [15] it is shown
 *   0x2001c  SELECT      the cells of the picture from [11:0] to [27:16]
 *                        are shown so too: what the mouse has selected;
 *                        [31] they are (a cell that is both shows as it
 *                        is, so the pointer is seen within a selection)
 *   0x20020  GRAPHICS    (with FB) [0] the framebuffer is shown where a
 *                        terminal would be: under the overlay, and
 *                        with no cursor, pointer or selection of ours
 *   0x20080 .. 0x200fc   the colours, a word each, 0x00rrggbb: sixteen
 *                        for the cells, then sixteen for the overlay
 *                        (write only; the PC's after reset)
 *   0x30000 .. 0x31f3c   the overlay's cells, as the cells are: the cell
 *                        at row r, column c of the picture is word
 *                        r*80 + c (write only). The overlay has the
 *                        picture's first 25 rows: two block RAMs.
 *
 * A screen's 30 rows are a ring: scrolling by a line is clearing the
 * row that comes into view and moving START on by 80 (and round), 80
 * stores, not 2400. Which screen is shown is BASE, END and START:
 * changing terminals copies nothing.
 *
 * The overlay is a second screen of cells over the first, for menus:
 * where its cell is 0 the screen underneath shows, anywhere else the
 * overlay's cell does, in the overlay's own colours. What is under it
 * goes on changing and scrolling as if it were not there.
 *
 * Colours are sixteen, and after reset the PC's: [0] blue, [1] green,
 * [2] red, [3] bright; 6 is brown.
 *
 * The font is 256 characters of 16 rows, a byte a row, the leftmost
 * pixel in bit 7, read from FONT_HEX (tools/mkfont.py makes it from
 * Zeitlos's 8x16 font).
 *
 * Two clocks: the cells are a dual-port memory, written on clk and
 * read on pclk. The registers are written on clk and taken over on
 * pclk at the start of vertical blanking, so a frame is drawn with
 * one set; they are few and change seldom, and a value caught in
 * the middle of changing lasts one frame.
 */

module k_text #(
	parameter TERMS    = 1,
	parameter FONT_HEX = "k_font.hex",
	parameter FB       = 0,			// 1: a framebuffer's picture (k_fb.v) can take a terminal's place
	parameter FB_SHOW  = 0			// ...and does so from reset (a simulation without a keyboard)
) (
	input         clk,
	input         rst,

	input  [17:0] adr_i,
	input  [31:0] dat_i,
	output reg [31:0] dat_o,
	input         we_i,
	input   [3:0] sel_i,
	input         stb_i,
	output reg    ack_o,

	input         pclk,
	output reg  [7:0] red,
	output reg  [7:0] green,
	output reg  [7:0] blue,
	output reg    hsync,			// low in the pulse, as 640x480 has them
	output reg    vsync,
	output reg    blank,
	output [10:0] hc,				// where the picture is, for whoever
	output [10:0] vc,				// needs it (not delayed as the pixels are)
	// the framebuffer (FB): whether it is shown (on clk), and its
	// pixel for the position hc, vc had two cycles ago
	output        fb_show,
	input  [23:0] fb_rgb
);

	localparam NCELL = TERMS * 2400;

	// ------------------------------------------------------------
	// the bus
	// ------------------------------------------------------------

	reg [15:0] cells [0:NCELL-1];
	reg [15:0] cell_a;
	reg [15:0] ovl [0:2047];
	reg [23:0] pal [0:31];

	reg  [5:0] ctrl;
	reg [14:0] cursor, start, base, wend;
	reg [15:0] pointer;
	reg [31:0] select;
	reg        gfx;					// the framebuffer is shown
	assign fb_show = (FB != 0) && gfx;

	wire s_cell = (adr_i[17] == 1'b0);
	wire s_reg  = (adr_i[17:16] == 2'b10) && !adr_i[7] && !adr_i[5];
	wire s_gfx  = (adr_i[17:16] == 2'b10) && !adr_i[7] && adr_i[5];
	wire s_pal  = (adr_i[17:16] == 2'b10) && adr_i[7];
	wire s_ovl  = (adr_i[17:16] == 2'b11);
	wire req    = stb_i && !ack_o;

	// the PC's colours: [0] blue, [1] green, [2] red, [3] bright; 6 brown
	function [23:0] pc_colour(input [3:0] c);
		reg [7:0] lo;
		begin
			lo = c[3] ? 8'h55 : 8'h00;
			pc_colour = { (c[2] ? 8'haa : 8'h00) | lo,
				(c == 4'd6) ? 8'h55 : ((c[1] ? 8'haa : 8'h00) | lo),
				(c[0] ? 8'haa : 8'h00) | lo };
		end
	endfunction
	integer pi;
	initial for (pi = 0; pi < 32; pi = pi + 1) pal[pi] = pc_colour(pi[3:0]);

	// status, from the other side
	reg        vbl_p;
	reg  [7:0] frames_p;
	reg  [1:0] vbl_s;
	reg  [7:0] frames_s0, frames_s1;

	always @(posedge clk) begin
		if (req && we_i && s_cell && sel_i[0]) cells[adr_i[16:2]][7:0]  <= dat_i[7:0];
		if (req && we_i && s_cell && sel_i[1]) cells[adr_i[16:2]][15:8] <= dat_i[15:8];
		cell_a <= cells[adr_i[16:2]];
	end

	always @(posedge clk) begin
		if (req && we_i && s_ovl && sel_i[0]) ovl[adr_i[12:2]][7:0]  <= dat_i[7:0];
		if (req && we_i && s_ovl && sel_i[1]) ovl[adr_i[12:2]][15:8] <= dat_i[15:8];
		if (req && we_i && s_pal) pal[adr_i[6:2]] <= dat_i[23:0];
	end

	reg        rd_cell;
	reg [31:0] rd_reg;
	always @(*) dat_o = rd_cell ? { 16'd0, cell_a } : rd_reg;

	always @(posedge clk) begin
		ack_o <= req;
		rd_cell <= s_cell;
		vbl_s <= { vbl_s[0], vbl_p };
		frames_s0 <= frames_p; frames_s1 <= frames_s0;
		case (adr_i[4:2])
			3'd0: rd_reg <= { 26'd0, ctrl };
			3'd1: rd_reg <= { 17'd0, cursor };
			3'd2: rd_reg <= { 17'd0, start };
			3'd3: rd_reg <= { 16'h7e88, frames_s1, 7'd0, vbl_s[1] };
			3'd4: rd_reg <= { 17'd0, base };
			3'd5: rd_reg <= { 17'd0, wend };
			3'd6: rd_reg <= { 16'd0, pointer };
			3'd7: rd_reg <= select;
		endcase
		if (s_gfx) rd_reg <= { 31'd0, fb_show };
		if (rst)
			gfx <= (FB_SHOW != 0);
		else if (req && we_i && s_gfx && sel_i[0])
			gfx <= dat_i[0];
		if (rst) begin
			ctrl <= 6'b000000;
			cursor <= 15'd0;
			start <= 15'd0;
			base <= 15'd0;
			wend <= 15'd2400;
			pointer <= 16'd0;
			select <= 32'd0;
		end else if (req && we_i && s_reg && sel_i[0]) begin
			case (adr_i[4:2])
				3'd0: ctrl <= dat_i[5:0];
				3'd1: cursor <= dat_i[14:0];
				3'd2: start <= dat_i[14:0];
				3'd4: base <= dat_i[14:0];
				3'd5: wend <= dat_i[14:0];
				3'd6: pointer <= dat_i[15:0];
				3'd7: select <= dat_i;
				default: ;
			endcase
		end
	end

	// ------------------------------------------------------------
	// the picture
	// ------------------------------------------------------------

	// 640x480 at 60 Hz: 800 by 525 in all
	localparam H_VIS = 640, H_FP = 16, H_SYN = 96, H_TOT = 800;
	localparam V_VIS = 480, V_FP = 10, V_SYN = 2,  V_TOT = 525;

	reg [10:0] h = 0, v = 0;
	assign hc = h;
	assign vc = v;

	// the registers, as this frame has them
	reg  [5:0] ctrl_m, ctrl_p;
	reg [14:0] cursor_m, cursor_p, start_m, start_p, base_m, base_p, wend_m, wend_p;
	reg  [5:0] blink;
	reg [15:0] pointer_m, pointer_p;
	reg        gfx_m, gfx_p;
	reg [31:0] select_m, select_p;

	// where the row of cells being drawn begins, in the screen and in
	// the overlay: on by 80 after each sixteen lines
	reg [14:0] row_a;
	reg [11:0] orow_a;
	wire [14:0] row_n = row_a + 15'd80;

	always @(posedge pclk) begin
		if (h == H_TOT - 1) begin
			h <= 0;
			v <= (v == V_TOT - 1) ? 11'd0 : v + 11'd1;
			if (v == V_TOT - 1) begin
				row_a <= start_p;
				orow_a <= 12'd0;
			end else if (v < V_VIS && v[3:0] == 4'd15) begin
				row_a <= (row_n == wend_p) ? base_p : row_n;
				orow_a <= orow_a + 12'd80;
			end
		end else
			h <= h + 11'd1;

		ctrl_m <= ctrl; cursor_m <= cursor; start_m <= start; base_m <= base; wend_m <= wend;
		pointer_m <= pointer; select_m <= select;
		gfx_m <= fb_show;
		if (h == 0 && v == V_VIS) begin
			pointer_p <= pointer_m; select_p <= select_m;
			gfx_p <= gfx_m;
			ctrl_p <= ctrl_m; cursor_p <= cursor_m; start_p <= start_m;
			base_p <= base_m; wend_p <= wend_m;
			frames_p <= frames_p + 8'd1;
			blink <= blink + 6'd1;
		end
		vbl_p <= (v >= V_VIS);
	end

	// three steps from a position to its pixel: the cell, the row of
	// its character, the pixel
	reg  [7:0] font [0:4095];
	initial $readmemh(FONT_HEX, font);

	wire [14:0] c_adr = row_a + { 8'd0, h[9:3] };
	wire [11:0] o_adr = orow_a + { 5'd0, h[9:3] };

	reg [15:0] cell_q, ovl_q;
	reg        ovl_in;				// the position is within the overlay's rows
	reg  [7:0] font_q;
	reg [14:0] c_adr1, c_adr2;
	reg  [7:0] attr2;
	reg        o2;
	reg [11:0] pos1;				// the cell's place in the picture
	reg        inv2;				// its colours are exchanged: the pointer, the selection
	reg  [2:0] px1, px2;
	reg  [3:0] ln1, ln2;
	reg        vis0, vis1, hs0, hs1, vs0, vs1;

	// the overlay's cell where it has one; under a dimming overlay the
	// screen's own cells are dark grey on black
	wire        o1  = ctrl_p[4] && ovl_in && (ovl_q != 16'd0);
	wire [15:0] sel1 = o1 ? ovl_q : ctrl_p[5] && ctrl_p[4] ? { 8'h08, cell_q[7:0] } : cell_q;

	wire cur_on  = ctrl_p[1] && (!ctrl_p[2] || blink[4]) && !o2 &&
		(c_adr2 == cursor_p) && (ctrl_p[3] || ln2 >= 4'd14);
	wire dot     = font_q[3'd7 - px2] ^ cur_on ^ inv2;
	wire [3:0] col = dot ? attr2[3:0] : attr2[7:4];
	wire [23:0] rgb = pal[{ o2, col }];
	wire [23:0] out = (gfx_p && !o2) ? fb_rgb : rgb;

	always @(posedge pclk) begin
		// 0: where we are
		vis0 <= (h < H_VIS) && (v < V_VIS);
		hs0  <= !(h >= H_VIS + H_FP && h < H_VIS + H_FP + H_SYN);
		vs0  <= !(v >= V_VIS + V_FP && v < V_VIS + V_FP + V_SYN);
		cell_q <= cells[c_adr];
		ovl_q  <= ovl[o_adr[10:0]];
		ovl_in <= (o_adr < 12'd2000);
		c_adr1 <= c_adr; px1 <= h[2:0]; ln1 <= v[3:0];
		pos1 <= o_adr;

		// 1: the cells are here: one of them
		font_q <= font[{ sel1[7:0], ln1 }];
		attr2 <= sel1[15:8];
		o2 <= o1;
		inv2 <= !o1 && ((pointer_p[15] && pos1 == pointer_p[11:0]) ^
			(select_p[31] && pos1 >= select_p[11:0] && pos1 <= select_p[27:16]));
		c_adr2 <= c_adr1; px2 <= px1; ln2 <= ln1;
		vis1 <= vis0; hs1 <= hs0; vs1 <= vs0;

		// 2: the row of the character is here
		// (the framebuffer's pixel where the overlay has no cell)
		red   <= (vis1 && ctrl_p[0]) ? out[23:16] : 8'd0;
		green <= (vis1 && ctrl_p[0]) ? out[15:8] : 8'd0;
		blue  <= (vis1 && ctrl_p[0]) ? out[7:0] : 8'd0;
		blank <= !vis1;
		hsync <= hs1;
		vsync <= vs1;
	end

endmodule
