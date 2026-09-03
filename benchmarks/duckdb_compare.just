import? "../justfile"

# DuckDB comparison harness: Linux guest-VM CLI vs OSv+uCache, for the WITH and
# WITHOUT variants (check out the recorded SHA of the one you want first).
# run-cold/run-warm drive the ucache-leg and duckdb-leg recipes; reps=1 is cold,
# reps>1 is warm, and `style` in the CSV follows from that.
# Console output is parsed by benchmarks/parse/*.awk, shared with
# cachefs_compare.just; each recipe prefixes its own config columns.
# All TPC-H queries except 15 (needs a nonexistent revenue.parquet). Run from the
# repo root: just -f benchmarks/duckdb_compare.just run-cold with

self := proot+"/benchmarks/duckdb_compare.just"
parse := proot+"/benchmarks/parse"
result_file := proot+"/benchmarks/results/duckdb_compare.csv"
sweep_file := proot+"/benchmarks/results/evict_sweep.csv"
queries := "01 02 03 04 05 06 07 08 09 10 11 12 13 14 16 17 18 19 20 21 22"
cores := "16"
vcpus := "16"
timeout_s := "900"
ddb_mem := "64G"

# The 8 columns benchmarks/parse/*.awk emit; each recipe prefixes its own config.
tail_header := "query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks"
header := "system,variant,memfit,style," + tail_header
sweep_header := "system,variant,memfit,style,evict_batch," + tail_header

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
    just -f {{self}} ucache-leg {{variant}} fits {{fits_mem}} {{fits_cache}} 1
    just -f {{self}} ucache-leg {{variant}} nofit {{nofit_mem}} {{nofit_cache}} 1
    if [ "{{variant}}" = "with" ]; then
        just -f {{self}} duckdb-leg fits {{fits_linux_mem}} 1
        just -f {{self}} duckdb-leg nofit {{nofit_linux_mem}} 1
    fi

# Warm: each query 3x back-to-back, at both memory-fit points.
run-warm variant="with":
    #!/usr/bin/env bash
    set -euo pipefail
    just -f {{self}} ucache-leg {{variant}} fits {{fits_mem}} {{fits_cache}} 3
    just -f {{self}} ucache-leg {{variant}} nofit {{nofit_mem}} {{nofit_cache}} 3
    if [ "{{variant}}" = "with" ]; then
        just -f {{self}} duckdb-leg fits {{fits_linux_mem}} 3
        just -f {{self}} duckdb-leg nofit {{nofit_linux_mem}} 3
    fi

