# Pizzicato build. LAZDIR must point at a built Lazarus tree (gtk2 LCL).
#   make              build ./pizzicato (and core/libpzcore.a, core/pzbench)
#   make pretty       format the sources (astyle for C, JCF for Pascal)
#   make icons        redraw the toolbar icons (python3 + pycairo) into src/pzicons.inc
#   make test         .picasa.ini round-trip test on copies of given files: INI="a.ini b.ini"
LAZDIR ?= /usr/lib/lazarus/default/
FPC    ?= fpc
ARCH    = x86_64-linux
UNITS   = -Fu$(LAZDIR)lcl/units/$(ARCH) -Fu$(LAZDIR)lcl/units/$(ARCH)/gtk2 \
          -Fu$(LAZDIR)components/lazutils/lib/$(ARCH) -Fusrc
FPCOPT  = -MObjFPC -Scghi -O3 -CX -XX -Xs -vewn -dLCL -dLCLgtk2 -FUbuild -Flcore -Fllib

all: pizzicato

core/libpzcore.a: core/pzcore.c core/pzcore.h
	$(MAKE) -C core libpzcore.a pzbench

lib/libraw_r.so:
	mkdir -p lib build
	ln -sf /usr/lib/x86_64-linux-gnu/libraw_r.so.20 $@

pizzicato: lib/libraw_r.so core/libpzcore.a src/*.pas src/*.inc src/pizzicato.lpr
	$(FPC) $(FPCOPT) $(UNITS) -o$(CURDIR)/$@ src/pizzicato.lpr

clean:
	rm -rf build/* pizzicato
	$(MAKE) -C core clean

.PHONY: all clean pretty pretty-c pretty-pas test icons

icons:
	python3 tools/make_icons.py

# ---- formatting: astyle options as in mcx/mcxcl, JCF as in Soloi ----
ASTYLE      ?= astyle
ASTYLE_OPTS  = --style=attach --indent=spaces=4 --indent-modifiers --indent-switches \
               --indent-preproc-block --indent-preproc-define --indent-col1-comments \
               --pad-oper --pad-header --align-pointer=type --align-reference=type \
               --add-brackets --convert-tabs --close-templates --lineend=linux \
               --preserve-date --suffix=none --formatted --break-blocks
JCF         ?= $(HOME)/.local/bin/jcf
JCFCFG      := $(CURDIR)/tools/jcfsettings.cfg
# include fragments (method bodies) cannot be parsed by JCF on their own
PAS_SRC      = $(wildcard src/*.pas src/*.lpr tests/*.pas)

pretty: pretty-c pretty-pas

pretty-c:
	@$(ASTYLE) $(ASTYLE_OPTS) core/*.c core/*.h | grep -v '^Unchanged' || true

pretty-pas:
	@test -x "$(JCF)" || { echo "JCF not found at $(JCF)"; exit 1; }
	@for f in $(PAS_SRC); do \
	  $(JCF) -clarify -inplace -y -config=$(JCFCFG) "$$f" >/dev/null 2>&1 || echo "JCF failed: $$f"; \
	done
	@echo "  PRETTY  Pascal sources"

test: build/test_ini
	@test -n "$(INI)" || { echo 'usage: make test INI="copy1.ini copy2.ini ..." (files are rewritten)'; exit 1; }
	build/test_ini $(INI)

build/test_ini: tests/test_ini.pas src/pzini.pas
	$(FPC) -MObjFPC -Fusrc -FUbuild -o$(CURDIR)/$@ tests/test_ini.pas
