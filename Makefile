# MIPS 5-stage pipelined processor -- build and verification entry points.
#
# GNU Make 3.81 compatible on purpose: no .ONESHELL, no != assignment, no
# $(file ...). Multi-command recipes are written as a single shell line with
# backslash continuations, and stick to POSIX sh so dash is fine.

SHELL := /bin/sh

RTL_DIR  := rtl
TB_DIR   := tb
PROG_DIR := $(TB_DIR)/programs
BUILD    := build

RTL := $(wildcard $(RTL_DIR)/*.v)
TB  := $(TB_DIR)/tb_processor.v

IVERILOG    := iverilog
VVP         := vvp
VERILATOR   := verilator
WAVE_VIEWER ?= gtkwave

IVFLAGS  := -g2005 -Wall -s tb_processor

# Lint policy: no blanket -Wno- suppressions. Anything Verilator flags is
# either fixed in the RTL or silenced by a targeted lint_off pragma at the
# exact line, with a comment saying why it is safe. DECLFILENAME is the sole
# command-line exception: the pipeline registers are named IF_ID / ID_EX /
# EX_MEM / MEM_WB but live in lowercase files, per the layout in CLAUDE.md.
VLTFLAGS := --lint-only -Wall -Wno-DECLFILENAME --top-module processor

# Test programs. To add one: append the name here, give it a PROG_ID matching
# the localparam in tb/tb_processor.v and a cycle budget, then drop
# tb/programs/<name>.hex alongside.
PROGRAMS := raw_dist3

PROGID_raw_dist3 := 3
CYCLES_raw_dist3 := 20

# Which program `make wave` runs and opens.
WAVE_PROGRAM ?= raw_dist3

SIMS := $(patsubst %,$(BUILD)/%.vvp,$(PROGRAMS))

.PHONY: all lint test wave clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

# One simulation binary per test program. The program path, its id and its
# cycle budget are baked in at compile time so the testbench needs no runtime
# plusargs and each binary is self-contained.
$(BUILD)/%.vvp: $(PROG_DIR)/%.hex $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) \
	  -DPROGRAM='"$(PROG_DIR)/$*.hex"' \
	  -DVCDFILE='"$(BUILD)/$*.vcd"' \
	  -DPROG_ID=$(PROGID_$*) \
	  -DRUN_CYCLES=$(CYCLES_$*) \
	  -o $@ $(RTL) $(TB)

lint:
	$(VERILATOR) $(VLTFLAGS) $(RTL)

# vvp exits 0 even after the testbench prints TEST FAILED, so the pass/fail
# verdict comes from grepping the log, not from the simulator's exit status.
# Every program runs even if an earlier one fails, so one invocation shows the
# full picture; the non-zero exit is deferred to the end.
test: $(SIMS)
	@rc=0; \
	for s in $(SIMS); do \
	  log=$${s%.vvp}.log; \
	  echo "--- $$s ---"; \
	  $(VVP) $$s | tee $$log; \
	  if grep -q "TEST PASSED" $$log; then \
	    echo "PASS: $$s"; \
	  else \
	    echo "FAIL: $$s"; \
	    rc=1; \
	  fi; \
	  echo ""; \
	done; \
	if [ $$rc -eq 0 ]; then \
	  echo "all $(words $(PROGRAMS)) test(s) passed"; \
	else \
	  echo "one or more tests FAILED"; \
	fi; \
	exit $$rc

wave: $(BUILD)/$(WAVE_PROGRAM).vvp
	$(VVP) $(BUILD)/$(WAVE_PROGRAM).vvp
	$(WAVE_VIEWER) $(BUILD)/$(WAVE_PROGRAM).vcd

clean:
	rm -rf $(BUILD)
