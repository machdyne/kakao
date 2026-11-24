/*
 * tb_firstlight -- the first-light design as built, with a terminal
 * on its UART: prints what it sends and, once it asks, types "ok" and
 * a return, and ends when that has been echoed.
 */

`timescale 1ns / 1ps

module tb_firstlight;

	parameter DIV = 48;

	reg clk = 0;
	always #5 clk = ~clk;

	wire tx;
	reg  rx = 1;
	wire led;

	firstlight #(
		.UART_DIV(DIV),
		.FW_PREFIX("../../fw/firstlight/firstlight")
	) dut (.CLK_48(clk), .UART0_TX(tx), .UART0_RX(rx), .LED_B(led));

	// the terminal's receiver
	integer k;
	reg [7:0] c;
	reg [8*16-1:0] tail = 0;
	integer echoed = 0;
	always begin
		@(negedge tx);
		repeat (DIV + DIV / 2) @(posedge clk);
		for (k = 0; k < 8; k = k + 1) begin
			c[k] = tx;
			repeat (DIV) @(posedge clk);
		end
		$write("%c", c);
		tail = { tail[8*15-1:0], c };
		if (tail[8*4-1:0] == "ok\r\n" && echoed) begin
			$display("[tb] echo seen, done");
			$finish;
		end
	end

	task send(input [7:0] ch);
		integer n;
		begin
			rx = 0; repeat (DIV) @(posedge clk);
			for (n = 0; n < 8; n = n + 1) begin
				rx = ch[n]; repeat (DIV) @(posedge clk);
			end
			rx = 1; repeat (DIV * 2) @(posedge clk);
		end
	endtask

	initial begin
		// wait for "type something\r\n"
		wait (tail[8*11-1:0] == "something\r\n");
		repeat (2000) @(posedge clk);
		echoed = 1;
		send("o"); send("k"); send(8'h0d);
	end

	initial begin
		repeat (20000000) @(posedge clk);
		$display("\n[tb] TIMEOUT");
		$finish;
	end

endmodule
