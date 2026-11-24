# Sergei ML2

## firstlight: the CPU alive on the board

`make firstlight` builds `build/firstlight.bit`: kakao32 at 48 MHz with
64 KB of block RAM, the CLINT and the UART, running the test program
in `soc/fw/firstlight`. It is not the SOC and does not use the DDR3,
the SD card, USB or video: it answers one question, whether the CPU
works on the FPGA as it does in simulation.

Load it as any other bitstream for the board. The console is the
Sechzig UART (the pins Zeitlos uses, `UART0_TX`/`UART0_RX`), 1 Mbaud
8N1. LED_B changes every 0.35 s whenever the clock runs, whatever the
CPU is doing.

`make firstlight24` builds the same at 24 MHz through a PLL
(`build/firstlight24.bit`, LED every 0.7 s, same console): the one to
try if the 48 MHz build misbehaves, since that one's timing margin is
only a few percent.

Expected, a moment after configuration:

```
kakao32 firstlight
misa 40141101  mtime 0000xxxx
multiply and divide: ok
ecall from M-mode: ok
illegal instruction: ok
misaligned load: ok
amoadd.w, lr.w and sc.w: ok
timer interrupt after 48116 cycles (asked for 48000): ok
S-mode, a megapage, ecall back: ok
S-mode, a 4 KB page through two levels: ok
load page fault on an unmapped address: ok
store page fault on a clean page: ok
a loop of 100005 instructions took 200003 cycles: 1.99 each
all tests passed
echo: type something
```

and then whatever is typed comes back. The cycle counts are the
simulation's, and the board's should equal them: the design is
synchronous and nothing in the tests waits on the outside.

`make sim-firstlight` runs the same design under Verilator with a
terminal on the UART that checks the echo.

Timing on the 45F as placed: 49.3 MHz for the 48 MHz build (51.6 on
another seed), 47.7 MHz for the 24 MHz one. Before the data address
was registered in front of the TLB the 48 MHz build reached 47.4.

## The SOC

It is built in the directory above, as for every board
([../README.md](../README.md)): `make -C .. BOARD=sergei_ml2 seeds`.
This is the board the SOC has run on: the DDR3, the SD boot, Linux,
the picture, a USB keyboard and the menus.

After configuration the screen shows `Kakao terminal` as soon as the
clock runs, before the DDR3 is trained and whether or not it trains.
kboot then trains the DDR3 and tests some of it:

```
kboot
ddr3 dd30....
gate scan: ...
 ...
ddr3 tune 0880.... L0:C L1:C
ddr3 check a5c377c3 5a3c5a3c ok
memory test ok
```

(the scan is the one Zeitlos's BIOS prints; docs/ddr3.md there explains
it), and boots from the SD card, which takes about 20 s for the kernel
and as long for the root file system. If training fails, kboot says so
and still takes commands (`T` trains again).

`make sim-kboot` and `make sim-sdboot` here run kboot's loader and its
SD boot in simulation; `make ddr3` in `soc/sim` runs the SOC on the
DDR3 controller against Zeitlos's DRAM model, which is as close to the
board's memory as simulation gets: the PHY and the training are not in
it.
