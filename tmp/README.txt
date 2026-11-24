kakao64 on the Sergei ML2: build t3 (24 Nov)

Meets timing: 48.73 MHz as placed (seed 2), for 48 MHz at speed grade 6.
Source: d427462 (machdyne/kakao main).

kakao64-sergei_ml2-t3.bit   the bitstream
sys/linux/                  for the SD card's FAT partition: the same
                            four files as t2's. A card that boots with
                            t2 needs nothing changed.

Since t2, only the I/O processor's program differs; the logic and its
placement are t2's.
- the mouse pointer no longer flashes over text, and is hidden unless
  the mouse moved within the last two seconds.
- the I/O processor's menu names the CPU that is there (kakao64,
  RV64IMAFDC) and not kakao32.

In simulation with this logic and this program: Linux boots from the
card to a shell. The pointer and the scroll buffer have run in the
firmware's own tests, not on a board.
