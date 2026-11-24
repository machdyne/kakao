/*
 * k_vcon -- the consoles beyond the first: N more 16550s for the host,
 * of which only the registers exist. Nothing of them leaves on a pin:
 * what the host sends on one goes to the I/O processor (k_iop.v) with
 * the console's number, for that console's terminal, and what is typed
 * there comes back the same way. So there is no rate, no shift
 * register and no FIFO; a 16550's registers otherwise, as k_uart.v has
 * them (see there), one byte a register:
 *
 *   0  RBR / THR      1  IER      2  IIR      3  LCR (kept; with [7],
 *   4  MCR (kept)     5  LSR      6  MSR      7  SCR (kept)   0 and 1 read 1 and 0)
 *
 * Console p (1..N) is at 0x100 * p above console 0, the real UART.
 *
 * All the consoles' characters reach the I/O processor through here,
 * console 0's too (tap0: k_uart's tap), one a cycle: console 0's when
 * it has one, otherwise the next console's that waits. full stops
 * them all (and k_uart, which gets it as hold).
 */

module k_vcon #(
	parameter N = 3					// 1..9
) (
	input         clk,
	input         rst,

	// one cycle: console port's register word at adr2 is read or
	// written in the byte lanes sel
	input         req,
	input         we,
	input   [3:0] port,
	input         adr2,
	input   [3:0] sel,
	input  [31:0] wdat,
	output [31:0] rdat,				// (combinational)
	output  [9:1] irq,

	// console 0's character, as it is sent
	input         tap0,
	input   [7:0] tap0_d,

	// to the I/O processor's queue
	output        out_stb,
	output  [3:0] out_id,
	output  [7:0] out_d,
	input         full,

	// from the I/O processor: a character typed at console key_id
	input         key_stb,
	input   [3:0] key_id,
	input   [7:0] key_d,
	output  [9:1] key_busy			// that console has not taken its last one
);

	reg  [7:0] thr [1:N];
	reg  [7:0] rbr [1:N];
	reg  [7:0] lcr [1:N];
	reg  [7:0] scr [1:N];
	reg  [4:0] mcr [1:N];
	reg  [1:0] ier [1:N];
	reg  [N:1] thr_v, rbr_v, thre_p;

	wire       here = (port >= 4'd1) && (port <= N);
	wire [3:0] p    = here ? port : 4'd1;

	wire       dlab   = lcr[p][7];
	wire       i_rx   = ier[p][0] && rbr_v[p];
	wire       i_thre = ier[p][1] && thre_p[p];
	wire [7:0] iir    = i_rx ? 8'hc4 : i_thre ? 8'hc2 : 8'hc1;
	wire [7:0] lsr    = { 1'b0, !thr_v[p], !thr_v[p], 4'b0000, rbr_v[p] };
	assign rdat = !here ? 32'd0 :
		adr2 ? { scr[p], 8'hb0, lsr, 3'd0, mcr[p] } :
		{ lcr[p], iir, dlab ? 8'd0 : { 6'd0, ier[p] }, dlab ? 8'd1 : rbr[p] };

	genvar g;
	generate
		for (g = 1; g <= 9; g = g + 1) begin : per
			if (g <= N) begin : on
				assign irq[g] = (ier[g][0] && rbr_v[g]) || (ier[g][1] && thre_p[g]);
				assign key_busy[g] = rbr_v[g];
			end else begin : off
				assign irq[g] = 1'b0;
				assign key_busy[g] = 1'b0;
			end
		end
	endgenerate

	// the consoles take turns at the queue
	reg  [3:0] sp;
	wire       take = thr_v[sp] && !tap0 && !full;
	assign out_stb = tap0 || take;
	assign out_id  = tap0 ? 4'd0 : sp;
	assign out_d   = tap0 ? tap0_d : thr[sp];

	integer i;
	always @(posedge clk) begin
		if (rst) begin
			thr_v <= 0; rbr_v <= 0; thre_p <= 0;
			sp <= 4'd1;
			for (i = 1; i <= N; i = i + 1) begin
				ier[i] <= 2'd0; lcr[i] <= 8'd3; mcr[i] <= 5'd0; scr[i] <= 8'd0;
			end
		end else begin
			if (take) begin
				thr_v[sp] <= 1'b0;
				thre_p[sp] <= 1'b1;			// free again, and that is news
			end
			if (!thr_v[sp] || take) sp <= (sp == N) ? 4'd1 : sp + 4'd1;

			if (key_stb && key_id >= 4'd1 && key_id <= N) begin
				rbr[key_id] <= key_d;
				rbr_v[key_id] <= 1'b1;
			end

			if (req && here) begin
				if (!we) begin
					if (!adr2 && sel[0] && !dlab) rbr_v[p] <= 1'b0;
					if (!adr2 && sel[2] && !i_rx) thre_p[p] <= 1'b0;
				end else begin
					if (!adr2 && sel[0] && !dlab) begin
						thr[p] <= wdat[7:0];
						thr_v[p] <= 1'b1;
						thre_p[p] <= 1'b0;
					end
					if (!adr2 && sel[1] && !dlab) begin
						ier[p] <= wdat[9:8];
						if (wdat[9] && !ier[p][1] && !thr_v[p]) thre_p[p] <= 1'b1;
					end
					if (!adr2 && sel[3]) lcr[p] <= wdat[31:24];
					if ( adr2 && sel[0]) mcr[p] <= wdat[4:0];
					if ( adr2 && sel[3]) scr[p] <= wdat[31:24];
				end
			end
		end
	end

endmodule
