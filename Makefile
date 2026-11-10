# install — repo conformance surface: build the .oo checkers, run both suites,
# and smoke the install.sh flag contract end to end.
OODA_COMPILER ?= /Projects/openOODA-core/oodac/bin/oodac
export OODA_COMPILER
OODAC_BIN ?= $(OODA_COMPILER)
export OODAC_BIN
OODA_READDIR ?= /Projects:/tmp:/usr:/lib:/lib64
OODA_WRITEDIR ?= $(CURDIR):/tmp
OO_LIST_AMBIENT_QUOTA ?= 8589934592
TF := .ooda-cache/test_functional
TR := .ooda-cache/test_refusal
ENV := OO_LIST_AMBIENT_QUOTA=$(OO_LIST_AMBIENT_QUOTA) OO_LINT_ROOTS=$(CURDIR) \
	OODA_COMPILER=$(OODA_COMPILER) OODAC_BIN=$(OODAC_BIN) \
	OODA_FS_READDIR=$(OODA_READDIR) OODA_FS_WRITEDIR=$(OODA_WRITEDIR) OODA_NO_JAIL=1
SRC := $(shell find . -name '*.oo' -not -path './.git/*' -not -path './.ooda-cache/*' -not -path './bin/*' -not -path './dist/*' | sort)

.PHONY: all build test check clean

all: build test

build: $(TF) $(TR)
	@$(ENV) $(OODA_COMPILER) check anchor.oo

$(TF): $(SRC)
	@mkdir -p .ooda-cache
	$(ENV) $(OODA_COMPILER) build tests/test_functional.oo -o $(TF)

$(TR): $(SRC)
	@mkdir -p .ooda-cache
	$(ENV) $(OODA_COMPILER) build tests/test_refusal.oo -o $(TR)

test: build
	@PATH=/nonexistent $(ENV) ./$(TF) | grep -q "PASS: functional" && echo "PASS: functional suite (PATH=/nonexistent)"
	@PATH=/nonexistent $(ENV) ./$(TR) | grep -q "PASS: refusal" && echo "PASS: refusal suite (PATH=/nonexistent)"
	@bash install.sh --help | grep -q -- "--selftest-sha" && echo "PASS: --help documents --selftest-sha"
	@bash install.sh --version | grep -qF "openOODA installer $$(cat VERSION)" && echo "PASS: --version aligns with VERSION"
	@bash install.sh --selftest-sha | grep -q "selftest-sha" && echo "PASS: --selftest-sha"
	@OPENOODA_DRY_RUN=1 NO_COLOR=1 bash install.sh --dry-run | grep -q "dry-run" && echo "PASS: --dry-run"
	@rc=0; bash install.sh --bogus-flag-zzz >/dev/null 2>&1 || rc=$$?; [ "$$rc" = "1" ] && echo "PASS: unknown flag refused (exit 1)"
	@rc=0; bash install.sh --pkg >/dev/null 2>&1 || rc=$$?; [ "$$rc" = "1" ] && echo "PASS: --pkg missing arg refused (exit 1)"
	@rc=0; bash install.sh --pkg --group >/dev/null 2>&1 || rc=$$?; [ "$$rc" = "1" ] && echo "PASS: --pkg swallowed flag refused (exit 1)"
	@echo "ALL TESTS PASSED"

check:
	@for f in $(SRC); do $(ENV) $(OODA_COMPILER) check "$$f" > /dev/null || exit 1; done
	@echo "PASS: oodac check holds on all .oo files"
	@bash -n install.sh && bash -n publish-hub.sh && for f in pkg/*/profile.d.sh; do bash -n "$$f"; done
	@echo "PASS: bash -n on install.sh publish-hub.sh pkg profile fragments"

clean:
	@rm -rf .ooda-cache
