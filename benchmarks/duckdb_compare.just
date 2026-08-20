import? "../justfile"

# DuckDB comparison harness: Linux guest-VM CLI vs OSv+uCache, for the WITH and
# WITHOUT variants (check out the recorded SHA of the one you want first).
# run-cold/run-warm drive the inner recipes: cold runs each query once, warm 3x.
# All TPC-H queries except 15 (needs a nonexistent revenue.parquet). Run from the
# repo root: just -f benchmarks/duckdb_compare.just run-cold with

self := proot+"/benchmarks/duckdb_compare.just"
result_file := proot+"/benchmarks/results/duckdb_compare.csv"
sweep_file := proot+"/benchmarks/results/evict_sweep.csv"
queries := "01 02 03 04 05 06 07 08 09 10 11 12 13 14 16 17 18 19 20 21 22"
cores := "16"
vcpus := "16"
timeout_s := "900"
ddb_mem := "64G"

# Only the uCache pool varies; VM mem is cache+256G to hold regular memory
# constant. Linux page cache size is not controllable, so Linux gets all the
# memory at both points as a single best-case reference.
fits_mem := "320G"
fits_cache := "64G"
fits_linux_mem := "512G"
nofit_mem := "258G"
nofit_cache := "2G"
nofit_linux_mem := "512G"

# Cold: each query once, at both memory-fit points.
run-cold variant="with":
    #!/usr/bin/env bash
    set -euo pipefail
    just -f {{self}} ucache-cold {{variant}} fits {{fits_mem}} {{fits_cache}}
    just -f {{self}} ucache-cold {{variant}} nofit {{nofit_mem}} {{nofit_cache}}
    if [ "{{variant}}" = "with" ]; then
        just -f {{self}} duckdb-cold fits {{fits_linux_mem}}
        just -f {{self}} duckdb-cold nofit {{nofit_linux_mem}}
    fi

# Warm: each query 3x back-to-back, at both memory-fit points.
run-warm variant="with":
    #!/usr/bin/env bash
    set -euo pipefail
    just -f {{self}} ucache-warm {{variant}} fits {{fits_mem}} {{fits_cache}}
    just -f {{self}} ucache-warm {{variant}} nofit {{nofit_mem}} {{nofit_cache}}
    if [ "{{variant}}" = "with" ]; then
        just -f {{self}} duckdb-warm fits {{fits_linux_mem}}
        just -f {{self}} duckdb-warm nofit {{nofit_linux_mem}}
    fi

