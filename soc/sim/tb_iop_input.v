/*
 * The I/O processor's keyboard and mouse as virtio input devices
 * (fw/iop, INPUT=1: vinput.c): k_iop and its program, Zeitlos's USB
 * host controller with its model of a USB device as a keyboard and as a
 * mouse (as tb_iop_usb.v has them), the virtio slots (k_virtio.v), and
 * a little of the host: 16 KB of its memory and what a driver does to
 * a slot's registers.
 *
 * The host asks both devices what they are (their names, the keys of
 * one, the range of the other's pointer), gives each an event queue of
 * eight buffers, and then:
 *
 *   - a key at a terminal is typed, and the host's device says nothing;
 *   - Super with 0, the graphics screen: the same key is two events of
 *     the keyboard's, down and up, with Linux's key code, and nothing
 *     is typed; Shift goes down before its key and up after it;
 *   - the mouse moved and its button pressed are the pointer's place
 *     and BTN_LEFT, and the text mode has no pointer to show;
 *   - the menus open over it (a Super key alone) and take the keys;
 *   - the driver lights Caps Lock;
 *   - Super with 1: a terminal again, and the key is typed.
 *
 *   make input        (in soc/sim)
 */

`timescale 1ns/1ps

module tb_iop_input;

	parameter FW = "../fw/iop/iop.hex";

	reg clk = 0, rst = 1;
	always #10.4167 clk = ~clk;			// 48 MHz

	wire [17:0] t_adr; wire [31:0] t_dw, t_dr; wire t_we, t_stb, t_ack; wire [3:0] t_sel;
	wire [10:0] u_adr; wire [31:0] u_dw, u_dr; wire u_we, u_stb, u_ack; wire [3:0] u_sel;
	wire key_stb; wire [7:0] key_dat; wire [3:0] key_id;
	wire trap, p_req, x_stb;

	// the virtio slots, and the host's side of them (the tasks below)
	wire        v_req, v_we;
	wire  [2:0] v_adr;
	wire [31:0] v_wdat, v_rdat;
	reg         h_stb = 0, h_we = 0;
	reg   [2:0] h_slot = 0;
	reg   [9:0] h_adr = 0;
	reg   [3:0] h_sel = 0;
	reg  [31:0] h_wdat = 0;
	wire        h_ack;
	wire [31:0] h_rdat;
	wire  [3:0] v_irq;
	k_virtio #(.N(4)) virtio (
		.clk(clk), .rst(rst),
		.h_stb(h_stb), .h_we(h_we), .h_slot(h_slot), .h_adr(h_adr), .h_sel(h_sel), .h_wdat(h_wdat),
		.h_ack(h_ack), .h_rdat(h_rdat), .h_hold(), .irq(v_irq),
		.i_req(v_req), .i_we(v_we), .i_adr(v_adr), .i_wdat(v_wdat), .i_rdat(v_rdat)
	);

	// (a request's registers are unknown until the first request, and the
	// I/O processor reads them every turn: in a simulation with unknown
	// values that stops its model, as the USB controller's buffer did)
	initial begin
		virtio.q_we = 0; virtio.q_slot = 0; virtio.q_adr = 0; virtio.q_sel = 0; virtio.q_wdat = 0;
		virtio.h_rdat = 0;
	end

	// the host's main memory, as much of it as the queues need: 16 KB
	// at 0x8000_0000, answered the cycle after it is asked
	reg  [31:0] hmem [0:4095];
	wire [28:0] p_adr;
	wire        p_we;
	wire  [3:0] p_sel;
	wire [31:0] p_wdat;
	reg         p_ack = 0;
	reg  [31:0] p_rdat = 0;
	integer hi;
	initial for (hi = 0; hi < 4096; hi = hi + 1) hmem[hi] = 32'd0;
	always @(posedge clk) begin
		p_ack <= p_req && !p_ack;
		if (p_req && !p_ack) begin
			p_rdat <= hmem[p_adr[13:2]];
			if (p_we) begin
				if (p_sel[0]) hmem[p_adr[13:2]][7:0]   <= p_wdat[7:0];
				if (p_sel[1]) hmem[p_adr[13:2]][15:8]  <= p_wdat[15:8];
				if (p_sel[2]) hmem[p_adr[13:2]][23:16] <= p_wdat[23:16];
				if (p_sel[3]) hmem[p_adr[13:2]][31:24] <= p_wdat[31:24];
			end
		end
	end

	// (four consoles: the keys go to the console of the terminal shown)
	k_iop #(.FW_HEX(FW), .USB(1), .TERMS(4)) iop (
		.clk(clk), .rst(rst),
		.con_stb(1'b0), .con_dat(8'd0), .con_id(4'd0), .con_full(),
		.key_stb(key_stb), .key_dat(key_dat), .key_id(key_id), .key_busy(10'd0),
		.t_adr_o(t_adr), .t_dat_o(t_dw), .t_dat_i(t_dr), .t_we_o(t_we), .t_sel_o(t_sel),
		.t_stb_o(t_stb), .t_ack_i(t_ack),
		.u_adr_o(u_adr), .u_dat_o(u_dw), .u_dat_i(u_dr), .u_we_o(u_we), .u_sel_o(u_sel),
		.u_stb_o(u_stb), .u_ack_i(u_ack),
		.v_req(v_req), .v_we(v_we), .v_adr(v_adr), .v_wdat(v_wdat), .v_rdat(v_rdat),
		.p_req(p_req), .p_adr(p_adr), .p_we(p_we), .p_sel(p_sel), .p_wdat(p_wdat), .p_ack(p_ack), .p_rdat(p_rdat),
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
	// the lowest the stack pointer has been (EBSS: where the program's
	// data end, from the Makefile; 0: not checked)
	parameter EBSS = 0;
	integer sp_min = 32'h7fffffff;
	always @(posedge clk)
		if (!rst && iop.cpu.cpuregs[2] != 0 && iop.cpu.cpuregs[2] < sp_min) sp_min = iop.cpu.cpuregs[2];

	reg        text_gfx = 0;		// GRAPHICS: the framebuffer is on the screen
	assign t_ack = t_ack_r;
	assign t_dr = 32'h7e88_0000;
	always @(posedge clk) begin
		t_ack_r <= t_stb && !t_ack_r;
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20000) text_ctrl <= t_dw[5:0];
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20010) text_base <= t_dw[14:0];
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20018) text_ptr <= t_dw[15:0];
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h2001c) text_sel <= t_dw;
		if (t_stb && !t_ack_r && t_we && t_adr == 18'h20020) text_gfx <= t_dw[0];
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

	generate begin : dev
		tb_usb_device #(.MODE(1), .MPS0(8)) kb (
			.dp(dp[0]), .dm(dm[0]), .attach(plug),
			.hub_en(), .hub_rst(), .hub_conn(4'b0000), .ext_reset(1'b0)
		);
		tb_usb_device #(.MODE(1), .MPS0(8)) ms (
			.dp(dp[1]), .dm(dm[1]), .attach(plug_m),
			.hub_en(), .hub_rst(), .hub_conn(4'b0000), .ext_reset(1'b0)
		);
	end endgenerate

`ifdef TICK
	// how far the simulation has come: a line every ten milliseconds of its time
	integer tick_n = 0;
	always @(posedge clk) begin
		tick_n = tick_n + 1;
		if (tick_n % 480000 == 0) $display("%0d ms", tick_n / 48000);
	end
