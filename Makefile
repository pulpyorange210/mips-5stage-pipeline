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
YOSYS       := yosys
WAVE_VIEWER ?= gtkwave

IVFLAGS_BASE := -g2005 -Wall -I$(TB_DIR)
IVFLAGS      := $(IVFLAGS_BASE) -s tb_processor

SELFTEST_SRC := $(TB_DIR)/tb_invariants_selftest.v
SELFTEST_BIN := $(BUILD)/invariants_selftest.vvp
INVARIANTS   := $(TB_DIR)/invariants.vh

# Lint policy: no blanket -Wno- suppressions. Anything Verilator flags is
# either fixed in the RTL or silenced by a targeted lint_off pragma at the
# exact line, with a comment saying why it is safe. DECLFILENAME is the sole
# command-line exception: the pipeline registers are named IF_ID / ID_EX /
# EX_MEM / MEM_WB but live in lowercase files, per the layout in CLAUDE.md.
VLTFLAGS := --lint-only -Wall -Wno-DECLFILENAME --top-module processor

# Test programs. To add one: append the name here, give it a PROG_ID matching
# the localparam in tb/tb_processor.v and a cycle budget, then drop
# tb/programs/<name>.hex alongside.
PROGRAMS := raw_dist1 raw_dist2 raw_dist3 load_use r0_write jump_flush

PROGID_raw_dist1  := 1
PROGID_raw_dist2  := 2
PROGID_raw_dist3  := 3
PROGID_load_use   := 4
PROGID_r0_write   := 5
PROGID_jump_flush := 6

# Cycle budgets. Each is comfortably past the point the last instruction
# retires; the .hex headers carry the arithmetic for load_use and jump_flush.
CYCLES_raw_dist1  := 20
CYCLES_raw_dist2  := 20
CYCLES_raw_dist3  := 20
CYCLES_load_use   := 20
CYCLES_r0_write   := 20
CYCLES_jump_flush := 24

# Which program `make wave` runs and opens.
WAVE_PROGRAM ?= raw_dist3

SIMS := $(patsubst %,$(BUILD)/%.vvp,$(PROGRAMS))

.PHONY: all lint test selftest check wave synth clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

# One simulation binary per test program. The program path, its id and its
# cycle budget are baked in at compile time so the testbench needs no runtime
# plusargs and each binary is self-contained.
$(BUILD)/%.vvp: $(PROG_DIR)/%.hex $(RTL) $(TB) $(INVARIANTS) | $(BUILD)
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

# Verifies the testbench, not the processor: it corrupts the state each
# invariant polices and asserts the invariant fires. Deliberately kept out of
# `make test`, which is about the DUT. `make check` runs both.
$(SELFTEST_BIN): $(RTL) $(SELFTEST_SRC) $(INVARIANTS) | $(BUILD)
	$(IVERILOG) $(IVFLAGS_BASE) -s tb_invariants_selftest \
	  -DVCDFILE='"$(BUILD)/invariants_selftest.vcd"' \
	  -o $@ $(RTL) $(SELFTEST_SRC)

selftest: $(SELFTEST_BIN)
	@log=$(BUILD)/invariants_selftest.log; \
	$(VVP) $(SELFTEST_BIN) | tee $$log; \
	if grep -q "TEST PASSED" $$log; then \
	  echo "PASS: invariants selftest"; \
	else \
	  echo "FAIL: invariants selftest"; \
	  exit 1; \
	fi

check: lint selftest test

wave: $(BUILD)/$(WAVE_PROGRAM).vvp
	$(VVP) $(BUILD)/$(WAVE_PROGRAM).vvp
	$(WAVE_VIEWER) $(BUILD)/$(WAVE_PROGRAM).vcd

# RTL-level cell count, per module. Not part of check, and not a gate count:
# no target library is involved, so the number is only meaningful compared
# against itself, which is what it is for -- sizing the effect of an RTL change.
#
# Deliberately no -top. Elaborating with -top processor reports zero cells, and
# that is correct rather than broken: the top has only CLK and reset and no
# outputs at all, so every cell in the design is unobservable and the optimiser
# removes the lot. Without -top, each module keeps its ports and its logic
# survives to be counted. The underlying limitation is real and is in the README.
synth: | $(BUILD)
	@$(YOSYS) -p "read_verilog $(RTL); proc; opt; stat" \
	  > $(BUILD)/synth.log 2>&1 || { tail -20 $(BUILD)/synth.log; exit 1; }
	@sed -n '/Printing statistics/,$$p' $(BUILD)/synth.log \
	  | grep -E "^=== |Number of cells"
	@echo "full log: $(BUILD)/synth.log"

clean:
	rm -rf $(BUILD)
