/* nzip.h — zero-copy, range-aware remote ZIP reader.
 *
 * Read one member out of a huge remote archive using only HTTP Range
 * requests. Three network reads: EOCD tail, central directory, target payload.
 *
 * The library is pure Zig, links as a static or shared object, needs no libc
 * and makes no I/O of its own: the caller supplies a byte-range callback
 * (curl, reqwest, raw sockets, a file, anything).
 */
#ifndef NZIP_H
#define NZIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nzip_archive nzip_archive_t;

/**
 * Fill `dst[0..len]` with the archive bytes at `offset`.
 * Return 0 on success, non-zero on failure.
 */
typedef int (*nzip_range_read_cb)(void *user_ctx, uint64_t offset, size_t len, uint8_t *dst);

typedef struct nzip_entry_info {
    uint64_t uncompressed_size;
    uint64_t compressed_size;
    uint64_t local_header_offset;
    uint16_t method;   /* 0 = stored, 8 = deflate, 93 = zstd */
    uint16_t flags;
    uint32_t crc32;
    uint32_t index;
} nzip_entry_info_t;

/* Error codes returned by the int entry points. */
#define NZIP_OK          0
#define NZIP_ERR_NOT_FOUND (-1)
#define NZIP_ERR_BUFFER    (-2)
#define NZIP_ERR_IO        (-3)
#define NZIP_ERR_FORMAT    (-4)
#define NZIP_ERR_METHOD    (-5)
#define NZIP_ERR_ARG       (-6)

/** Version string, e.g. "nzip 0.1.0". */
const char *nzip_version(void);

/**
 * Open a remote archive by reading only its Central Directory metadata.
 *
 * `total_archive_size` is the archive's byte length (from Content-Range /
 * Content-Length). On success returns an opaque handle; on failure NULL.
 *
 * Network cost: one range read of the last ~64 KiB, plus one more when the
 * central directory does not fit in that window.
 */
nzip_archive_t *nzip_open_remote(nzip_range_read_cb read_cb,
                                 void *user_ctx,
                                 uint64_t total_archive_size);

/** Close and free an archive handle. NULL-safe. */
void nzip_close(nzip_archive_t *zip);

/**
 * Find a file entry by exact relative path.
 * Writes the uncompressed size to `out_uncompressed_size` when non-NULL.
 * Returns the entry index (>= 0), or a negative NZIP_ERR_* code.
 */
int nzip_find_entry(nzip_archive_t *zip,
                    const char *filename,
                    uint64_t *out_uncompressed_size);

/**
 * Read and decompress a target file directly into caller-provided memory.
 * `dst_len` must be >= the entry's uncompressed size.
 * Returns the number of bytes written, or a negative NZIP_ERR_* code.
 */
int nzip_extract_entry(nzip_archive_t *zip,
                       const char *filename,
                       uint8_t *dst,
                       size_t dst_len);

/** Same as nzip_extract_entry but addressed by index. */
int nzip_extract_entry_at(nzip_archive_t *zip,
                          int index,
                          uint8_t *dst,
                          size_t dst_len);

/**
 * Allocate and fill a buffer with the entry's bytes.
 * `out_len` receives the length (== uncompressed_size).
 * Free the result with nzip_free(ptr, out_len).
 */
uint8_t *nzip_extract_entry_alloc(nzip_archive_t *zip, int index, uint64_t *out_len);

/** Free a buffer produced by nzip_extract_entry_alloc. */
void nzip_free(uint8_t *ptr, size_t len);

/** Number of entries in the archive. */
int nzip_entry_count(nzip_archive_t *zip);

/**
 * Inspect entry `index`. `name_out` (may be NULL) receives a NUL-terminated
 * name truncated to `name_cap - 1` bytes. `info` (may be NULL) is filled in.
 * Returns 0 or a negative NZIP_ERR_* code.
 */
int nzip_entry_at(nzip_archive_t *zip,
                  int index,
                  char *name_out,
                  size_t name_cap,
                  nzip_entry_info_t *info);

/** Total bytes pulled over the network so far. */
uint64_t nzip_fetched_bytes(nzip_archive_t *zip);

/**
 * Enable or disable CRC-32 verification of decompressed output (off by
 * default). When enabled, nzip_extract_entry* returns NZIP_ERR_FORMAT if the
 * data does not match the CRC stored in the central directory.
 */
void nzip_set_verify_crc(nzip_archive_t *zip, int enable);

/** Number of range requests issued so far. */
uint32_t nzip_range_calls(nzip_archive_t *zip);

/** Total archive size in bytes. */
uint64_t nzip_total_size(nzip_archive_t *zip);

#ifdef __cplusplus
}
#endif

#endif /* NZIP_H */
