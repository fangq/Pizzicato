CC      ?= gcc
CFLAGS  ?= -O3 -march=x86-64-v2 -fopenmp -fPIC -Wall -Wno-unused-result -Wno-format-truncation
INCS     = -I../third_party/libraw-0.20.2-include
LIBDIR   = /usr/lib/x86_64-linux-gnu
LIBS     = -ljpeg -lpng16 -lgif -lwebp -lheif $(LIBDIR)/libraw_r.so.20 -lz -lm -lgomp -lstdc++

# AI=1 builds libpzai.a from pzai.cpp against MNN (third_party/mnn, see
# tools/fetch_mnn.sh); otherwise from pzai_stub.c, which reports no AI.
AI      ?= 0
MNN_DIR ?= $(CURDIR)/../third_party/mnn
CXX     ?= g++
CXXFLAGS ?= -O3 -march=x86-64-v2 -fPIC -std=c++17 -Wall -Wno-unused-result
MNN_LIBS = -L$(MNN_DIR)/lib -lMNN -Wl,-rpath,$(MNN_DIR)/lib

ifeq ($(AI),1)
PZAI_OBJ = pzai_mnn.o
all: libpzcore.a libpzai.a pzbench pzai_cli
else
PZAI_OBJ = pzai_stub.o
all: libpzcore.a libpzai.a pzbench
endif

pzcore.o: pzcore.c pzcore.h
	$(CC) $(CFLAGS) $(INCS) -c $< -o $@

libpzcore.a: pzcore.o
	ar rcs $@ $^

pzai_mnn.o: pzai.cpp pzai.h pzcore.h
	$(CXX) $(CXXFLAGS) -I$(MNN_DIR)/include -c $< -o $@

pzai_stub.o: pzai_stub.c pzai.h pzcore.h
	$(CC) $(CFLAGS) -c $< -o $@

# rebuilt whenever the AI setting changes (the stamp records it)
libpzai.a: $(PZAI_OBJ) .ai-$(AI)
	rm -f $@
	ar rcs $@ $(PZAI_OBJ)

.ai-$(AI):
	rm -f .ai-*
	touch $@

pzai_cli: pzai_cli.c libpzai.a libpzcore.a
	$(CC) $(CFLAGS) $< -o $@ libpzai.a libpzcore.a $(LIBS) $(MNN_LIBS)

pzbench: pzbench.c libpzcore.a
	$(CC) $(CFLAGS) $< -o $@ libpzcore.a $(LIBS)

clean:
	rm -f *.o *.a .ai-* pzbench pzai_cli

.PHONY: all clean
