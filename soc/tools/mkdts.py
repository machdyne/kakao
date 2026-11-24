#!/usr/bin/env python3
"""
mkdts.py --model <name> --mem <MB> [--consoles <n>] [--virtio <n>] [--isa <string>] [--bootargs <string>]
         [--initrd <start> <end>] [--liteuart] [--compatible <string>] > board.dts

The device tree of a Kakao SOC (rtl/kakao_soc.v): what every board has
is the same, and the rest is its memory, how many consoles it has
(UART 0 and the terminals' own, k_vcon.v) and where its boot puts the
root file system.

The consoles are "ns16550", not "ns16550a": they have no FIFOs, and the
8250 driver sends an "a" sixteen characters at a time.

--virtio is the number of virtio slots (k_virtio.v): the first is the SD
card as a disk, the second the network. They are where QEMU's are, with
the PLIC's sources 12 and up (QEMU's 1 to 8 are the consoles' here).

--liteuart is for the prebuilt Kakao kernel of the LiteX boards, whose
only console driver is the LiteX UART's: the SOC answers as one too.
"""
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--compatible", default="machdyne,kakao-soc")
    ap.add_argument("--mem", type=int, required=True)
    ap.add_argument("--consoles", type=int, default=1)
    ap.add_argument("--virtio", type=int, default=0)
    ap.add_argument("--initrd", nargs=2, default=None)
    ap.add_argument("--liteuart", action="store_true")
    # the CPU: kakao32 is rv32ima; kakao64 rv64imac, and Sv39
    ap.add_argument("--isa", default="rv32ima")
    # more for the kernel's command line (root=/dev/vda2 rootwait)
    ap.add_argument("--bootargs", default="")
    a = ap.parse_args()

    if a.liteuart:
        bootargs = "console=liteuart earlycon=liteuart,0xf0001000"
    else:
        bootargs = "console=ttyS0 earlycon"
    if a.bootargs:
        bootargs += " " + a.bootargs
    initrd = ""
    if a.initrd:
        initrd = "\t\tlinux,initrd-start = <%s>;\n\t\tlinux,initrd-end = <%s>;\n" % tuple(a.initrd)
    serial = ""
    for i in range(a.consoles):
        # UART 0 is the PLIC's source 10; console i after it is source i
        serial += """
		serial@%x {
			compatible = "ns16550";
			reg = <0x%x 0x100>;
			clock-frequency = <3686400>;
			interrupt-parent = <&plic>;
			interrupts = <%d>;
		};
""" % (0x10000000 + i * 0x100, 0x10000000 + i * 0x100, 10 if i == 0 else i)
    for i in range(a.virtio):
        serial += """
		virtio@%x {
			compatible = "virtio,mmio";
			reg = <0x%x 0x1000>;
			interrupt-parent = <&plic>;
			interrupts = <%d>;
		};
""" % (0x10001000 + i * 0x1000, 0x10001000 + i * 0x1000, 12 + i)
    if a.liteuart:
        serial += """
		serial@f0001000 {
			compatible = "litex,liteuart";
			reg = <0xf0001000 0x100>;
		};
"""
    print("""/dts-v1/;

/* %s: made by soc/tools/mkdts.py. %d MB, %d console%s. */

/ {
	#address-cells = <1>;
	#size-cells = <1>;
	compatible = "%s";
	model = "%s";

	chosen {
		bootargs = "%s";
		stdout-path = "/soc/serial@10000000";
%s	};

	cpus {
		#address-cells = <1>;
		#size-cells = <0>;
		timebase-frequency = <48000000>;

		cpu@0 {
			device_type = "cpu";
			compatible = "riscv";
			reg = <0>;
			status = "okay";
			riscv,isa = "%s";
			mmu-type = "riscv,%s";

			intc: interrupt-controller {
				#interrupt-cells = <1>;
				interrupt-controller;
				compatible = "riscv,cpu-intc";
			};
		};
	};

	/* as QEMU has them: how OpenSBI resets the machine and turns it
	   off (a board cannot turn itself off: there it stops) */
	poweroff {
		compatible = "syscon-poweroff";
		regmap = <&test>;
		offset = <0>;
		value = <0x5555>;
	};

	reboot {
		compatible = "syscon-reboot";
		regmap = <&test>;
		offset = <0>;
		value = <0x7777>;
	};

	memory@80000000 {
		device_type = "memory";
		reg = <0x80000000 0x%08x>;
	};

	soc {
		#address-cells = <1>;
		#size-cells = <1>;
		compatible = "simple-bus";
		ranges;

		test: test@100000 {
			compatible = "sifive,test1", "sifive,test0", "syscon";
			reg = <0x00100000 0x1000>;
		};

		clint@2000000 {
			compatible = "sifive,clint0", "riscv,clint0";
			reg = <0x02000000 0x10000>;
			interrupts-extended = <&intc 3 &intc 7>;
		};

		plic: interrupt-controller@c000000 {
			compatible = "sifive,plic-1.0.0", "riscv,plic0";
			reg = <0x0c000000 0x600000>;
			#interrupt-cells = <1>;
			#address-cells = <0>;
			interrupt-controller;
			interrupts-extended = <&intc 11 &intc 9>;
			riscv,ndev = <15>;
		};
%s	};
};""" % (a.model, a.mem, a.consoles, "" if a.consoles == 1 else "s", a.compatible, a.model,
        bootargs, initrd, a.isa, "sv39" if a.isa.startswith("rv64") else "sv32", a.mem << 20, serial))

if __name__ == "__main__":
    main()