# OSv+uCache, cold: each query booted fresh and run once.
ucache-cold variant memfit mem cache:
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{result_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "system,variant,memfit,style,query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks" > "$RF"
    for q in {{queries}}; do
        echo "==> [ucache/{{variant}}] cold memfit={{memfit}} q=$q (cache={{cache}})"
        # </dev/null is needed: `timeout` puts QEMU in its own process group,
        # where touching the controlling tty stops it on SIGTTIN/SIGTTOU.
        out=$(timeout {{timeout_s}} bash -c \
            "cd {{proot}}/osv && just run-duckdb $q 1 {{mem}} {{vcpus}} {{cache}} {{ddb_mem}} 2048 2048" 2>&1 </dev/null)
        rc=$?
        # A query can FAIL while exiting 0: a DuckDB error prints no `rows=/time=`
        # line but still reaches the BENCHMARK PEAK banner. Count rows and record a
        # status row when none appear, so a broken run is visible in the CSV.
        if [ $rc -ne 0 ]; then
            [ $rc -eq 124 ] && st=TIMEOUT || st=FAIL
            echo "ucache,{{variant}},{{memfit}},cold,$q,1,$st,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_ucache_{{variant}}_{{memfit}}_cold_q$q.log"
        else
            n=$(echo "$out" | gawk -v q="$q" -v variant="{{variant}}" -v mf="{{memfit}}" '
                function tob(v,u){ if(u=="GiB")return v*1073741824; if(u=="MiB")return v*1048576; if(u=="KiB")return v*1024; return v }
                # The serial console emits CRLF, so the unit of a line-final stat
                # arrives as "GiB\r", tob falls through to the raw number, and
                # read_bytes/prefetch_used land in the CSV 2^30 too small.
                { sub(/\r$/, "") }
                /rows=/ && /time=/ { rep++; split($2,a,"="); t=a[2]/1000.0; split($4,p,"="); peak=tob(p[2],$5); split($6,m,"="); mhb=m[2] }
                /\[metadata\] time=/ { split($2,mt,"="); meta=mt[2]/1000.0 }
                /^read_bytes:/ { rb=tob($2,$3) }
                /^prefetch_used_by_faults:/ { printf "ucache,%s,%s,cold,%s,%d,%.3f,%.3f,%.0f,%.0f,%.0f,%s\n", variant, mf, q, rep, t, meta, rb, tob($2,$3), peak, mhb }
            ' | tee -a "$RF" | wc -l)
            if [ "$n" -eq 0 ]; then
                echo "ucache,{{variant}},{{memfit}},cold,$q,1,ERROR,na,na,na,na,na" >> "$RF"
                printf '%s\n' "$out" > "$(dirname "$RF")/failed_ucache_{{variant}}_{{memfit}}_cold_q$q.log"
                echo "    !! q$q produced no rows despite exit 0, see failed_*_q$q.log"
            fi
        fi
        just check_downgraded_link || true
    done

# OSv+uCache, warm: each query booted fresh and run 3x (rep1 cold, rep2-3 warm).
ucache-warm variant memfit mem cache:
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{result_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "system,variant,memfit,style,query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks" > "$RF"
    for q in {{queries}}; do
        echo "==> [ucache/{{variant}}] warm memfit={{memfit}} q=$q (cache={{cache}})"
        # </dev/null: see the note in ucache-cold.
        out=$(timeout {{timeout_s}} bash -c \
            "cd {{proot}}/osv && just run-duckdb $q 3 {{mem}} {{vcpus}} {{cache}} {{ddb_mem}} 2048 2048" 2>&1 </dev/null)
        rc=$?
        # See the note in ucache-cold: exit 0 with no parsed rows is a failure too.
        if [ $rc -ne 0 ]; then
            [ $rc -eq 124 ] && st=TIMEOUT || st=FAIL
            echo "ucache,{{variant}},{{memfit}},warm,$q,1,$st,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_ucache_{{variant}}_{{memfit}}_warm_q$q.log"
        else
            n=$(echo "$out" | gawk -v q="$q" -v variant="{{variant}}" -v mf="{{memfit}}" '
                function tob(v,u){ if(u=="GiB")return v*1073741824; if(u=="MiB")return v*1048576; if(u=="KiB")return v*1024; return v }
                # The serial console emits CRLF, so the unit of a line-final stat
                # arrives as "GiB\r", tob falls through to the raw number, and
                # read_bytes/prefetch_used land in the CSV 2^30 too small.
                { sub(/\r$/, "") }
                /rows=/ && /time=/ { rep++; split($2,a,"="); t=a[2]/1000.0; split($4,p,"="); peak=tob(p[2],$5); split($6,m,"="); mhb=m[2] }
                /\[metadata\] time=/ { split($2,mt,"="); meta=mt[2]/1000.0 }
                /^read_bytes:/ { rb=tob($2,$3) }
                /^prefetch_used_by_faults:/ { printf "ucache,%s,%s,warm,%s,%d,%.3f,%.3f,%.0f,%.0f,%.0f,%s\n", variant, mf, q, rep, t, meta, rb, tob($2,$3), peak, mhb }
            ' | tee -a "$RF" | wc -l)
            if [ "$n" -eq 0 ]; then
                echo "ucache,{{variant}},{{memfit}},warm,$q,1,ERROR,na,na,na,na,na" >> "$RF"
                printf '%s\n' "$out" > "$(dirname "$RF")/failed_ucache_{{variant}}_{{memfit}}_warm_q$q.log"
                echo "    !! q$q produced no rows despite exit 0, see failed_*_q$q.log"
            elif [ "$n" -lt 3 ]; then
                echo "    !! q$q produced only $n of 3 repetitions"
            fi
        fi
        just check_downgraded_link || true
    done

# Linux guest-VM DuckDB CLI, cold: drop_caches per query, run each query once.
duckdb-cold memfit linux_mem:
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{result_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "system,variant,memfit,style,query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks" > "$RF"
    echo "==> [duckdb] cold memfit={{memfit}} (linux_mem={{linux_mem}})"
    # </dev/null on every VM/ssh call: qemu -nographic and ssh both grab the
    # controlling tty, which stops them with SIGTTIN once they are off the
    # foreground process group (see the note in ucache-cold).
    just linux_vm {{cores}} {{linux_mem}} > /dev/null 2>&1 < /dev/null &
    # Poll for sshd: a cold boot runs fsck first and takes well over 40s.
    for _ in $(seq 60); do
        just ssh true < /dev/null > /dev/null 2>&1 && break
        sleep 5
    done
    just ssh "mkdir -p /nvme; mount /dev/nvme0n1 /nvme" < /dev/null || true
    for q in {{queries}}; do
        # Capture first, then parse: piping into grep threw away the output of a
        # query that died, leaving neither a row nor a log.
        out=$(just ssh "echo 1 > /proc/sys/vm/drop_caches; rm -f /nvme/db.tmp; duckdb -no-stdin -c 'set enable_progress_bar = false' -c '.timer on' -c '.read /root/osv/benchmarks/duckdb/tpch/q${q}.sql' /nvme/db.tmp" < /dev/null 2>&1)
        n=$(printf '%s\n' "$out" | grep "Run Time" \
            | gawk -v q="$q" -v mf="{{memfit}}" '{printf "duckdb,na,%s,cold,%s,%s,%.3f,na,na,na,na,na\n", mf, q, NR, $5}' \
            | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "duckdb,na,{{memfit}},cold,$q,1,ERROR,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_duckdb_{{memfit}}_cold_q$q.log"
            echo "    !! q$q produced no timing, see failed_duckdb_{{memfit}}_cold_q$q.log"
        fi
        sleep 5
    done
    just ssh "poweroff" > /dev/null 2>&1 < /dev/null || true
    sleep 20
    just check_downgraded_link || true

# Linux guest-VM DuckDB CLI, warm: drop_caches per query, run each query 3x.
duckdb-warm memfit linux_mem:
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{result_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "system,variant,memfit,style,query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks" > "$RF"
    echo "==> [duckdb] warm memfit={{memfit}} (linux_mem={{linux_mem}})"
    # </dev/null on every VM/ssh call: qemu -nographic and ssh both grab the
    # controlling tty, which stops them with SIGTTIN once they are off the
    # foreground process group (see the note in ucache-cold).
    just linux_vm {{cores}} {{linux_mem}} > /dev/null 2>&1 < /dev/null &
    # Poll for sshd: a cold boot runs fsck first and takes well over 40s.
    for _ in $(seq 60); do
        just ssh true < /dev/null > /dev/null 2>&1 && break
        sleep 5
    done
    just ssh "mkdir -p /nvme; mount /dev/nvme0n1 /nvme" < /dev/null || true
    for q in {{queries}}; do
        # See the note in duckdb-cold: capture, then parse, then record failures.
        out=$(just ssh "echo 1 > /proc/sys/vm/drop_caches; rm -f /nvme/db.tmp; duckdb -no-stdin -c 'set enable_progress_bar = false' -c '.timer on' -c '.read /root/osv/benchmarks/duckdb/tpch/q${q}_repeat.sql' /nvme/db.tmp" < /dev/null 2>&1)
        n=$(printf '%s\n' "$out" | grep "Run Time" \
            | gawk -v q="$q" -v mf="{{memfit}}" '{printf "duckdb,na,%s,warm,%s,%s,%.3f,na,na,na,na,na\n", mf, q, NR, $5}' \
            | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "duckdb,na,{{memfit}},warm,$q,1,ERROR,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_duckdb_{{memfit}}_warm_q$q.log"
            echo "    !! q$q produced no timing, see failed_duckdb_{{memfit}}_warm_q$q.log"
        elif [ "$n" -lt 3 ]; then
            echo "    !! q$q produced only $n of 3 repetitions"
        fi
        sleep 5
    done
    just ssh "poweroff" > /dev/null 2>&1 < /dev/null || true
    sleep 20
    just check_downgraded_link || true

# Sweep UCACHE_EVICT_BATCH for one query at one memory-fit point, into its own
# CSV; prefetch_batch stays at 2048 so only one knob moves.
evict-sweep variant="with" query="08" memfit="nofit" reps="3" batches="64 256 1024 2048 8192":
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{sweep_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "system,variant,memfit,style,query,repetition,evict_batch,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks" > "$RF"
    if [ "{{memfit}}" = "fits" ]; then
        mem="{{fits_mem}}"; cache="{{fits_cache}}"
    else
        mem="{{nofit_mem}}"; cache="{{nofit_cache}}"
    fi
    [ "{{reps}}" -gt 1 ] && style=warm || style=cold
    for eb in {{batches}}; do
        echo "==> [ucache/{{variant}}] {{memfit}}/$style q{{query}} evict_batch=$eb (cache=$cache)"
        # </dev/null: see the note in ucache-cold.
        out=$(timeout {{timeout_s}} bash -c \
            "cd {{proot}}/osv && just run-duckdb {{query}} {{reps}} $mem {{vcpus}} $cache {{ddb_mem}} $eb 2048" 2>&1 </dev/null)
        rc=$?
        if [ $rc -ne 0 ]; then
            [ $rc -eq 124 ] && st=TIMEOUT || st=FAIL
            echo "ucache,{{variant}},{{memfit}},$style,{{query}},1,$eb,$st,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_sweep_{{variant}}_{{memfit}}_q{{query}}_eb$eb.log"
            continue
        fi
        n=$(echo "$out" | gawk -v q="{{query}}" -v variant="{{variant}}" -v mf="{{memfit}}" -v st="$style" -v eb="$eb" '
            function tob(v,u){ if(u=="GiB")return v*1073741824; if(u=="MiB")return v*1048576; if(u=="KiB")return v*1024; return v }
            { sub(/\r$/, "") }
            /rows=/ && /time=/ { rep++; split($2,a,"="); t=a[2]/1000.0; split($4,p,"="); peak=tob(p[2],$5); split($6,m,"="); mhb=m[2] }
            /\[metadata\] time=/ { split($2,mt,"="); meta=mt[2]/1000.0 }
            /^read_bytes:/ { rb=tob($2,$3) }
            /^prefetch_used_by_faults:/ { printf "ucache,%s,%s,%s,%s,%d,%s,%.3f,%.3f,%.0f,%.0f,%.0f,%s\n", variant, mf, st, q, rep, eb, t, meta, rb, tob($2,$3), peak, mhb }
        ' | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "ucache,{{variant}},{{memfit}},$style,{{query}},1,$eb,ERROR,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_sweep_{{variant}}_{{memfit}}_q{{query}}_eb$eb.log"
            echo "    !! evict_batch=$eb produced no rows, see failed_sweep_*_eb$eb.log"
        fi
        just check_downgraded_link || true
    done
