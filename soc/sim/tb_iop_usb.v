/*
 * The I/O processor with a USB keyboard: k_iop and its program (fw/iop),
 * Zeitlos's USB host controller, and Zeitlos's model of a USB
 * device (ext/zeitlos/rtl/tb/tb_usb_device.v) as a low-speed keyboard,
 * plugged into a root port or (HUB) behind its model of a hub. Keys
 * are pressed on the model and what the I/O processor types to the
 * host is compared with what a terminal should send; the menus are
 * opened and a layout chosen in them.
 *
 * The model is a boot mouse with a four-byte report; its interface is
 * made a keyboard's here, and of a keyboard's report it then carries
 * the modifiers and the first two keys, which is all this needs. (The
 * controller takes a keyboard's third and fourth keys from the fifth
 * and sixth bytes, which a report of four does not have: here they are
 * held at none.)
 *
 * On a root port a mouse is then plugged into the other one, which the
 * model is by itself: it is moved with the button held, and what the
 * text mode is told of the pointer and the selection is looked at;
 * Super with C and Super with V, and what was selected is typed. That
 * is done in the middle of the keyboard's test (MT_AFTER=3, after the
 * layout's change; 1, 2 and 4 are other places).
 *
 * KNOWN TO FAIL, by a narrow margin of time: without MT_AFTER the mouse
 * is plugged in at the very end, 8 ms after the last key, and there
 * the driver does not get past reading the mouse's report descriptor
 * (its control transfer's last stage is never seen to end). Plugged in
 * 20 ms later (MT_DELAY=960000) the same mouse is recognised and works,
 * as it is at the four other places. So something in Zeitlos's driver
 * or controller, or in the model, can lose a transfer's end; where is
 * not known. make usb-late runs it. On a board it would show as a
 * device that is not recognised until it is plugged in again.
 *
 *   make usb          (in soc/sim) both ways round
 */

