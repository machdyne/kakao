/*
 * tb_k_vcon -- k_vcon's registers as the 8250 driver uses them: a
 * character sent on each console reaches the queue with its number,
 * console 0's has the way first, full stops them; a character typed
 * raises the console's interrupt and is read once; the transmitter's
 * interrupt comes when it is free, goes when IIR is read, and comes
 * again when it is asked for again.
 */

`timescale 1ns/1ps

module tb_k_vcon;

	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	reg         req = 0, we = 0, adr2 = 0;
	reg   [3:0] port = 0, sel = 0;
	reg  [31:0] wdat = 0;
	wire [31:0] rdat;
	wire  [9:1] irq, key_busy;
	reg         tap0 = 0, full = 0, key_stb = 0;
	reg   [7:0] tap0_d = 0, key_d = 0;
	reg   [3:0] key_id = 0;
	wire        out_stb;
	wire  [3:0] out_id;
	wire  [7:0] out_d;

	k_vcon #(.N(3)) dut (
		.clk(clk), .rst(rst),
		.req(req), .we(we), .port(port), .adr2(adr2), .sel(sel), .wdat(wdat), .rdat(rdat), .irq(irq),
		.tap0(tap0), .tap0_d(tap0_d),
		.out_stb(out_stb), .out_id(out_id), .out_d(out_d), .full(full),
		.key_stb(key_stb), .key_id(key_id), .key_d(key_d), .key_busy(key_busy)
	);

	integer errors = 0;
	reg [7:0] v;

	// a register of a console, a byte: as the CPU's byte accesses are
	task wr(input [3:0] p, input [2:0] r, input [7:0] d);
		begin
			@(negedge clk); req = 1; we = 1; port = p; adr2 = r[2]; sel = 4'b0001 << r[1:0];
			wdat = { 4{d} };
			@(negedge clk); req = 0; we = 0;
		end
	endtask
	task rd(input [3:0] p, input [2:0] r, output [7:0] d);
		begin
			@(negedge clk); req = 1; we = 0; port = p; adr2 = r[2]; sel = 4'b0001 << r[1:0];
			#1 d = rdat[8 * r[1:0] +: 8];
			@(negedge clk); req = 0;
		end
	endtask
	task want(input [8*24-1:0] what, input [7:0] got, input [7:0] should);
		if (got !== should) begin
			$display("FAIL: %0s is %02x, should be %02x", what, got, should);
			errors = errors + 1;
		end
	endtask

	// what comes out for the queue
	reg [11:0] outq [0:15];
	integer n_out = 0;
	always @(posedge clk) if (out_stb) begin outq[n_out] = { out_id, out_d }; n_out = n_out + 1; end

	initial begin
		repeat (3) @(negedge clk);
		rst = 0;

		// nothing there: the transmitter free, nothing received, no interrupt
		rd(2, 5, v); want("LSR at rest", v, 8'h60);
		rd(2, 2, v); want("IIR at rest", v, 8'hc1);
		rd(5, 5, v); want("LSR of no console", v, 8'h00);

		// a character out, on console 2 and on console 3, and console 0's
		// in the same cycle as one waits
		wr(2, 0, "x");
		wr(3, 0, "y");
		@(negedge clk); tap0 = 1; tap0_d = "z"; @(negedge clk); tap0 = 0;
		repeat (8) @(negedge clk);
		if (n_out != 3) begin $display("FAIL: %0d characters out, should be 3", n_out); errors = errors + 1; end
		if (!(outq[0] === { 4'd2, "x" } || outq[1] === { 4'd2, "x" } || outq[2] === { 4'd2, "x" }) ||
		    !(outq[0] === { 4'd3, "y" } || outq[1] === { 4'd3, "y" } || outq[2] === { 4'd3, "y" }) ||
		    !(outq[0] === { 4'd0, "z" } || outq[1] === { 4'd0, "z" } || outq[2] === { 4'd0, "z" })) begin
			$display("FAIL: out came %03x %03x %03x", outq[0], outq[1], outq[2]); errors = errors + 1;
		end

		// the queue full: the character waits, the transmitter is busy
		full = 1;
		wr(1, 0, "w");
		repeat (6) @(negedge clk);
		rd(1, 5, v); want("LSR, queue full", v, 8'h00);
		if (n_out != 3) begin $display("FAIL: a character went into a full queue"); errors = errors + 1; end
		full = 0;
		repeat (6) @(negedge clk);
		rd(1, 5, v); want("LSR, queue free", v, 8'h60);
		if (n_out != 4 || outq[3] !== { 4'd1, "w" }) begin $display("FAIL: the waiting character did not go"); errors = errors + 1; end

		// the transmitter's interrupt: asked for while free, it comes; IIR
		// read, it goes; asked again, it comes again (the driver's test)
		wr(1, 1, 8'h02);
		if (irq !== 9'b000000001) begin $display("FAIL: no THRE interrupt (%b)", irq); errors = errors + 1; end
		rd(1, 2, v); want("IIR, THRE", v, 8'hc2);
		rd(1, 2, v); want("IIR, THRE read", v, 8'hc1);
		wr(1, 1, 8'h00);
		wr(1, 1, 8'h02);
		rd(1, 2, v); want("IIR, THRE again", v, 8'hc2);
		// ...and after a character has gone
		wr(1, 0, "v");
		repeat (6) @(negedge clk);
		rd(1, 2, v); want("IIR, sent", v, 8'hc2);
		wr(1, 1, 8'h01);

		// a character typed at console 1: its interrupt, read once
		@(negedge clk); key_stb = 1; key_id = 1; key_d = "k"; @(negedge clk); key_stb = 0;
		if (key_busy !== 9'b000000001) begin $display("FAIL: key_busy %b", key_busy); errors = errors + 1; end
		if (irq !== 9'b000000001) begin $display("FAIL: no receive interrupt (%b)", irq); errors = errors + 1; end
		rd(1, 2, v); want("IIR, received", v, 8'hc4);
		rd(1, 5, v); want("LSR, received", v, 8'h61);
		rd(1, 5, v); want("LSR, still", v, 8'h61);
		rd(1, 0, v); want("RBR", v, "k");
		rd(1, 5, v); want("LSR, taken", v, 8'h60);
		if (irq !== 9'd0 || key_busy !== 9'd0) begin $display("FAIL: after the read irq %b busy %b", irq, key_busy); errors = errors + 1; end
		// (a console that is not there takes nothing)
		@(negedge clk); key_stb = 1; key_id = 7; key_d = "q"; @(negedge clk); key_stb = 0;
		if (key_busy !== 9'd0) begin $display("FAIL: a console that is not there is busy"); errors = errors + 1; end

		// the kept registers, and the divisor's latch out of the way
		wr(2, 3, 8'h83); rd(2, 0, v); want("DLL", v, 8'h01);
		wr(2, 3, 8'h03); wr(2, 7, 8'h5a); rd(2, 7, v); want("SCR", v, 8'h5a);
		rd(2, 3, v); want("LCR", v, 8'h03);
		rd(2, 6, v); want("MSR", v, 8'hb0);

		if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
		$finish;
	end

endmodule
