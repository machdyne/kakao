/*
 * k_uart -- a 16550, as much of one as the Kakao SOC needs so far:
 * 8N1 at a fixed rate, no modem lines. The host sees no FIFOs (it
 * finds an 8250 and sends a character at a time), but what comes in
 * waits in a queue of RXQ characters behind RBR: at this rate a
 * character takes a few hundred clock cycles, and a terminal sends a
 * key's three or four (ESC [ A) in one go.
 *
 * Byte registers, one per address (reg-shift 0, reg-io-width 1), so a
 * register's lane within the word is its address's low two bits:
 *
 *   0  RBR (read: the received character; reading takes it)
 *      THR (write: send a character)
 *   1  IER ([0] interrupt while a character waits, [1] while the
 *      transmitter is free and has not been told so)
 *   2  IIR (read: 0xc4 a character waits, 0xc2 the transmitter is free,
 *      0xc1 neither; reading it with the transmitter's reason takes
 *      that reason back, as writing THR does). FCR (write) is ignored.
 *   3  LCR (kept; [7] puts the divisor at 0 and 1, where it is kept
 *      and ignored: the rate is fixed)
 *   4  MCR (kept)
 *   5  LSR (read: bit 0 a character waits, bit 1 one was lost,
 *            bits 5 and 6 the transmitter is free)
 *   6  MSR (read: carrier, data set ready and clear to send)
 *   7  SCR (kept)
 *
 * lx with a request means it comes from a second set of registers in
 * front (the LiteX UART's): registers 0 as RBR and THR whatever LCR
 * says.
 *
 * With PIPE the port has no pins: what it sends and receives are bytes
 * on p_tx_* and p_rx_*, each with a valid and a ready, for the USB
 * console (the boards whose console is a USB CDC device on their USB-C
 * socket). Nothing sets the pace there but the other side, which may
 * not be there: a byte that has waited STALL cycles to be taken is
 * given up on, and what is sent is dropped until the other side takes
 * something again. So a machine with nobody listening waits once, ten
 * seconds, and then runs.
 *
 * For the terminal (k_iop.v) the port is tapped: tap goes with each
 * character taken for sending, hold makes the transmitter look busy
 * (the terminal's queue is full), and inj puts a character into the
 * receiver as if it had come from the pin.
 */