`timescale 1ns/1ps

module tb_iop_usb;

	parameter HUB = 0;
	parameter FW = "../fw/iop/iop.hex";

	reg clk = 0, rst = 1;
	always #10.4167 clk = ~clk;			// 48 MHz

	wire [17:0] t_adr; wire [31:0] t_dw, t_dr; wire t_we, t_stb, t_ack; wire [3:0] t_sel;
	wire [10:0] u_adr; wire [31:0] u_dw, u_dr; wire u_we, u_stb, u_ack; wire [3:0] u_sel;
	wire key_stb; wire [7:0] key_dat; wire [3:0] key_id;
	wire trap, p_req, x_stb;

	// (four consoles: the keys go to the console of the terminal shown)
	k_iop #(.FW_HEX(FW), .USB(1), .TERMS(4)) iop (
		.clk(clk), .rst(rst),
		.con_stb(1'b0), .con_dat(8'd0), .con_id(4'd0), .con_full(),
		.key_stb(key_stb), .key_dat(key_dat), .key_id(key_id), .key_busy(10'd0),
		.t_adr_o(t_adr), .t_dat_o(t_dw), .t_dat_i(t_dr), .t_we_o(t_we), .t_sel_o(t_sel),
		.t_stb_o(t_stb), .t_ack_i(t_ack),
		.u_adr_o(u_adr), .u_dat_o(u_dw), .u_dat_i(u_dr), .u_we_o(u_we), .u_sel_o(u_sel),
		.u_stb_o(u_stb), .u_ack_i(u_ack),
		// (no virtio slots, no host memory, no board devices here)
		.v_req(), .v_we(), .v_adr(), .v_wdat(), .v_rdat(32'd0),
		.p_req(p_req), .p_adr(), .p_we(), .p_sel(), .p_wdat(), .p_ack(p_req), .p_rdat(32'd0),
		.x_adr_o(), .x_dat_o(), .x_dat_i(32'd0), .x_we_o(), .x_sel_o(), .x_stb_o(x_stb), .x_ack_i(x_stb),
		.reset_o(),
		.trap(trap)
	);

	// the text mode is not here (it is slow to simulate, and has its
	// own test): what is written to its CTRL is kept
	reg t_ack_r = 0;
	reg [5:0] text_ctrl = 0;
	reg [14:0] text_base = 0;
	reg [15:0] text_ptr = 0;
	reg [31:0] text_sel = 0;
	assign t_ack = t_ack_r;
	assign t_dr = 32'h7e88_0000;
	always @(posedge clk) begin
		t_ack_r <= t_stb && !t_ack_r;
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20000) text_ctrl <= t_dw[5:0];
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20010) text_base <= t_dw[14:0];
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20018) text_ptr <= t_dw[15:0];
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h2001c) text_sel <= t_dw;
	end

	wire [1:0] dp, dm;
	assign (highz1, weak0) dp[0] = 1'b0;
	assign (highz1, weak0) dm[0] = 1'b0;
	assign (highz1, weak0) dp[1] = 1'b0;
	assign (highz1, weak0) dm[1] = 1'b0;

	// (the ports' own times ten times shorter: debounce 10 ms, reset 1)
	usb_host #(.PORTS(2), .T_MS(32'd4800), .T_FRAME(32'd48000)) host (
		.wb_clk_i(clk), .wb_rst_i(rst),
		.wb_adr_i(u_adr), .wb_dat_i(u_dw), .wb_dat_o(u_dr), .wb_we_i(u_we), .wb_sel_i(u_sel),
		.wb_stb_i(u_stb), .wb_ack_o(u_ack), .wb_cyc_i(u_stb),
		.usb_dp(dp), .usb_dm(dm),
		.curs_max_x(11'd639), .curs_max_y(10'd479),
		.curs_x0(), .curs_y0(), .curs_x1(), .curs_y1(), .typ0(), .typ1(),
		.tx_active_o(), .tx_port_o(), .line0_o(),
		.hid0_int_o(), .hid1_int_o(), .int_o()
	);

	reg plug = 0;
	reg plug_m = 0;
	wire [3:0] hub_en, hub_rst;

	generate if (HUB) begin : dev
		tb_usb_device #(.MODE(0), .MPS0(64), .HUB(1), .PORT_LS(4'b0001)) hub (
			.dp(dp[0]), .dm(dm[0]), .attach(plug),
			.hub_en(hub_en), .hub_rst(hub_rst), .hub_conn(4'b0001), .ext_reset(1'b0)
		);
		tb_usb_device #(.MODE(2), .MPS0(8)) kb (
			.dp(dp[0]), .dm(dm[0]), .attach(plug & hub_en[0]),
			.hub_en(), .hub_rst(), .hub_conn(4'b0000), .ext_reset(hub_rst[0])
		);
	end else begin : dev
		tb_usb_device #(.MODE(1), .MPS0(8)) kb (
			.dp(dp[0]), .dm(dm[0]), .attach(plug),
			.hub_en(), .hub_rst(), .hub_conn(4'b0000), .ext_reset(1'b0)
		);
		// (the mouse, plugged in when the keyboard's test is done)
		tb_usb_device #(.MODE(1), .MPS0(8)) ms (
			.dp(dp[1]), .dm(dm[1]), .attach(plug_m),
			.hub_en(), .hub_rst(), .hub_conn(4'b0000), .ext_reset(1'b0)
		);
	end endgenerate

	// what the I/O processor types
	reg [7:0] got [0:255];
	integer n_got = 0, errors = 0;
	integer wrong_con = 0, con = 0;		// con: the console the keys should go to
	always @(posedge clk) if (key_stb) begin
		got[n_got] = key_dat; n_got = n_got + 1;
		if (key_id != con) wrong_con = wrong_con + 1;
	end

	// the keyboard's state: modifiers and a key; out when the host has it
	integer after = 60000;			// clocks after a report: seen, and typed
	task report(input [7:0] mods, input [7:0] key);
		integer guard;
		begin
			dev.kb.hid_r0 = mods; dev.kb.hid_r1 = 0; dev.kb.hid_r2 = key; dev.kb.hid_r3 = 0;
			dev.kb.hid_have = 1;
			guard = 0;
			while (dev.kb.hid_have && guard < 4000000) begin @(posedge clk); guard = guard + 1; end
			if (guard >= 4000000) begin $display("FAIL: a report was not taken"); errors = errors + 1; end
			repeat (after) @(posedge clk);
		end
	endtask

	task tap(input [7:0] mods, input [7:0] key);
		begin report(mods, key); report(mods, 8'd0); if (mods) report(8'd0, 8'd0); end
	endtask

	// what was typed since the last check, against s
	integer chk = 0;
	task expect(input [8*16-1:0] name, input integer n, input [8*8-1:0] s);
		integer i; reg ok;
		begin
			ok = (n_got - chk == n);
			for (i = 0; i < n && ok; i = i + 1)
				if (got[chk + i] !== s[8 * (n - 1 - i) +: 8]) ok = 0;
			if (!ok) begin
				$write("FAIL: %0s: typed", name);
				for (i = chk; i < n_got; i = i + 1) $write(" %02x", got[i]);
				$write(" (%0d), should be", n_got - chk);
				for (i = 0; i < n; i = i + 1) $write(" %02x", s[8 * (n - 1 - i) +: 8]);
				$write("\n");
				errors = errors + 1;
			end
			chk = n_got;
		end
	endtask

	// the mouse's state: buttons and a movement, once
	task mreport(input [7:0] btn, input [7:0] dx, input [7:0] dy);
		integer g;
		begin
`ifndef NOMOUSE
			dev.ms.hid_r0 = btn; dev.ms.hid_r1 = dx; dev.ms.hid_r2 = dy; dev.ms.hid_r3 = 0;
			dev.ms.hid_have = 1;
			g = 0;
			while (dev.ms.hid_have && g < 4000000) begin @(posedge clk); g = g + 1; end
			if (g >= 4000000) begin $display("FAIL: a mouse report was not taken"); errors = errors + 1; end
			repeat (after) @(posedge clk);
