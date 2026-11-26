/*
 * k_fb -- the framebuffer's scan-out: the picture a host draws in main
 * memory, read out of it as the text mode (k_text.v) draws the screen,
 * for k_text to show under its overlay in place of a terminal.
 *
 * The framebuffer is W by H pixels, row after row from the top, at
 * BASE in main memory (a block's number: memory is read 16 bytes, one
 * DDR3 burst, at a time). A pixel is 16 bits, r5g6b5 (red the top five
 * bits of a little-endian word: Linux's "r5g6b5", Plan 9's RGB16), or
 * with `deep8` 8 bits, a colour of the 256 in the palette here.
 *
 * Two clocks. On clk the blocks are fetched, in order, through
 *
 *   m_stb, m_adr      a block is asked for (held until m_ack)
 *   m_ack, m_dat      one cycle: its 128 bits, the lowest address in
 *                     the lowest bits
 *
 * into a queue of eight blocks; on pclk they are taken out of it and
 * shifted out a pixel at a time, where k_text's counters (hc, vc: 640
 * by 480 visible of 800 by 525) say a pixel is visible. rgb is the
 * colour of the pixel at (hc, vc) two cycles later, which is when
 * k_text chooses between it and its own.
 *
 * Whoever answers m_stb has to answer it first: eight pixels of 16
 * bits last fifteen cycles of a 48 MHz clk, a block takes ten to
 * fetch, and the queue is what absorbs an access of the CPU's or a
 * refresh that was under way. If the queue runs dry all the same, the
 * last block is shown again and the rest of that frame is out of step;
 * the next frame starts afresh, both sides from nothing, at the
 * beginning of vertical blanking (the pixel side says so across the
 * clocks, and nothing is read for the forty-five lines after it).
 *
 * `show` is off: nothing is fetched, and rgb is black. Memory is then
 * the CPU's alone, which is the point of asking: a terminal on the
 * screen costs a host nothing.
 *
 * The palette is written on clk (pal_we, pal_a, pal_d: 0x00rrggbb) and
 * read on pclk; a colour changed while it is on the screen may show
 * wrongly for a pixel.
 */

