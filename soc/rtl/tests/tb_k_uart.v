/*
 * tb_k_uart -- k_uart's receiver: characters that come in one behind
 * the other at the pin (a terminal's ESC [ A) all wait for the host
 * and are read in order, with the interrupt up until the last is
 * taken; what is typed at the terminal meanwhile is among them; more
 * than the queue holds is lost and said to be (LSR bit 1); and what is
 * sent comes out of the pin.
 */

`timescale 1ns/1ps

module tb_k_uart;

	localparam DIV = 8, RXQ = 16;

	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	reg         req = 0, we = 0, adr2 = 0, inj = 0, rx = 1;
	reg   [3:0] sel = 0;
	reg  [31:0] wdat = 0;
	reg   [7:0] inj_d = 0;
	wire [31:0] rdat;
	wire        irq, tx, tap, st_rxv, st_txbusy;
	wire  [7:0] st_rxd;

	k_uart #(.DIV(DIV), .RXQ(RXQ)) dut (
		.clk(clk), .rst(rst),
		.req(req), .we(we), .adr2(adr2), .sel(sel), .lx(1'b0), .wdat(wdat), .rdat(rdat),
		.st_rxv(st_rxv), .st_rxd(st_rxd), .st_txbusy(st_txbusy), .irq(irq),
		.tap(tap), .hold(1'b0), .inj(inj), .inj_d(inj_d),
		.rx(rx), .tx(tx),
		.p_tx_valid(), .p_tx_data(), .p_tx_ready(1'b0),
		.p_rx_valid(1'b0), .p_rx_data(8'd0), .p_rx_ready()
	);

	integer errors = 0, i;
	reg [7:0] v;

	task wr(input [2:0] r, input [7:0] d);
		begin
			@(negedge clk); req = 1; we = 1; adr2 = r[2]; sel = 4'b0001 << r[1:0]; wdat = { 4{d} };
			@(negedge clk); req = 0; we = 0;
		end
	endtask
	task rd(input [2:0] r, output [7:0] d);
		begin
			@(negedge clk); req = 1; we = 0; adr2 = r[2]; sel = 4'b0001 << r[1:0];
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
	// a character at the pin, with one stop bit and nothing after it
	task pin(input [7:0] d);
		integer k;
		begin
			rx = 0; repeat (DIV) @(posedge clk);
			for (k = 0; k < 8; k = k + 1) begin rx = d[k]; repeat (DIV) @(posedge clk); end
			rx = 1; repeat (DIV) @(posedge clk);
		end
	endtask

	// what comes out of the pin
	reg [7:0] sent;
	integer   n_sent = 0, b;
	always begin
		@(negedge tx);
		repeat (DIV + DIV / 2) @(posedge clk);
		for (b = 0; b < 8; b = b + 1) begin sent[b] = tx; repeat (DIV) @(posedge clk); end
		n_sent = n_sent + 1;
	end

	initial begin
		repeat (4) @(posedge clk); rst = 0;
		wr(1, 8'h01);							// interrupt while a character waits

		// ESC [ A in one go
		pin(8'h1b); pin(8'h5b); pin(8'h41);
		repeat (4) @(posedge clk);
		want("irq", irq, 1);
		rd(2, v); want("IIR", v, 8'hc4);
		rd(5, v); want("LSR", v & 8'h03, 8'h01);
		rd(0, v); want("first", v, 8'h1b);
		rd(0, v); want("second", v, 8'h5b);
		want("irq before the last", irq, 1);
		rd(0, v); want("third", v, 8'h41);
		want("irq after the last", irq, 0);
		rd(5, v); want("LSR empty", v & 8'h03, 8'h00);

		// typed at the terminal while the pin's character ends: both
		fork
			pin(8'h61);
			begin
				repeat (DIV * 9 + DIV / 2) @(posedge clk);		// where the stop bit is sampled
				for (i = 0; i < 4; i = i + 1) begin
					@(negedge clk); inj = 1; inj_d = 8'h30 + i; @(negedge clk); inj = 0;
				end
			end
		join
		repeat (4) @(posedge clk);
		begin : both
			integer n_a, n_d; n_a = 0; n_d = 0;
			for (i = 0; i < 5; i = i + 1) begin
				rd(0, v);
				if (v == 8'h61) n_a = n_a + 1; else if (v == 8'h30 + n_d) n_d = n_d + 1;
			end
			want("pin's among typed", n_a, 1);
			want("typed in order", n_d, 4);
		end
		rd(5, v); want("LSR empty 2", v & 8'h03, 8'h00);

		// more than the queue holds
		for (i = 0; i < RXQ + 3; i = i + 1) pin(8'h40 + i);
		repeat (4) @(posedge clk);
		rd(5, v); want("LSR lost", v & 8'h03, 8'h03);
		rd(5, v); want("LSR lost once", v & 8'h03, 8'h01);
		for (i = 0; i < RXQ; i = i + 1) begin rd(0, v); want("queued", v, 8'h40 + i); end
		rd(5, v); want("LSR empty 3", v & 8'h03, 8'h00);
		pin(8'h7e); repeat (4) @(posedge clk);
		rd(0, v); want("after full", v, 8'h7e);

		// sending
		wr(0, 8'h55);
		repeat (DIV * 14) @(posedge clk);
		want("sent", sent, 8'h55);
		want("sent once", n_sent, 1);

		if (errors == 0) $display("ok: bursts at the pin are queued and read in order");
		else $display("%0d errors", errors);
		$finish;
	end

endmodule