`endif
		end
	endtask

	task mouse_test;
		integer g, n_sel;
		reg [11:0] p0;
		begin
`ifndef NOMOUSE
			dev.ms.cfgd[33] = 8'h01;
			plug_m = 1;
			g = 0;
			while (host.typ1 !== 2'd2 && g < 12000000) begin @(posedge clk); g = g + 1; end
			if (host.typ1 !== 2'd2) begin $display("FAIL: no mouse after %0d clocks", g); errors = errors + 1; end
			else $display("a mouse after %0d ms", g / 48000);
			repeat (100000) @(posedge clk);
			after = 200000;

			// moved: the pointer is shown, nothing is selected
			mreport(8'h00, 8'd16, 8'd0);
			if (text_ptr[15] !== 1'b1) begin $display("FAIL: no pointer (%04x)", text_ptr); errors = errors + 1; end
			if (text_sel[31] !== 1'b0) begin $display("FAIL: selected without a button"); errors = errors + 1; end
			p0 = text_ptr[11:0];

			// the button down, then right by five cells and a bit: six cells selected
			mreport(8'h01, 8'd0, 8'd0);
			mreport(8'h01, 8'd40, 8'd0);
			mreport(8'h00, 8'd0, 8'd0);
			n_sel = text_sel[27:16] - text_sel[11:0] + 1;
			if (text_sel[31] !== 1'b1 || text_sel[11:0] !== p0 || n_sel < 2 || n_sel > 12) begin
				$display("FAIL: the selection is %08x, from pointer %0d", text_sel, p0); errors = errors + 1;
			end

			// Super with C, Super with V: as many characters typed as cells
			// were selected (blank ones: there is no screen here), at the
			// terminal shown
			chk = n_got;
			report(8'h08, 8'h00); report(8'h08, 8'h06); report(8'h08, 8'h00); report(8'h00, 8'h00);
			if (n_got != chk) begin $display("FAIL: Super+C typed something"); errors = errors + 1; end
			report(8'h08, 8'h00); report(8'h08, 8'h19); report(8'h08, 8'h00); report(8'h00, 8'h00);
			if (n_got - chk != n_sel) begin
				$display("FAIL: %0d characters pasted, %0d cells selected", n_got - chk, n_sel); errors = errors + 1;
			end else $display("a selection of %0d cells copied and pasted", n_sel);
			chk = n_got;
			after = 60000;
`endif
		end
	endtask

	integer guard;
	initial begin
		#1;
		// a keyboard's interface: boot protocol 1, reports of 8 on paper
		dev.kb.cfgd[16] = 8'h01;
		force host.cap4 = 8'd0;
		force host.cap5 = 8'd0;
		dev.kb.cfgd[33] = 8'h01;		// (asked every frame: the test is shorter)
		repeat (20) @(posedge clk);
		rst = 0;
		repeat (20000) @(posedge clk);
		plug = 1;

		// until the driver has made it a keyboard
		guard = 0;
		while (host.typ0 !== 2'd1 && guard < 60000000) begin @(posedge clk); guard = guard + 1; end
		if (host.typ0 !== 2'd1) begin $display("FAIL: no keyboard after %0d clocks", guard); $finish; end
		$display("a keyboard after %0d ms", guard / 48000);
		repeat (100000) @(posedge clk);

		tap(8'h00, 8'h04);  expect("a", 1, "a");
		tap(8'h02, 8'h04);  expect("A", 1, "A");
		tap(8'h01, 8'h06);  expect("Ctrl+C", 1, 8'h03);
		tap(8'h00, 8'h52);  expect("Up", 3, { 8'h1b, "[A" });
		tap(8'h00, 8'h28);  expect("Enter", 1, 8'h0d);
		tap(8'h00, 8'h33);  expect("; (us)", 1, ";");
`ifdef MT_AFTER
		if (`MT_AFTER == 1) mouse_test;
`endif

		// the menus: a Super key alone, then Keyboard, Layout, the third (de)
		// (slower: the menus are drawn after each key, and a key that
		// comes and goes while they are is not seen)
		after = 400000;
		tap(8'h08, 8'h00);
		if (text_ctrl[4] !== 1'b1) begin $display("FAIL: the menus did not open"); errors = errors + 1; end
		tap(8'h00, 8'h4f);		// Right: Keyboard
		tap(8'h00, 8'h28);		// Enter: Layout's list
		tap(8'h00, 8'h51);		// Down
		tap(8'h00, 8'h51);		// Down
		tap(8'h00, 8'h28);		// Enter
		tap(8'h00, 8'h47);		// Scroll Lock: out
		if (text_ctrl[4] !== 1'b0) begin $display("FAIL: the menus did not close"); errors = errors + 1; end
		expect("in the menus", 0, "");
		after = 60000;
`ifdef MT_AFTER
		if (`MT_AFTER == 2) mouse_test;
`endif

		tap(8'h00, 8'h33);  expect("o umlaut (de)", 2, { 8'hc3, 8'hb6 });
		tap(8'h00, 8'h1c);  expect("z (de)", 1, "z");
		tap(8'h40, 8'h14);  expect("AltGr+q (de)", 1, "@");
		tap(8'h04, 8'h04);  expect("Alt+a", 2, { 8'h1b, "a" });
`ifdef MT_AFTER
		if (`MT_AFTER == 3) mouse_test;
`endif

		// the second terminal (Super with 2): its screen, and the keys to
		// its console; and back with Super and Left
		report(8'h08, 8'h00); report(8'h08, 8'h1f); report(8'h08, 8'h00); report(8'h00, 8'h00);
		expect("Super+2", 0, "");
		if (text_base !== 15'd2400) begin $display("FAIL: the second terminal is not shown (%0d)", text_base); errors = errors + 1; end
		if (text_ctrl[4] !== 1'b1) begin $display("FAIL: no note"); errors = errors + 1; end
		con = 1;
		tap(8'h00, 8'h04);  expect("a, second terminal", 1, "a");
`ifdef MT_AFTER
		if (`MT_AFTER == 4) mouse_test;
`endif
		report(8'h08, 8'h00); report(8'h08, 8'h50); report(8'h08, 8'h00); report(8'h00, 8'h00);
		if (text_base !== 15'd0) begin $display("FAIL: the first terminal is not shown (%0d)", text_base); errors = errors + 1; end
		con = 0;
		tap(8'h00, 8'h05);  expect("b, first terminal", 1, "b");
		if (wrong_con != 0) begin $display("FAIL: %0d keys went to the wrong console", wrong_con); errors = errors + 1; end

`ifndef MT_AFTER
`ifdef MT_DELAY
		repeat (`MT_DELAY) @(posedge clk);
`endif
		if (!HUB) mouse_test;
`endif

		if (trap) begin $display("FAIL: the I/O processor stopped"); errors = errors + 1; end
		if (errors != 0) $display("FAIL: %0d errors", errors);
		else if (HUB) $display("PASS: a keyboard behind a hub");
		else $display("PASS: a keyboard on a root port, and a mouse");
		$finish;
	end

`ifdef WATCH
	// what goes on, every millisecond (WATCHM: once the mouse is plugged in)
	integer ms = 0;
	always #1000000 begin
		ms = ms + 1;
`ifdef WATCHM
		if (plug_m)
`endif
		$display("%0d ms: trap %b pc %08x ports %b%b/%b%b ctrl %08x typ %0d %0d typed %0d",
			ms, trap, iop.cpu.reg_pc, dp[0], dm[0], dp[1], dm[1], host.ctrl, host.typ0, host.typ1, n_got);
	end
`endif

	initial begin
		#3000000000;		// 3 s
		$display("FAIL: not done in time");
		$finish;
	end

endmodule