module k_fb #(
	parameter [24:0] BASE = 25'd0,	// the framebuffer's first block
	parameter W = 640,
	parameter H = 480,
	parameter H_TOT = 800,
	parameter V_TOT = 525
) (
	input          clk,
	input          rst,
	input          show,			// (clk) the framebuffer is on the screen
	input          deep8,			// (clk) 8 bits a pixel, through the palette

	output reg         m_stb,
	output reg  [24:0] m_adr,
	input              m_ack,
	input      [127:0] m_dat,

	input          pal_we,
	input    [7:0] pal_a,
	input   [23:0] pal_d,

	input          pclk,
	input   [10:0] hc,
	input   [10:0] vc,
	output reg [23:0] rgb,
	output reg [15:0] underruns		// (pclk) blocks that were not there in time
);

	// ------------------------------------------------------------
	// the queue: eight blocks, written on clk and read on pclk
	// ------------------------------------------------------------

	reg [127:0] q [0:7];
	reg   [3:0] wp, wp_g;			// clk: the next to write, and as a Gray code
	reg   [3:0] rp, rp_g;			// pclk: the next to read
	reg   [3:0] rp_s0, rp_s1;		// rp_g on clk
	reg   [3:0] wp_s0, wp_s1;		// wp_g on pclk

	function [3:0] gray(input [3:0] b);
		gray = b ^ (b >> 1);
	endfunction

	wire [3:0] wp_n  = wp + 4'd1;
	wire       full  = (wp_g == { ~rp_s1[3:2], rp_s1[1:0] });
	wire       empty = (rp_g == wp_s1);

	// ------------------------------------------------------------
	// clk: the fetching
	// ------------------------------------------------------------

	// blocks in a frame
	localparam [24:0] N16 = (W * H) / 8;
	localparam [24:0] N8  = (W * H) / 16;

	reg        ft_p;				// pclk: turned over at the start of each frame
	reg  [2:0] ft_s;				// ...and here
	reg [24:0] left;				// blocks of this frame still to fetch
	reg  [4:0] hold;				// after a frame's start: nothing, while the queue empties
	reg        drop;				// the block on its way is the last frame's
	reg        show_s, deep_s;

	always @(posedge clk) begin
		rp_s0 <= rp_g; rp_s1 <= rp_s0;
		ft_s <= { ft_s[1:0], ft_p };
		if (rst) begin
			m_stb <= 1'b0;
			wp <= 4'd0; wp_g <= 4'd0;
			left <= 25'd0;
			hold <= 5'd0;
			drop <= 1'b0;
			show_s <= 1'b0; deep_s <= 1'b0;
		end else begin
			if (hold != 5'd0) hold <= hold - 5'd1;

			if (m_stb && m_ack) begin
				m_stb <= 1'b0;
				drop <= 1'b0;
				if (!drop) begin
					q[wp[2:0]] <= m_dat;
					wp <= wp_n; wp_g <= gray(wp_n);
					m_adr <= m_adr + 25'd1;
					left <= left - 25'd1;
				end
			end else if (!m_stb && hold == 5'd0 && left != 25'd0 && !full)
				m_stb <= 1'b1;

			// a frame begins: from the framebuffer's first block again,
			// with the queue empty (the pixel side has emptied its end);
			// what the frame is, is settled here for all of it
			if (ft_s[2] != ft_s[1]) begin
				if (m_stb && !m_ack) drop <= 1'b1;
				wp <= 4'd0; wp_g <= 4'd0;
				m_adr <= BASE;
				show_s <= show; deep_s <= deep8;
				left <= !show ? 25'd0 : deep8 ? N8 : N16;
				hold <= 5'd16;
			end
		end
	end

	// ------------------------------------------------------------
	// the palette
	// ------------------------------------------------------------

	reg [23:0] pal [0:255];
	always @(posedge clk) if (pal_we) pal[pal_a] <= pal_d;

	// ------------------------------------------------------------
	// pclk: the pixels
	// ------------------------------------------------------------

	reg [127:0] cur, nxt;			// the block being shown, and the one after it
	reg         cur_v, nxt_v;
	reg   [3:0] idx;				// the pixel of cur that is next
	reg         show_p0, show_p, deep_p0, deep_p;
	reg  [15:0] pix;
	reg         pix_v;

	wire        vis   = (hc < W) && (vc < H);
	wire        fs    = (hc == 11'd0) && (vc == H);
	wire  [3:0] last  = deep_p ? 4'd15 : 4'd7;
	wire [15:0] pix16 = cur[{ idx[2:0], 4'b0000 } +: 16];
	wire  [7:0] pix8  = cur[{ idx, 3'b000 } +: 8];
	wire [23:0] pal_q = pal[pix[7:0]];

	always @(posedge pclk) begin
		wp_s0 <= wp_g; wp_s1 <= wp_s0;
		show_p0 <= show_s; deep_p0 <= deep_s;

		if (fs) begin
			// the frame is over: both ends of the queue start again
			ft_p <= !ft_p;
			rp <= 4'd0; rp_g <= 4'd0;
			cur_v <= 1'b0; nxt_v <= 1'b0;
			idx <= 4'd0;
			show_p <= show_p0; deep_p <= deep_p0;
		end else begin
			// the block after this one, as soon as there is one
			if (!nxt_v && !empty && !(vis && idx == last)) begin
				nxt <= q[rp[2:0]];
				nxt_v <= 1'b1;
				rp <= rp + 4'd1; rp_g <= gray(rp + 4'd1);
			end
			if (!cur_v && nxt_v && !vis) begin
				cur <= nxt; cur_v <= 1'b1; nxt_v <= 1'b0;
			end
			if (vis) begin
				if (idx == last) begin
					idx <= 4'd0;
					if (nxt_v) begin cur <= nxt; nxt_v <= 1'b0; end
					else if (show_p) underruns <= underruns + 16'd1;
				end else
					idx <= idx + 4'd1;
			end
		end

		// one: the pixel's bits; two: its colour
		pix   <= deep_p ? { 8'd0, pix8 } : pix16;
		pix_v <= vis && show_p && cur_v;
		rgb   <= !pix_v ? 24'd0 :
			deep_p ? pal_q :
			{ pix[15:11], pix[15:13], pix[10:5], pix[10:9], pix[4:0], pix[4:2] };

	end

	initial begin
		ft_p = 1'b0; ft_s = 3'd0;
		rp = 4'd0; rp_g = 4'd0;
		cur_v = 1'b0; nxt_v = 1'b0; idx = 4'd0;
		underruns = 16'd0;
	end

endmodule