module k_uart #(
	parameter DIV = 48,			// clock cycles per bit: 48 MHz / 1 Mbaud
	parameter RXQ = 64,			// received characters that can wait (a power of two)
	parameter PIPE = 0,			// 1: bytes on p_tx_* and p_rx_*, no pins
	parameter [31:0] STALL = 32'd480_000_000
) (
	input         clk,
	input         rst,

	// one cycle: the register word at adr[2] is read or written in the
	// byte lanes sel
	input         req,
	input         we,
	input         adr2,			// address bit 2: registers 0..3 or 4..7
	input   [3:0] sel,
	input         lx,
	input  [31:0] wdat,
	output [31:0] rdat,			// (combinational: for the word at adr2)

	// its state, for a second set of registers in front of it
	output        st_rxv,		// a character waits
	output  [7:0] st_rxd,
	output        st_txbusy,

	output        irq,

	output        tap,			// one cycle: wdat[7:0] is being sent
	input         hold,
	input         inj,			// one cycle: inj_d was received
	input   [7:0] inj_d,

	input         rx,
	output reg    tx,

	output        p_tx_valid,
	output  [7:0] p_tx_data,
	input         p_tx_ready,
	input         p_rx_valid,
	input   [7:0] p_rx_data,
	output        p_rx_ready
);

	// -- transmit --
	reg  [9:0] t_sh;
	reg  [3:0] t_n;				// bit times left
	reg [15:0] t_c;
	// (PIPE: the byte that waits to be taken, and whether the other
	// side has been given up on)
	reg        p_v, p_gone;
	reg  [7:0] p_d;
	reg [31:0] p_c;
	wire       t_busy = (PIPE != 0) ? ((p_v && !p_gone) || hold) : ((t_n != 4'd0) || hold);
	assign p_tx_valid = p_v;
	assign p_tx_data  = p_d;

	// -- the registers that are only kept --
	reg  [3:0] ier;
	reg  [7:0] lcr, mcr, scr, dll, dlm;
	reg        thre_p;				// the transmitter is free, and that is news
	reg        t_busy_q;
	wire       dlab   = lcr[7] && !lx;
	wire       thr_wr = req && we && !adr2 && sel[0] && !dlab;
	assign tap = thr_wr && !t_busy;

	// -- receive --
	reg  [1:0] r_s;				// the pin, synchronised
	reg  [7:0] r_sh;
	reg  [3:0] r_n;				// 0 idle, 1 start, 2..9 data, 10 stop
	reg [15:0] r_c;
	reg        r_ovr;
	reg        r_new;			// one cycle: r_sh is a character
	// the queue: q_n of its RXQ places are taken, from q_rp on
	localparam QB = $clog2(RXQ);
	reg  [7:0] q [0:RXQ-1];
	reg [QB-1:0] q_wp, q_rp;
	reg [QB:0] q_n;
	wire       r_v    = (q_n != 0);
	wire [7:0] r_d    = q[q_rp];
	wire       q_full = q_n[QB];
	wire       q_pop  = req && !we && !adr2 && sel[0] && !dlab && r_v;
	// what is typed at the terminal goes first; a character off the
	// pin in the same cycle waits one (r_late)
	reg        r_late;
	wire       p_take = (PIPE != 0) && p_rx_valid && !q_full && !inj;
	assign p_rx_ready = !q_full && !inj;
	wire       q_push = inj || r_new || r_late || p_take;
	wire [7:0] q_in   = inj ? inj_d : (PIPE != 0) ? p_rx_data : r_sh;

	wire [7:0] lsr = { 1'b0, !t_busy, !t_busy, 3'b000, r_ovr, r_v };
	wire       i_rx   = ier[0] && r_v;
	wire       i_thre = ier[1] && thre_p;
	wire [7:0] iir    = i_rx ? 8'hc4 : i_thre ? 8'hc2 : 8'hc1;
	assign irq = i_rx || i_thre;
	assign st_rxv = r_v;
	assign st_rxd = r_d;
	assign st_txbusy = t_busy;
	assign rdat = adr2 ? { scr, 8'hb0, lsr, mcr } :
		{ lcr, iir, dlab ? dlm : { 4'd0, ier }, dlab ? dll : r_d };

	always @(posedge clk) begin
		r_s <= { r_s[0], rx };
		if (rst) begin
			tx <= 1'b1;
			t_n <= 4'd0;
			p_v <= 1'b0; p_gone <= 1'b0; p_c <= 32'd0;
			r_n <= 4'd0;
			r_ovr <= 1'b0;
			r_new <= 1'b0; r_late <= 1'b0;
			q_wp <= 0; q_rp <= 0; q_n <= 0;
			ier <= 4'd0; lcr <= 8'd3; mcr <= 8'd0; scr <= 8'd0; dll <= 8'd1; dlm <= 8'd0;
			thre_p <= 1'b0; t_busy_q <= 1'b0;
		end else begin
			// transmit: start, eight data bits, stop; or a byte for the pipe
			if (PIPE != 0) begin
				if (tap && !p_v) begin p_v <= 1'b1; p_d <= wdat[7:0]; p_c <= 32'd0; end
				if (p_v) begin
					if (p_tx_ready) begin p_v <= 1'b0; p_gone <= 1'b0; end
					else if (p_c == STALL) p_gone <= 1'b1;
					else p_c <= p_c + 32'd1;
				end
			end else if (t_n != 4'd0) begin
				if (t_c == 16'd0) begin
					t_c  <= DIV - 1;
					tx   <= t_sh[0];
					t_sh <= { 1'b1, t_sh[9:1] };
					t_n  <= t_n - 4'd1;
				end else begin
					t_c <= t_c - 16'd1;
				end
			end else begin
				tx <= 1'b1;
				if (tap) begin
					t_sh <= { 1'b1, wdat[7:0], 1'b0 };
					t_n  <= 4'd11;		// start, 8 data, stop, and the stop's length
					t_c  <= 16'd0;
				end
			end

			// receive: from the start bit's edge, sample each bit's middle
			r_new <= 1'b0;
			if (r_n == 4'd0) begin
				if (!r_s[1] && PIPE == 0) begin
					r_n <= 4'd1;
					r_c <= DIV / 2 - 1;
				end
			end else if (r_c == 16'd0) begin
				r_c <= DIV - 1;
				if (r_n == 4'd1) begin
					r_n <= r_s[1] ? 4'd0 : 4'd2;		// a glitch, not a start
				end else if (r_n == 4'd10) begin
					r_n <= 4'd0;
					if (r_s[1]) r_new <= 1'b1;
				end else begin
					r_sh <= { r_s[1], r_sh[7:1] };
					r_n  <= r_n + 4'd1;
				end
			end else begin
				r_c <= r_c - 16'd1;
			end

			// into the queue, and out of it: reading RBR takes the
			// character; reading LSR clears "lost"
			r_late <= inj && (r_new || r_late);
			if (q_push) begin
				if (q_full && !q_pop) r_ovr <= 1'b1;
				else begin
					q[q_wp] <= q_in;
					q_wp <= q_wp + 1'b1;
				end
			end
			if (q_pop) q_rp <= q_rp + 1'b1;
			q_n <= q_n + ((q_push && !(q_full && !q_pop)) ? 1'b1 : 1'b0) - (q_pop ? 1'b1 : 1'b0);

			// the kept registers, and the transmitter's interrupt
			t_busy_q <= t_busy;
			if (t_busy_q && !t_busy) thre_p <= 1'b1;
			if (req && !we && !adr2 && sel[2] && !i_rx) thre_p <= 1'b0;
			if (req && we && !lx) begin
				if (!adr2 && sel[0] && dlab) dll <= wdat[7:0];
				if (!adr2 && sel[1]) begin
					if (dlab) dlm <= wdat[15:8];
					else begin
						ier <= wdat[11:8];
						if (wdat[9] && !ier[1] && !t_busy) thre_p <= 1'b1;
					end
				end
				if (!adr2 && sel[3]) lcr <= wdat[31:24];
				if ( adr2 && sel[0]) mcr <= wdat[7:0];
				if ( adr2 && sel[3]) scr <= wdat[31:24];
			end
			if (thr_wr) thre_p <= 1'b0;
			if (req && !we &&  adr2 && sel[1]) r_ovr <= 1'b0;
		end
	end

endmodule
