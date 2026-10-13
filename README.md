# nzip

Zero-copy, range-aware remote ZIP reader.

Pull **one member** out of a multi-hundred-megabyte archive over HTTP Range
requests. Never download the archive.

```
$ nzip bench https://cdn.tse.jus.br/estatistica/sead/odsele/votacao_candidato_munzona/votacao_candidato_munzona_2022.zip \
      votacao_candidato_munzona_2022_BR.csv -n 8 --crc

archive       579632297 bytes
target        votacao_candidato_munzona_2022_BR.csv
compressed    2001927 bytes (deflate)
uncompressed  38081808 bytes
metadata      4096 bytes / 1 range calls (once)
payload       2002250 bytes / 1 range calls per extract (16018000 total over 8 runs)
iterations    8  best 164 ms  mean 183 ms
bandwidth     2006346 bytes instead of 579632297 bytes -> 288.9x less per extract
```

2.0 MB on the wire instead of 553 MB. Two range calls. 164 ms to inflate 38 MB.

## How it works

A ZIP stores its index at the **end** of the file. nzip exploits that in three
linear steps, each one an exact byte range:

```
[ Local Header 1 | Data 1 | ... | Local Header N | Data N | Central Dir | EOCD ]
                                                               ▲            ▲
  step 1  Range: bytes=-4096 ──────────────────────────────────┴────────────┘
          locate EOCD (0x06054b50), read total_entries / cd_size / cd_offset
          escalate to a 64 KiB window only if the EOCD is not in the probe

  step 2  Range: bytes={cd_offset}-{cd_offset+cd_size-1}     (skipped when the
          parse Central Directory (0x02014b50)                CD is already in
          name -> index hash map, zero-copy name slices       the tail probe)

  step 3  Range: bytes={lhoff}-{lhoff+30+name+extra+csize}
          skip the 30-byte Local File Header (0x04034b50)
          pipe the compressed stream into nstd (deflate / zstd)
```

**Exactly one range call per extract.** The local header and the compressed
stream arrive in a single request; the header's variable-length name and extra
fields are parsed out of the buffer we already have.

## Layout

```
include/nzip.h        C ABI
src/zip.zig           EOCD / ZIP64 / Central Directory parser + extract
src/c_abi.zig         C ABI exports
src/http_range.zig    HTTP Range transport for the CLI (std.http.Client)
src/main.zig          CLI
src/zip_test.zig      unit tests over synthetic archives
tests/c_caller.c      C ABI conformance test
```

## Build

```sh
zig build -Doptimize=ReleaseFast   # libnzip.a, libnzip.so, nzip CLI
zig build test                     # unit tests (ZIP64, long-local-extra fallback, CRC)
zig build test-c -Doptimize=ReleaseFast
```

Needs Zig 0.14 and the sibling `nstandard` checkout (nstd's compression core),
one directory up. Nothing else. `libnzip.a` is pure Zig: no libc, no dynamic
deps. The CLI links libc for DNS.

`libnzip.a` also carries nstd's drop-in `ZSTD_*`, zlib and `Brotli*` symbols, so
one static library covers decompression and ZIP.

## C ABI

```c
#include "nzip.h"

/* Your transport: fill dst[0..len] with archive bytes at `offset`. */
static int my_range(void *ctx, uint64_t offset, size_t len, uint8_t *dst);

nzip_archive_t *z = nzip_open_remote(my_range, my_ctx, total_archive_size);

uint64_t size = 0;
int idx = nzip_find_entry(z, "votacao_candidato_munzona_2022_BR.csv", &size);

uint8_t *buf = malloc(size);
nzip_set_verify_crc(z, 1);              /* optional */
int n = nzip_extract_entry(z, "votacao_candidato_munzona_2022_BR.csv", buf, size);

printf("fetched %llu bytes in %u range calls\n",
       nzip_fetched_bytes(z), nzip_range_calls(z));

free(buf);
nzip_close(z);
```

`tests/c_caller.c` is a complete working example (in-memory range callback).

Full surface in `include/nzip.h`:

| function | purpose |
|---|---|
| `nzip_open_remote` | parse metadata from ranged reads |
| `nzip_find_entry` | exact path -> index + uncompressed size |
| `nzip_extract_entry` / `_at` / `_alloc` | decompress into caller memory |
| `nzip_entry_count` / `nzip_entry_at` | enumerate |
| `nzip_set_verify_crc` | CRC-32 check of decompressed output |
| `nzip_fetched_bytes` / `nzip_range_calls` / `nzip_total_size` | accounting |
| `nzip_free` / `nzip_close` | teardown |

## CLI

```sh
nzip ls    <url>                            # list entries
nzip find  <url> <substring>                # filter by name
nzip stat  <url> [name]                     # archive / entry metadata
nzip get   <url> <name> [-o FILE] [--crc]   # extract one member
nzip bench <url> <name> [-n N] [--crc]      # timing + bandwidth breakdown
```

## Correctness

Extracted output is byte-identical to `zlib`'s raw inflate on the same payload,
and the CRC-32 matches the record in the central directory. Verified against
`votacao_candidato_munzona_2022.zip` (553 MB, 30 members, deflate) from the TSE
open-data CDN.

ZIP64 archives (offsets and sizes past 4 GiB) parse through the ZIP64 EOCD
locator and the 0x0001 extended-information extra field.

## Cost model

| phase | range calls | bytes |
|---|---|---|
| metadata (CD fits in the 4 KiB probe) | 1 | 4 096 |
| metadata (CD larger than the probe) | 2 | 4 096 + cd_size |
| one extract | 1 | 30 + name + extra + compressed_size (+ slack) |

Slack is 256 bytes, covering the usual difference between the local and central
extra fields. When the local header is longer than budgeted, nzip re-reads the
exact range: correct at the cost of one extra call, never a wrong result.