# OSv+uCache: each query booted fresh and run `reps` times (rep 1 cold, 2..N warm).
ucache-leg variant memfit mem cache reps="1":
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{result_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "{{header}}" > "$RF"
    [ "{{reps}}" -gt 1 ] && style=warm || style=cold
    cfg="ucache,{{variant}},{{memfit}},$style"
    for q in {{queries}}; do
        echo "==> [ucache/{{variant}}] $style memfit={{memfit}} q=$q (cache={{cache}})"
        # </dev/null is needed: `timeout` puts QEMU in its own process group,
        # where touching the controlling tty stops it on SIGTTIN/SIGTTOU.
        out=$(timeout {{timeout_s}} bash -c \
            "cd {{proot}}/osv && just run-duckdb $q {{reps}} {{mem}} {{vcpus}} {{cache}} {{ddb_mem}} 2048 2048" 2>&1 </dev/null)
        rc=$?
        # A query can FAIL while exiting 0: a DuckDB error prints no `@@ROW` line
        # but still reaches the BENCHMARK PEAK banner. Count rows and record a
        # status row when none appear, so a broken run is visible in the CSV.
        if [ $rc -ne 0 ]; then
            [ $rc -eq 124 ] && st=TIMEOUT || st=FAIL
            echo "$cfg,$q,1,$st,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_ucache_{{variant}}_{{memfit}}_${style}_q$q.log"
        else
            n=$(printf '%s\n' "$out" | gawk -f {{parse}}/osv_rows.awk \
                | gawk -F, -v pre="$cfg" '{ print pre "," $0 }' | tee -a "$RF" | wc -l)
            if [ "$n" -eq 0 ]; then
                echo "$cfg,$q,1,ERROR,na,na,na,na,na" >> "$RF"
                printf '%s\n' "$out" > "$(dirname "$RF")/failed_ucache_{{variant}}_{{memfit}}_${style}_q$q.log"
                echo "    !! q$q produced no rows despite exit 0, see failed_*_q$q.log"
            elif [ "$n" -lt {{reps}} ]; then
                echo "    !! q$q produced only $n of {{reps}} repetitions"
            fi
        fi
        just check_downgraded_link || true
    done

# Linux guest-VM DuckDB CLI: drop_caches per query, then run it.
# reps>1 uses q{q}_repeat.sql, which has the query three times.
duckdb-leg memfit linux_mem reps="1":
    #!/usr/bin/env bash
    set -uo pipefail
    RF="{{result_file}}"; mkdir -p "$(dirname "$RF")"
    [ -f "$RF" ] || echo "{{header}}" > "$RF"
    if [ "{{reps}}" -gt 1 ]; then style=warm; sfx=_repeat; else style=cold; sfx=; fi
    cfg="duckdb,na,{{memfit}},$style"
    echo "==> [duckdb] $style memfit={{memfit}} (linux_mem={{linux_mem}})"
    # </dev/null on every VM/ssh call: see the note in ucache-leg.
    just linux_vm {{cores}} {{linux_mem}} > /dev/null 2>&1 < /dev/null &
    # Poll for sshd: a cold boot runs fsck first and takes well over 40s.
    for _ in $(seq 60); do
        just ssh true < /dev/null > /dev/null 2>&1 && break
        sleep 5
    done
    just ssh "mkdir -p /nvme; mount /dev/nvme0n1 /nvme" < /dev/null || true
    for q in {{queries}}; do
        # Capture first, then parse: piping into the parser threw away the
        # output of a query that died, leaving neither a row nor a log.
        out=$(just ssh "echo 1 > /proc/sys/vm/drop_caches; rm -f /nvme/db.tmp; duckdb -no-stdin -c 'set enable_progress_bar = false' -c '.timer on' -c '.read /root/osv/benchmarks/duckdb/tpch/q${q}${sfx}.sql' /nvme/db.tmp" < /dev/null 2>&1)
        n=$(printf '%s\n' "$out" | gawk -v q="$q" -f {{parse}}/duckdb_rows.awk \
            | gawk -F, -v pre="$cfg" '{ print pre "," $0 }' | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "$cfg,$q,1,ERROR,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_duckdb_{{memfit}}_${style}_q$q.log"
            echo "    !! q$q produced no timing, see failed_duckdb_{{memfit}}_${style}_q$q.log"
        elif [ "$n" -lt {{reps}} ]; then
            echo "    !! q$q produced only $n of {{reps}} repetitions"
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
    [ -f "$RF" ] || echo "{{sweep_header}}" > "$RF"
    if [ "{{memfit}}" = "fits" ]; then
        mem="{{fits_mem}}"; cache="{{fits_cache}}"
    else
        mem="{{nofit_mem}}"; cache="{{nofit_cache}}"
    fi
    [ "{{reps}}" -gt 1 ] && style=warm || style=cold
    for eb in {{batches}}; do
        echo "==> [ucache/{{variant}}] {{memfit}}/$style q{{query}} evict_batch=$eb (cache=$cache)"
        cfg="ucache,{{variant}},{{memfit}},$style,$eb"
        # </dev/null: see the note in ucache-leg.
        out=$(timeout {{timeout_s}} bash -c \
            "cd {{proot}}/osv && just run-duckdb {{query}} {{reps}} $mem {{vcpus}} $cache {{ddb_mem}} $eb 2048" 2>&1 </dev/null)
        rc=$?
        if [ $rc -ne 0 ]; then
            [ $rc -eq 124 ] && st=TIMEOUT || st=FAIL
            echo "$cfg,{{query}},1,$st,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_sweep_{{variant}}_{{memfit}}_q{{query}}_eb$eb.log"
            continue
        fi
        n=$(printf '%s\n' "$out" | gawk -f {{parse}}/osv_rows.awk \
            | gawk -F, -v pre="$cfg" '{ print pre "," $0 }' | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "$cfg,{{query}},1,ERROR,na,na,na,na,na" >> "$RF"
            printf '%s\n' "$out" > "$(dirname "$RF")/failed_sweep_{{variant}}_{{memfit}}_q{{query}}_eb$eb.log"
            echo "    !! evict_batch=$eb produced no rows, see failed_sweep_*_eb$eb.log"
        fi
        just check_downgraded_link || true
    done
