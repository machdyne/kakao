/*
 * k_virtio -- the virtio-mmio slots: N devices' register pages for the
 * host, of which nearly nothing is here. The devices are the I/O
 * processor's programs (fw/iop: the SD card as a disk, the network),
 * and so are their registers: a register the host reads or writes is
 * held here as a request, the host waits, and the I/O processor
 * answers it. That is slow, tens of microseconds, and happens when a
 * driver starts.
 *
 * What a driver does all the time is answered here at once:
 *
 *   0x050  QueueNotify (write)      the queue's bit is set for the I/O
 *                                   processor to find
 *   0x060  InterruptStatus (read)   what the device has raised: bit 0
 *                                   the used ring, bit 1 the configuration
 *   0x064  InterruptACK (write)     takes those bits back
 *
 * A slot's interrupt is up while it has a bit raised.
 *
 * The host's side: h_stb with the slot, the register's word address,
 * the byte lanes and the data, held until h_ack (one cycle, with
 * h_rdat for a read). While the I/O processor has a request to answer
 * (h_hold), the host's bus may take h_stb away and bring the same
 * access again later (k_cache.v does, to let the I/O processor into
 * main memory): the request and its answer are kept for it.
 *
 * The I/O processor's side, registers a word each (i_req for one
 * cycle; a read's answer is there the cycle after):
 *
 *   0  REQ     read: [31] a request waits, [30] it is a write,
 *              [23:20] its byte lanes, [19:16] the slot (0..N-1),
 *              [11:0] the register (a multiple of four)
 *   1  WDAT    read: what the host writes
 *   2  RSP     write: the answer (what the host reads; anything for a
 *              write), and the host goes on
 *   3  NOTIFY  read: the queues notified, four bits a slot (queues
 *              0..3); write: the bits written as ones are taken back
 *   4  IRQ     write: raise interrupt bits, two bits a slot
 */

module k_virtio #(
	parameter N = 4					// slots, 1..8
) (
	input         clk,
	input         rst,

	input         h_stb,
	input         h_we,
	input   [2:0] h_slot,
	input   [9:0] h_adr,			// the register's word address
	input   [3:0] h_sel,
	input  [31:0] h_wdat,
	output reg    h_ack,
	output reg [31:0] h_rdat,
	output        h_hold,
	output [N-1:0] irq,

	input         i_req,
	input         i_we,
	input   [2:0] i_adr,
	input  [31:0] i_wdat,
	output reg [31:0] i_rdat
);

	reg  [2*N-1:0] isr;
	reg  [4*N-1:0] ntf;
	reg            pend;			// the host waits for the I/O processor
	reg            ans;				// ...which has answered, and the host is to be told
	// the request, kept (the host's bus may be elsewhere meanwhile)
	reg            q_we;
	reg      [2:0] q_slot;
	reg      [9:0] q_adr;
	reg      [3:0] q_sel;
	reg     [31:0] q_wdat;
	assign h_hold = pend;
	reg            done;			// the request in hand has been answered or passed on

	wire h_here = (h_slot < N);
	wire h_isr  = (h_adr == 10'h018);		// 0x060
	wire h_iack = (h_adr == 10'h019);		// 0x064
	wire h_ntf  = (h_adr == 10'h014);		// 0x050
	wire fast   = !h_here || (h_isr && !h_we) || (h_iack && h_we) || (h_ntf && h_we);

	genvar g;
	generate
		for (g = 0; g < N; g = g + 1) begin : per
			assign irq[g] = |isr[2*g +: 2];
		end
	endgenerate

`ifndef SYNTHESIS_ONLY
`ifdef K_VIRTIO_LOG
	always @(posedge clk) begin
		if (h_ack) $display("[virtio %0d] %s %03x: %08x  (isr %b ntf %b)", h_slot, h_we ? "write" : "read ", { h_adr, 2'b00 },
			h_we ? h_wdat : h_rdat, isr, ntf);
		if (i_req && i_we && i_adr == 3'd4) $display("[virtio] irq %b", i_wdat[2*N-1:0]);
	end
`endif
`endif

	integer k;
	always @(posedge clk) begin
		h_ack <= 1'b0;
		case (i_adr)
			3'd0: i_rdat <= { pend, q_we, 6'd0, q_sel, 1'b0, q_slot, 4'd0, q_adr, 2'b00 };
			3'd1: i_rdat <= q_wdat;
			3'd3: i_rdat <= ntf;
			default: i_rdat <= 32'd0;
		endcase

		if (rst) begin
			isr <= 0; ntf <= 0;
			pend <= 1'b0; done <= 1'b0; ans <= 1'b0;
		end else begin
			// the I/O processor's writes first: what the host does in the
			// same cycle (below) is not lost to them
			if (i_req && i_we && i_adr == 3'd3) ntf <= ntf & ~i_wdat[4*N-1:0];
			if (i_req && i_we && i_adr == 3'd4) isr <= isr | i_wdat[2*N-1:0];

			if (!h_stb) done <= 1'b0;
			if (h_stb && !done && !pend && !ans) begin
				if (fast) begin
					done  <= 1'b1;
					h_ack <= 1'b1;
					h_rdat <= (h_here && h_isr) ? { 30'd0, isr[2*h_slot +: 2] } : 32'd0;
					if (h_here && h_iack && h_sel[0]) begin
						for (k = 0; k < 2; k = k + 1)
							if (h_wdat[k] && !(i_req && i_we && i_adr == 3'd4 && i_wdat[2*h_slot + k]))
								isr[2*h_slot + k] <= 1'b0;
					end
					if (h_here && h_ntf && h_sel[0]) ntf[4*h_slot + h_wdat[1:0]] <= 1'b1;
				end else begin
					pend <= 1'b1;
					q_we <= h_we; q_slot <= h_slot; q_adr <= h_adr; q_sel <= h_sel; q_wdat <= h_wdat;
				end
			end
			if (pend && i_req && i_we && i_adr == 3'd2) begin
				pend  <= 1'b0;
				ans   <= 1'b1;
				h_rdat <= i_wdat;
			end
			if (ans && h_stb) begin
				ans   <= 1'b0;
				done  <= 1'b1;
				h_ack <= 1'b1;
			end
		end
	end

endmodule
