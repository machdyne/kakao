/*
 * kakao64_bare -- the kakao64 CPU by itself, for the FPGA tools to say
 * how big it is and how fast: not a machine. Its inputs come from a
 * shift register and its outputs go into one, so that the core's ports
 * are registers on both sides, nothing of it is optimised away, and
 * three pins are enough.
 *
 *   make BOARD=sergei_ml2 kakao64-bare
 */

module kakao64_bare #(
	parameter FAST_MUL = 0,
	parameter BTFN     = 0,
	parameter BTB_BITS = 6
) (
	input  clk,
	input  si,
	output so
);

	reg [3:0] rst_c = 4'd0;
	wire rst = !rst_c[3];
	always @(posedge clk) if (rst) rst_c <= rst_c + 4'd1;

	// in: m_rdy, m_ack, m_rdat, mtime, four interrupt lines
	reg [133:0] in;
	always @(posedge clk) in <= { in[132:0], si };

	wire        m_req, m_we, m_instr, fencei;
	wire [31:0] m_adr;
	wire  [7:0] m_sel;
	wire [63:0] m_wdat;

	kakao64 #(
		.FAST_MUL(FAST_MUL), .BTFN(BTFN), .BTB_BITS(BTB_BITS)
	) cpu (
		.clk(clk), .rst(rst),
		.m_req(m_req), .m_adr(m_adr), .m_dbl(), .m_we(m_we), .m_sel(m_sel),
		.m_wdat(m_wdat), .m_instr(m_instr),
		.m_rdy(in[0]), .m_ack(in[1]), .m_rdat(in[65:2]),
		.fencei(fencei),
		.mtime(in[129:66]),
		.irq_msi(in[130]), .irq_mti(in[131]), .irq_mei(in[132]), .irq_sei(in[133])
	);

	// out: loaded from the port every cycle but one in 128, shifted then
	reg [107:0] out;
	reg   [6:0] oc = 7'd0;
	always @(posedge clk) begin
		oc <= oc + 7'd1;
		if (oc == 7'd0) out <= { fencei, m_instr, m_we, m_req, m_sel, m_adr, m_wdat };
		else out <= { out[106:0], out[107] ^ (^{ fencei, m_instr, m_we, m_req, m_sel, m_adr, m_wdat }) };
	end
	assign so = out[107];

endmodule
