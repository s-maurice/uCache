# DuckDB CLI output -> the same 8-column tail as osv_rows.awk.
# One process runs one query, so the Nth "Run Time" line is repetition N; keep .timer
# off around anything else that emits one. -v q=<query> supplies the query.

{ sub(/\r$/, "") }

/^Run Time \(s\): real/ { printf "%s,%d,%.3f,na,na,na,na,na\n", q, ++rep, $5 }
