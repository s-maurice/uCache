# OSv/uCache console (duckdb_app.cc) -> one CSV row per repetition:
#   query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks
# The counters on @@ROW are per-repetition, since reset_io_stats() zeroes them per
# query. metadata_time and min_huge_blocks come from the lines around it.

# The serial console emits CRLF; without this a line-final field keeps a \r.
{ sub(/\r$/, "") }

# Printed once per boot, before the query loop: the same value for every row.
/\[metadata\] time=/ { split($2, m, "="); meta = m[2] / 1000.0 }

# "  rows=N  time=X ms  peak_used=Y GiB  min_huge_blocks=Z", immediately before @@ROW.
/rows=/ && /time=/ { split($6, h, "="); mhb = h[2] }

/^@@ROW,/ {
    split($0, f, ",")   # @@ROW,iteration,query,time_s,read_bytes,prefetch_used,peak_used
    printf "%s,%s,%s,%.3f,%s,%s,%s,%s\n", f[3], f[2], f[4], meta, f[5], f[6], f[7], mhb
}
