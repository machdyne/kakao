/*
 * tb_k_uart_pipe -- k_uart with a byte pipe in place of the pins (the
 * console of a board whose serial port is a USB one): what is sent
 * waits for the other end and comes out in order; what the other end
 * gives queues up as characters from the pin do, and is held back when
 * the queue is full, not lost; and an end that takes nothing for STALL
 * cycles stops holding the machine up, until it takes something again.
 */

`timescale 1ns/1ps

module tb_k_uart_pipe;

	localparam RXQ = 16, STALL = 200;

	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	reg         req = 0, we = 0, adr2 = 0;
	reg   [3:0] sel = 0;
	reg  [31:0] wdat = 0;
	wire [31:0] rdat;
	wire        irq, tx, tap, st_rxv, st_txbusy;
	wire  [7:0] st_rxd;

	wire        tv, rr;
	wire  [7:0] td;
	reg         tr = 0, rv = 0;
	reg   [7:0] rdt = 0;

	k_uart #(.DIV(8), .RXQ(RXQ), .PIPE(1), .STALL(STALL)) dut (
		.clk(clk), .rst(rst),
		.req(req), .we(we), .adr2(adr2), .sel(sel), .lx(1'b0), .wdat(wdat), .rdat(rdat),
		.st_rxv(st_rxv), .st_rxd(st_rxd), .st_txbusy(st_txbusy), .irq(irq),
		.tap(tap), .hold(1'b0), .inj(1'b0), .inj_d(8'd0),
		.rx(1'b0), .tx(tx),		// (the pin low: it is not looked at)
		.p_tx_valid(tv), .p_tx_data(td), .p_tx_ready(tr),
		.p_rx_valid(rv), .p_rx_data(rdt), .p_rx_ready(rr)
	);

	integer errors = 0, i, n;
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
	// the other end gives a byte: waits until it is taken
	task give(input [7:0] d);
		begin
			@(negedge clk); rv = 1; rdt = d;
			while (!rr) @(negedge clk);
			@(negedge clk); rv = 0;
		end
	endtask
	// the host sends a character when the holding register is empty
	task send(input [7:0] d);
		begin
			rd(5, v);
			while (!v[5]) rd(5, v);
			wr(0, d);
		end
	endtask

	// what the other end took
	reg [7:0] got [0:63];
	integer g = 0;
	always @(posedge clk) if (tv && tr) begin got[g] <= td; g <= g + 1; end

	initial begin
		repeat (4) @(negedge clk);
		rst = 0;
		wr(1, 8'h01);				// the receive interrupt

		// sent: held until taken
		wr(0, 8'h41);
		repeat (4) @(negedge clk);
		rd(5, v); want("LSR, byte not taken", v & 8'h60, 8'h00);
		if (!tv || td !== 8'h41) begin $display("FAIL: the byte is not offered"); errors = errors + 1; end
		@(negedge clk); tr = 1;
		@(negedge clk); tr = 0;
		rd(5, v); want("LSR, byte taken", v & 8'h60, 8'h60);
		// a string, the other end taking one cycle in five
		fork
			begin for (i = 0; i < 20; i = i + 1) send(8'h61 + i); end
			begin
				for (n = 0; n < 300; n = n + 1) begin
					@(negedge clk); tr = (n % 5) == 4;
				end
				tr = 0;
			end
		join
		want("bytes taken", g, 21);
		for (i = 0; i < 20; i = i + 1) want("byte sent", got[i + 1], 8'h61 + i);

		// received: three in a row, read in order
		give(8'h1b); give(8'h5b); give(8'h41);
		@(negedge clk);
		if (!irq) begin $display("FAIL: no interrupt"); errors = errors + 1; end
		rd(0, v); want("first", v, 8'h1b);
		rd(0, v); want("second", v, 8'h5b);
		rd(0, v); want("third", v, 8'h41);
		rd(5, v); want("LSR, empty", v & 8'h03, 8'h00);
		// more than the queue holds: the rest waits at the other end
		fork
			begin for (i = 0; i < 40; i = i + 1) give(i); end
			begin
				repeat (400) @(negedge clk);
				for (n = 0; n < 40; n = n + 1) begin
					rd(5, v);
					while (!v[0]) rd(5, v);
					want("LSR, none lost", v & 8'h02, 8'h00);
					rd(0, v); want("in order", v, n);
				end
			end
		join

		// nobody takes: the machine is held STALL cycles, then no more
		wr(0, 8'h58);
		rd(5, v); want("LSR, held", v & 8'h20, 8'h00);
		repeat (STALL + 10) @(negedge clk);
		rd(5, v); want("LSR, given up", v & 8'h60, 8'h60);
		wr(0, 8'h59); wr(0, 8'h5a);		// dropped
		rd(5, v); want("LSR, still free", v & 8'h60, 8'h60);
		// the other end is back: it gets the byte that waited, and what follows
		@(negedge clk); tr = 1;
		repeat (3) @(negedge clk);
		send(8'h30); send(8'h31);
		repeat (4) @(negedge clk);
		tr = 0;
		want("bytes taken at the end", g, 24);
		want("the one that waited", got[21], 8'h58);
		want("after it", got[22], 8'h30);
		want("and after", got[23], 8'h31);

		if (errors == 0) $display("PASS: the byte pipe");
		else $display("%0d FAILED", errors);
		$finish;
	end

	initial begin #5_000_000; $display("FAIL: timeout"); $finish; end

endmodule
