/*
 * k_clint -- the core-local interruptor, as SiFive's CLINT and QEMU's
 * virt machine lay it out, for one hart:
 *
 *   0x0000  msip      bit 0: the machine software interrupt
 *   0x4000  mtimecmp  64 bits: the machine timer interrupt is raised
 *                     while mtime >= mtimecmp
 *   0xbff8  mtime     64 bits, counting TICK-th clock cycles
 */

module k_clint #(
	parameter TICK = 1,			// clock cycles per mtime count
	// 1: a read of mtime's lower word keeps the upper word of that
	// moment for the read of it that follows (a 64 bit CPU whose
	// doubleword loads arrive as two)
	parameter HOLD_HI = 0
) (
	input         clk,
	input         rst,

	input         req,
	input         we,
	input  [15:2] adr,
	input  [31:0] wdat,
	output [31:0] rdat,			// (combinational)

	output reg [63:0] mtime,
	output        irq_msi,
	output reg    irq_mti
);

	reg [63:0] mtimecmp;
	reg        msip;
	reg [15:0] div;
	reg [31:0] hi_q;

	assign irq_msi = msip;
	assign rdat =
		(adr == 14'h0000) ? { 31'd0, msip } :
		(adr == 14'h1000) ? mtimecmp[31:0] :
		(adr == 14'h1001) ? mtimecmp[63:32] :
		(adr == 14'h2ffe) ? mtime[31:0] :
		(adr == 14'h2fff) ? ((HOLD_HI != 0) ? hi_q : mtime[63:32]) : 32'd0;

	always @(posedge clk) begin
		irq_mti <= (mtime >= mtimecmp);
		if (rst) begin
			mtime <= 64'd0;
			mtimecmp <= 64'hffff_ffff_ffff_ffff;
			msip <= 1'b0;
			div <= 16'd0;
		end else begin
			if (div == TICK - 1) begin
				div <= 16'd0;
				mtime <= mtime + 64'd1;
			end else begin
				div <= div + 16'd1;
			end
			if (req && !we && adr == 14'h2ffe) hi_q <= mtime[63:32];
			if (req && we) begin
				if (adr == 14'h0000) msip <= wdat[0];
				if (adr == 14'h1000) mtimecmp[31:0]  <= wdat;
				if (adr == 14'h1001) mtimecmp[63:32] <= wdat;
				if (adr == 14'h2ffe) mtime[31:0]  <= wdat;
				if (adr == 14'h2fff) mtime[63:32] <= wdat;
			end
		end
	end

endmodule
