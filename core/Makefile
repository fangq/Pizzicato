CC      ?= gcc
CFLAGS  ?= -O3 -march=x86-64-v2 -fopenmp -fPIC -Wall -Wno-unused-result -Wno-format-truncation
INCS     = -I../third_party/libraw-0.20.2-include
LIBDIR   = /usr/lib/x86_64-linux-gnu
LIBS     = -ljpeg -lpng16 -lgif -lwebp -lheif $(LIBDIR)/libraw_r.so.20 -lz -lm -lgomp -lstdc++

all: libpzcore.a pzbench

pzcore.o: pzcore.c pzcore.h
	$(CC) $(CFLAGS) $(INCS) -c $< -o $@

libpzcore.a: pzcore.o
	ar rcs $@ $^

pzbench: pzbench.c libpzcore.a
	$(CC) $(CFLAGS) $< -o $@ libpzcore.a $(LIBS)

clean:
	rm -f *.o *.a pzbench

.PHONY: all clean