`endif

	// what the I/O processor types
	integer n_got = 0, errors = 0;
	reg [7:0] last_key = 0;
	always @(posedge clk) if (key_stb) begin n_got = n_got + 1; last_key = key_dat; end

	integer after = 60000;			// clocks after a report: seen, and passed on
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

	task mreport(input [7:0] btn, input [7:0] dx, input [7:0] dy);
		integer g;
		begin
			dev.ms.hid_r0 = btn; dev.ms.hid_r1 = dx; dev.ms.hid_r2 = dy; dev.ms.hid_r3 = 0;
			dev.ms.hid_have = 1;
			g = 0;
			while (dev.ms.hid_have && g < 4000000) begin @(posedge clk); g = g + 1; end
			if (g >= 4000000) begin $display("FAIL: a mouse report was not taken"); errors = errors + 1; end
			repeat (after) @(posedge clk);
		end
	endtask

	// ------------------------------------------------------------
	// the host: a slot's registers, as a driver reads and writes them
	// ------------------------------------------------------------

	reg [31:0] rd;
	task vreg(input [2:0] slot, input [11:0] off, input we, input [3:0] sel, input [31:0] dat);
		integer g;
		begin
			@(posedge clk);
			h_slot = slot; h_adr = off[11:2]; h_we = we; h_sel = sel; h_wdat = dat; h_stb = 1;
			g = 0;
			@(posedge clk);
			while (!h_ack && g < 2000000) begin @(posedge clk); g = g + 1; end
			if (!h_ack) begin $display("FAIL: slot %0d register %03x was not answered", slot, off); errors = errors + 1; end
			rd = h_rdat;
			h_stb = 0;
			@(posedge clk);
		end
	endtask
	task vwr(input [2:0] slot, input [11:0] off, input [31:0] dat);
		vreg(slot, off, 1'b1, 4'b1111, dat);
	endtask
	task vrd(input [2:0] slot, input [11:0] off);
		vreg(slot, off, 1'b0, 4'b1111, 32'd0);
	endtask

	// the configuration asked: select and subsel, a byte each as Linux
	// writes them; rd is then the word with the answer's size in [23:16]
	task ask(input [2:0] slot, input [7:0] sel, input [7:0] subsel);
		begin
			vreg(slot, 12'h100, 1'b1, 4'b0001, { 24'd0, sel });
			vreg(slot, 12'h100, 1'b1, 4'b0010, { 16'd0, subsel, 8'd0 });
			vrd(slot, 12'h100);
		end
	endtask

	// A device's queues in the host's memory, 4 KB a device at word
	// B = 1024 * (slot - 2): the event queue's descriptors at B, its
	// driver's ring at B + 64, the device's at B + 128, eight buffers of
	// two words from B + 256; the status queue's at B + 512, + 576,
	// + 640, and its one buffer at B + 768.
	function [31:0] ha(input integer w);		// a word's address, as the host has it
		ha = 32'h8000_0000 + 4 * w;
	endfunction

	task setup(input [2:0] slot);
		integer B, i;
		begin
			B = 1024 * (slot - 2);
			for (i = 0; i < 8; i = i + 1) begin
				hmem[B + 4*i]     = ha(B + 256 + 2*i);
				hmem[B + 4*i + 1] = 32'd0;
				hmem[B + 4*i + 2] = 32'd8;
				hmem[B + 4*i + 3] = 32'h0000_0002;		// the device writes it
			end
			// the driver's ring: flags, idx (8: all of them), then 0..7
			hmem[B + 64] = { 16'd8, 16'd0 };
			for (i = 0; i < 4; i = i + 1) hmem[B + 65 + i] = ((2*i + 1) << 16) | (2*i);
			// the status queue: one descriptor, the driver's to fill
			hmem[B + 512] = ha(B + 768); hmem[B + 513] = 32'd0; hmem[B + 514] = 32'd8; hmem[B + 515] = 32'd0;
			hmem[B + 576] = 32'd0;
			hmem[B + 577] = 32'd0;

			vwr(slot, 12'h070, 32'd0);			// reset
			vwr(slot, 12'h070, 32'd1);			// acknowledged
			vwr(slot, 12'h070, 32'd3);			// ...and a driver for it
			vwr(slot, 12'h014, 32'd1); vrd(slot, 12'h010);
			if (!rd[0]) begin $display("FAIL: slot %0d does not offer version 1", slot); errors = errors + 1; end
			vwr(slot, 12'h024, 32'd1); vwr(slot, 12'h020, 32'd1);
			vwr(slot, 12'h070, 32'd11);			// features agreed
			vwr(slot, 12'h030, 32'd0);
			vrd(slot, 12'h034);
			if (rd < 8) begin $display("FAIL: slot %0d: a queue of %0d", slot, rd); errors = errors + 1; end
			vwr(slot, 12'h038, 32'd8);
			vwr(slot, 12'h080, ha(B)); vwr(slot, 12'h090, ha(B + 64)); vwr(slot, 12'h0a0, ha(B + 128));
			vwr(slot, 12'h044, 32'd1);
			vwr(slot, 12'h030, 32'd1);
			vwr(slot, 12'h038, 32'd8);
			vwr(slot, 12'h080, ha(B + 512)); vwr(slot, 12'h090, ha(B + 576)); vwr(slot, 12'h0a0, ha(B + 640));
			vwr(slot, 12'h044, 32'd1);
			vwr(slot, 12'h070, 32'd15);			// driver ready
			vwr(slot, 12'h050, 32'd0);
		end
	endtask

	// the events a device has sent since asked last: each is looked at
	// (ev_t, ev_c, ev_v; n_ev of them) and its buffer given back
	reg [15:0] ev_t [0:63];
	reg [15:0] ev_c [0:63];
	reg [31:0] ev_v [0:63];
	integer n_ev;
	integer seen [2:3];
	initial begin seen[2] = 0; seen[3] = 0; end
	task collect(input [2:0] slot);
		integer B, id, used;
		begin
			B = 1024 * (slot - 2);
			n_ev = 0;
			used = hmem[B + 128][31:16];
			while (seen[slot] != used && n_ev < 64) begin
				id = hmem[B + 129 + 2 * (seen[slot] & 7)];
				ev_t[n_ev] = hmem[B + 256 + 2*id][15:0];
				ev_c[n_ev] = hmem[B + 256 + 2*id][31:16];
				ev_v[n_ev] = hmem[B + 257 + 2*id];
				n_ev = n_ev + 1;
				seen[slot] = (seen[slot] + 1) & 16'hffff;
				// the buffer back: the driver's ring goes round with the same numbers
				hmem[B + 64][31:16] = hmem[B + 64][31:16] + 16'd1;
			end
			vwr(slot, 12'h064, 32'd3);			// the interrupt, taken
		end
	endtask

	task want(input [8*24-1:0] name, input integer i, input [15:0] t, input [15:0] c, input [31:0] v);
		begin
			if (i >= n_ev || ev_t[i] !== t || ev_c[i] !== c || ev_v[i] !== v) begin
				if (i >= n_ev) $display("FAIL: %0s: event %0d is not there (%0d came)", name, i, n_ev);
				else $display("FAIL: %0s: event %0d is %0d %0d %0d, should be %0d %0d %0d", name, i,
					ev_t[i], ev_c[i], ev_v[i], t, c, v);
				errors = errors + 1;
			end
		end
	endtask

	integer pb;
	initial for (pb = 0; pb < 2048; pb = pb + 1) host.pbuf[pb] = 8'h00;

	integer guard, typed, k;
	reg [31:0] x0;
	initial begin
		#1;
		dev.kb.cfgd[16] = 8'h01;
		force host.cap4 = 8'd0;
		force host.cap5 = 8'd0;
		dev.kb.cfgd[33] = 8'h01;
		dev.ms.cfgd[33] = 8'h01;
		repeat (20) @(posedge clk);
		rst = 0;
		repeat (20000) @(posedge clk);
		plug = 1;
		guard = 0;
		while (host.typ0 !== 2'd1 && guard < 60000000) begin @(posedge clk); guard = guard + 1; end
		if (host.typ0 !== 2'd1) begin $display("FAIL: no keyboard after %0d clocks", guard); $finish; end
		$display("a keyboard after %0d ms", guard / 48000);
		plug_m = 1;
		guard = 0;
		while (host.typ1 !== 2'd2 && guard < 12000000) begin @(posedge clk); guard = guard + 1; end
		if (host.typ1 !== 2'd2) begin $display("FAIL: no mouse after %0d clocks", guard); $finish; end
		$display("a mouse after %0d ms", guard / 48000);
		repeat (100000) @(posedge clk);

		// what the devices say they are
		vrd(3'd2, 12'h000); if (rd !== 32'h74726976) begin $display("FAIL: slot 2's magic is %08x", rd); errors = errors + 1; end
		vrd(3'd2, 12'h008); if (rd !== 32'd18) begin $display("FAIL: slot 2 is device %0d", rd); errors = errors + 1; end
		vrd(3'd3, 12'h008); if (rd !== 32'd18) begin $display("FAIL: slot 3 is device %0d", rd); errors = errors + 1; end
		ask(3'd2, 8'h01, 8'd0);
		if (rd[23:16] !== 8'd14) begin $display("FAIL: the keyboard's name has %0d letters", rd[23:16]); errors = errors + 1; end
		vrd(3'd2, 12'h108);
		if (rd !== "akaK") begin $display("FAIL: the keyboard's name begins %08x", rd); errors = errors + 1; end
		ask(3'd3, 8'h01, 8'd0);
		if (rd[23:16] !== 8'd13) begin $display("FAIL: the pointer's name has %0d letters", rd[23:16]); errors = errors + 1; end
		// the keyboard's keys: KEY_A is 30, in the fourth byte's bit 6;
		// neither Super key (125, 126) and not Scroll Lock (70)
		ask(3'd2, 8'h11, 8'd1);
		vrd(3'd2, 12'h108);
		if (!rd[30]) begin $display("FAIL: the keyboard has no A (%08x)", rd); errors = errors + 1; end
		vrd(3'd2, 12'h110);
		if (rd[6]) begin $display("FAIL: the keyboard offers Scroll Lock"); errors = errors + 1; end
		vrd(3'd2, 12'h114);
		if (rd[29] || rd[30]) begin $display("FAIL: the keyboard offers a Super key"); errors = errors + 1; end
		// the pointer: X from 0 to 639, Y to 479, and the left button (0x110)
		ask(3'd3, 8'h12, 8'd0);
		if (rd[23:16] !== 8'd20) begin $display("FAIL: the pointer's range is %0d bytes", rd[23:16]); errors = errors + 1; end
		vrd(3'd3, 12'h10c);
		if (rd !== 32'd639) begin $display("FAIL: the pointer goes to %0d across", rd); errors = errors + 1; end
		ask(3'd3, 8'h12, 8'd1);
		vrd(3'd3, 12'h10c);
		if (rd !== 32'd479) begin $display("FAIL: the pointer goes to %0d down", rd); errors = errors + 1; end
		ask(3'd3, 8'h11, 8'd1);
		vrd(3'd3, 12'h108 + 12'h020);
		if (rd[23:16] !== 8'h07) begin $display("FAIL: the pointer's buttons are %08x", rd); errors = errors + 1; end
		// (the keyboard asked again after the pointer: the one answer is made anew)
		ask(3'd2, 8'h11, 8'h11);
		vrd(3'd2, 12'h108);
		if (rd[7:0] !== 8'h07) begin $display("FAIL: the keyboard's lights are %02x", rd[7:0]); errors = errors + 1; end
		$display("the devices have said what they are");

		setup(3'd2);
		setup(3'd3);

		// at a terminal: typed, and nothing for the host's keyboard
		typed = n_got;
		tap(8'h00, 8'h04);
		if (n_got != typed + 1 || last_key !== "a") begin $display("FAIL: a at a terminal typed %0d (%02x)", n_got - typed, last_key); errors = errors + 1; end
		collect(3'd2);
		if (n_ev != 0) begin $display("FAIL: %0d events at a terminal", n_ev); errors = errors + 1; end
		mreport(8'h00, 8'd16, 8'd0);
		if (text_ptr[15] !== 1'b1) begin $display("FAIL: no pointer on the terminal"); errors = errors + 1; end
		collect(3'd3);
		if (n_ev != 0) begin $display("FAIL: %0d pointer events at a terminal", n_ev); errors = errors + 1; end

		// Super with 0: the graphics screen
		after = 200000;
		report(8'h08, 8'h00); report(8'h08, 8'h27); report(8'h08, 8'h00); report(8'h00, 8'h00);
		after = 60000;
		if (text_ptr[15] !== 1'b0) begin $display("FAIL: the terminal's pointer is still shown"); errors = errors + 1; end
		if (text_gfx !== 1'b1) begin $display("FAIL: the screen was not turned to the framebuffer"); errors = errors + 1; end
		typed = n_got;
		tap(8'h00, 8'h04);
		collect(3'd2);
		if (n_got != typed) begin $display("FAIL: a on the graphics screen was typed"); errors = errors + 1; end
		if (n_ev != 4) begin $display("FAIL: a is %0d events", n_ev); errors = errors + 1; end
		want("a", 0, 16'd1, 16'd30, 32'd1); want("a", 1, 16'd0, 16'd0, 32'd0);
		want("a", 2, 16'd1, 16'd30, 32'd0); want("a", 3, 16'd0, 16'd0, 32'd0);
		tap(8'h02, 8'h04);
		collect(3'd2);
		if (n_ev != 8) begin $display("FAIL: A is %0d events", n_ev); errors = errors + 1; end
		want("A", 0, 16'd1, 16'd42, 32'd1); want("A", 2, 16'd1, 16'd30, 32'd1);
		want("A", 4, 16'd1, 16'd30, 32'd0); want("A", 6, 16'd1, 16'd42, 32'd0);
		// more than the queue has buffers for, between two looks: Up, Enter, F1
		tap(8'h00, 8'h52); tap(8'h00, 8'h28); tap(8'h00, 8'h3a);
		collect(3'd2);
		if (n_ev != 8) begin $display("FAIL: three keys, eight buffers: %0d events", n_ev); errors = errors + 1; end
		want("Up", 0, 16'd1, 16'd103, 32'd1); want("Enter", 4, 16'd1, 16'd28, 32'd1);
		vwr(3'd2, 12'h050, 32'd0);
		repeat (60000) @(posedge clk);
		collect(3'd2);
		if (n_ev != 4) begin $display("FAIL: the rest: %0d events", n_ev); errors = errors + 1; end
		want("F1", 0, 16'd1, 16'd59, 32'd1); want("F1", 2, 16'd1, 16'd59, 32'd0);
		if (n_got != typed) begin $display("FAIL: keys on the graphics screen were typed"); errors = errors + 1; end
		$display("the keyboard is the host's");

		// the pointer: moved right by 24, then the button
		collect(3'd3);
		mreport(8'h00, 8'd24, 8'd0);
		collect(3'd3);
		if (n_ev != 2) begin $display("FAIL: the pointer moved: %0d events", n_ev); errors = errors + 1; end
		if (n_ev >= 1 && (ev_t[0] !== 16'd3 || ev_c[0] !== 16'd0)) begin $display("FAIL: the pointer moved: %0d %0d", ev_t[0], ev_c[0]); errors = errors + 1; end
		x0 = ev_v[0];
		mreport(8'h00, 8'd8, 8'd4);
		collect(3'd3);
		// (how far a movement takes the pointer is the USB controller's
		// business: further than the mouse says, when it moves fast)
		if (n_ev != 3 || ev_c[0] !== 16'd0 || ev_v[0] <= x0 || ev_v[0] > x0 + 32 || ev_t[1] !== 16'd3 || ev_c[1] !== 16'd1) begin
			$display("FAIL: the pointer moved again: %0d events, x %0d after %0d", n_ev, ev_v[0], x0); errors = errors + 1;
		end
		x0 = ev_v[0];
		mreport(8'h01, 8'd0, 8'd0);
		collect(3'd3);
		want("the button", 0, 16'd1, 16'h110, 32'd1); want("the button", 1, 16'd0, 16'd0, 32'd0);
		mreport(8'h00, 8'd0, 8'd0);
		collect(3'd3);
		want("the button up", 0, 16'd1, 16'h110, 32'd0);
		if (text_ptr[15] !== 1'b0 || text_sel[31] !== 1'b0) begin $display("FAIL: the text mode has a pointer or a selection"); errors = errors + 1; end
		$display("the pointer is the host's, at %0d across", x0);

		// the menus over it: a Super key alone opens them, the keys are
		// theirs, Scroll Lock closes them
		after = 400000;
		tap(8'h08, 8'h00);
		if (text_ctrl[4] !== 1'b1) begin $display("FAIL: the menus did not open"); errors = errors + 1; end
		tap(8'h00, 8'h51);
		tap(8'h00, 8'h47);
		after = 60000;
		collect(3'd2);
		if (n_ev != 0) begin $display("FAIL: %0d events while the menus were open", n_ev); errors = errors + 1; end

		// the driver lights Caps Lock: EV_LED (0x11), light 1, on
		hmem[1024 * 0 + 768] = { 16'd1, 16'h0011 };
		hmem[1024 * 0 + 769] = 32'd1;
		hmem[1024 * 0 + 576] = { 16'd1, 16'd0 };
		vwr(3'd2, 12'h050, 32'd1);
		repeat (200000) @(posedge clk);
		if (hmem[640][31:16] !== 16'd1) begin $display("FAIL: the light's buffer did not come back"); errors = errors + 1; end

		// Super with 1: a terminal again; a key held is let go for the host
		report(8'h00, 8'h05);
		collect(3'd2);
		want("b down", 0, 16'd1, 16'd48, 32'd1);
		after = 200000;
		report(8'h08, 8'h05); report(8'h08, 8'h1e); report(8'h08, 8'h00); report(8'h00, 8'h00);
		after = 60000;
		if (text_gfx !== 1'b0) begin $display("FAIL: the screen was not turned back to the terminal"); errors = errors + 1; end
		collect(3'd2);
		k = 0;
		for (guard = 0; guard < n_ev; guard = guard + 1)
			if (ev_t[guard] === 16'd1 && ev_c[guard] === 16'd48 && ev_v[guard] === 32'd0) k = 1;
		if (!k) begin $display("FAIL: b was not let go for the host"); errors = errors + 1; end
		typed = n_got;
		tap(8'h00, 8'h04);
		collect(3'd2);
		if (n_got != typed + 1 || n_ev != 0) begin $display("FAIL: back at a terminal: %0d typed, %0d events", n_got - typed, n_ev); errors = errors + 1; end

		// "About this machine", the menus' first entry: Super alone,
		// Enter; then Esc twice. It is the deepest the program goes.
		after = 200000;
		tap(8'h08, 8'h00);
		tap(8'h00, 8'h28);
		repeat (2000000) @(posedge clk);
		tap(8'h00, 8'h29);
		tap(8'h00, 8'h29);

		$display("the stack: down to %0d, the program's data end at %0d", sp_min, EBSS);
		if (EBSS != 0 && sp_min < EBSS) begin
			$display("FAIL: the stack went into the program's data"); errors = errors + 1;
		end
		if (trap) begin $display("FAIL: the I/O processor stopped"); errors = errors + 1; end
		if (errors != 0) $display("FAIL: %0d errors", errors);
		else $display("PASS: the keyboard and the mouse as virtio input devices");
		$finish;
	end

endmodule
