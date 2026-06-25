# ============================================================================
# RISC-V Out-of-Order RV32I core -- build & simulation
# ============================================================================
VERILATOR ?= verilator
CXX       ?= g++

BUILD := build
OBJ   := $(BUILD)/obj_dir
TOP   := ooo_core
SIM   := $(BUILD)/Vooo_sim
ASM   := $(BUILD)/asm

VROOT := $(shell $(VERILATOR) --getenv VERILATOR_ROOT)
VINC  := $(VROOT)/include

# Package must come first so the modules that import it elaborate.
RTL := rtl/riscv_ooo_pkg.sv $(filter-out rtl/riscv_ooo_pkg.sv,$(wildcard rtl/*.sv))
CPP := tb/sim_main.cpp cpp_model/golden_model.cpp dpi/dpi_bridge.cpp

# NOTE: Verilator's generated build Makefile refuses to run in a directory whose
# path contains spaces.  This project's checkout path may contain spaces, so we
# use Verilator only to *generate* C++ (--cc), then compile it ourselves with g++
# using relative paths (which never contain the absolute, space-bearing prefix).
VFLAGS := --cc --sv -Wno-fatal -Wno-IMPORTSTAR --top-module $(TOP) -Mdir $(OBJ)

VRUNTIME := $(VINC)/verilated.cpp $(VINC)/verilated_dpi.cpp $(VINC)/verilated_threads.cpp
CXXFLAGS_SIM := -O2 -std=c++17 -I$(OBJ) -I$(VINC) -I$(VINC)/vltstd -Icpp_model -Idpi

ifeq ($(TRACE),1)
VFLAGS += --trace
VRUNTIME += $(VINC)/verilated_vcd_c.cpp
CXXFLAGS_SIM += -DVM_TRACE=1
endif

TESTS := $(patsubst tests/asm/%.s,%,$(wildcard tests/asm/*.s))
HEXES := $(patsubst %,tests/hex/%.hex,$(TESTS))

.PHONY: all sim asm hex check clean help
.DEFAULT_GOAL := sim

help:
	@echo "Targets:"
	@echo "  make sim            build the Verilator simulation"
	@echo "  make asm            build the RV32I assembler"
	@echo "  make hex            assemble every tests/asm/*.s into tests/hex/"
	@echo "  make check          build + assemble + run the whole test suite"
	@echo "  make run TEST=name  run a single test (tests/asm/name.s)"
	@echo "  make TRACE=1 run TEST=name VCD=wave.vcd   run with waveform dump"
	@echo "  make clean          remove build artefacts"

all: sim asm

sim: $(SIM)
$(SIM): $(RTL) $(CPP) | $(BUILD)
	$(VERILATOR) $(VFLAGS) $(RTL)
	$(CXX) $(CXXFLAGS_SIM) $(OBJ)/*.cpp $(VRUNTIME) $(CPP) -lpthread -o $(SIM)

asm: $(ASM)
$(ASM): scripts/asm.cpp | $(BUILD)
	$(CXX) -O2 -std=c++17 -o $@ $<

$(BUILD):
	@mkdir -p $(BUILD)

# Assemble a single program.
tests/hex/%.hex: tests/asm/%.s $(ASM)
	@mkdir -p tests/hex
	$(ASM) $< $@

hex: $(ASM) $(HEXES)

# Run one test:  make run TEST=arith
run: $(SIM) tests/hex/$(TEST).hex
	$(SIM) +MEM=tests/hex/$(TEST).hex +CSV=$(BUILD)/stats.csv +NAME=$(TEST) \
	       $(if $(VCD),+VCD=$(VCD),)

# Build everything and run the whole suite, collecting one CSV.
check: $(SIM) $(HEXES)
	@rm -f $(BUILD)/stats.csv
	@pass=0; fail=0; \
	for t in $(TESTS); do \
	  echo "------------------------------------------------------"; \
	  echo "RUN $$t"; \
	  if $(SIM) +MEM=tests/hex/$$t.hex +CSV=$(BUILD)/stats.csv +NAME=$$t; \
	    then pass=$$((pass+1)); else fail=$$((fail+1)); fi; \
	done; \
	echo "======================================================"; \
	echo "SUITE: $$pass passed, $$fail failed"; \
	echo "stats CSV -> $(BUILD)/stats.csv"; \
	test $$fail -eq 0

# Generate, assemble and run a batch of random programs (golden-model checked).
RAND_SEEDS ?= 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
RAND_N     ?= 300
random: $(SIM) $(ASM)
	@rm -f $(BUILD)/random.csv; mkdir -p $(BUILD)/rand
	@fail=0; for s in $(RAND_SEEDS); do \
	  python3 scripts/gen_random.py $$s $(RAND_N) > $(BUILD)/rand/r$$s.s; \
	  $(ASM) $(BUILD)/rand/r$$s.s $(BUILD)/rand/r$$s.hex; \
	  if $(SIM) +MEM=$(BUILD)/rand/r$$s.hex +CSV=$(BUILD)/random.csv +NAME=rand$$s +MAXCYCLES=100000 \
	       > $(BUILD)/rand/r$$s.log 2>&1; \
	    then echo "rand seed $$s : PASS"; \
	    else echo "rand seed $$s : FAIL"; tail -20 $(BUILD)/rand/r$$s.log; fail=1; fi; \
	done; \
	test $$fail -eq 0 && echo "ALL RANDOM TESTS PASSED"

clean:
	rm -rf $(BUILD) tests/hex
