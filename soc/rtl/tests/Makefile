# Tests of the SOC's own modules, under Verilator.
#
#   make            all of them
#   make cache      k_cache against a plain memory (N=<requests> SEED=<n>)
#   make text       k_text draws a frame (obj/k_text.ppm) and it is checked
#   make vcon       k_vcon's registers, as the 8250 driver uses them
#   make uart       k_uart's receive queue

N    ?= 400000
SEED ?= 1
VFLAGS = --binary -j 2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-BLKSEQ

all: cache text vcon uart

cache: obj/tb_k_cache
	@for s in $(SEED) $$(( $(SEED) + 1 )) $$(( $(SEED) + 2 )); do \
		obj/tb_k_cache +verilator+seed+$$s | sed "s/^/k_cache: /"; done

obj/tb_k_cache: tb_k_cache.v ../k_cache.v
	@mkdir -p obj
	verilator $(VFLAGS) -DK_CACHE_STATS -GN=$(N) -GSEED=$(SEED) --top-module tb_k_cache -Mdir obj/k_cache.d \
		-o ../tb_k_cache tb_k_cache.v ../k_cache.v > obj/k_cache.log 2>&1 || { tail -20 obj/k_cache.log; exit 1; }

text: obj/tb_k_text
	@obj/tb_k_text | grep -v finish | sed "s/^/k_text: /"

obj/k_font.hex: ../../tools/mkfont.py
	@mkdir -p obj
	python3 ../../tools/mkfont.py ../../ext/zeitlos/sw/data/font/font16.mem $@

obj/tb_k_text: tb_k_text.v ../k_text.v obj/k_font.hex
	verilator $(VFLAGS) --timing -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_k_text -Mdir obj/k_text.d \
		-o ../tb_k_text tb_k_text.v ../k_text.v > obj/k_text.log 2>&1 || { tail -20 obj/k_text.log; exit 1; }

vcon: obj/tb_k_vcon
	@obj/tb_k_vcon | grep -v finish | sed "s/^/k_vcon: /"

obj/tb_k_vcon: tb_k_vcon.v ../k_vcon.v
	@mkdir -p obj
	verilator $(VFLAGS) --timing -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_k_vcon -Mdir obj/k_vcon.d \
		-o ../tb_k_vcon tb_k_vcon.v ../k_vcon.v > obj/k_vcon.log 2>&1 || { tail -20 obj/k_vcon.log; exit 1; }

uart: obj/tb_k_uart obj/tb_k_uart_pipe
	@obj/tb_k_uart | grep -v finish | sed "s/^/k_uart: /"
	@obj/tb_k_uart_pipe | grep -v finish | sed "s/^/k_uart: /"

obj/tb_k_uart: tb_k_uart.v ../k_uart.v
	@mkdir -p obj
	verilator $(VFLAGS) --timing -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_k_uart -Mdir obj/k_uart.d \
		-o ../tb_k_uart tb_k_uart.v ../k_uart.v > obj/k_uart.log 2>&1 || { tail -20 obj/k_uart.log; exit 1; }

obj/tb_k_uart_pipe: tb_k_uart_pipe.v ../k_uart.v
	@mkdir -p obj
	verilator $(VFLAGS) --timing -Wno-STMTDLY -Wno-INITIALDLY --top-module tb_k_uart_pipe -Mdir obj/k_uart_pipe.d \
		-o ../tb_k_uart_pipe tb_k_uart_pipe.v ../k_uart.v > obj/k_uart_pipe.log 2>&1 || { tail -20 obj/k_uart_pipe.log; exit 1; }

clean:
	rm -rf obj

.PHONY: all cache text vcon uart clean
