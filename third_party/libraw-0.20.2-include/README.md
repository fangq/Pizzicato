# LibRaw 0.20.2 headers

The `libraw/` headers of LibRaw 0.20.2 (https://www.libraw.org), unmodified,
so `core/pzcore.c` can be built against the system `libraw_r.so.20`
(Ubuntu 22.04 package `libraw20`, version 0.20.2). The headers must match the
library's version because `libraw_data_t` is accessed directly.

LibRaw is dual-licensed under the LGPL 2.1 (`LICENSE.LGPL`) and the CDDL 1.0
(`LICENSE.CDDL`); see `COPYRIGHT`.
