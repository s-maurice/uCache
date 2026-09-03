import? "../justfile"

# Linux+cache_httpfs vs OSv+uCache, on the same TPC-H parquet on the same NVMe.
# One query at a time, REPEAT repetitions back to back, cache reset in between.
# ucache: fresh OSv boot per query.
# cache_httpfs: one guest VM, fresh duckdb process per query.
# Knobs are the NAME=value assignments below, set before the recipe name:
#   just -f benchmarks/cachefs_compare.just QUERIES=06 LATENCY_US=0 compare
# LATENCY_US/BANDWIDTH: delay = latency_us + bytes / (bandwidth_gbps * 1000),
# charged per BLOCK_SIZE chunk on cache_httpfs, per page or prefetch batch on uCache.

self := proot + "/benchmarks/cachefs_compare.just"
results_dir := proot + "/benchmarks/results"
result_file := results_dir + "/cachefs_compare.csv"
access_file := results_dir + "/cachefs_access.csv"
parse := proot + "/benchmarks/parse"

# Exported so a CLI override reaches the nested `just` calls in compare and the sweeps.
export THREADS := env("THREADS", "16")
export REPEAT := env("REPEAT", "3")
export CACHE_PCT := env("CACHE_PCT", "10")
export BLOCK_SIZE := env("BLOCK_SIZE", "524288")
export POLICY := env("POLICY", "lru")
export SCOPE := env("SCOPE", "global")
export FILE_POLICIES := env("FILE_POLICIES", "")
export CHUNKING := env("CHUNKING", "")
# 1400:0.7 = MinIO over 100 GbE (measured); 20000-40000 us ~= real S3.
export LATENCY_US := env("LATENCY_US", "1400")
export BANDWIDTH := env("BANDWIDTH", "0.7")

# TPC-H minus 15: the tpch/q15.sql read on Linux points at a nonexistent
# revenue.parquet.
export QUERIES := env("QUERIES", "01 02 03 04 05 06 07 08 09 10 11 12 13 14 16 17 18 19 20 21 22")
export DDB_MEM := env("DDB_MEM", "64G")
# uCache only, in 4 KiB pages. EVICT_BATCH runs ahead of PREFETCH_BATCH so one
# eviction round can clear a whole prefetch burst.
export EVICT_BATCH := env("EVICT_BATCH", "8192")
export PREFETCH_BATCH := env("PREFETCH_BATCH", "2048")
# Both systems size their VM as cache + this, so the memory outside the cache is
# the same on each and constant as CACHE_PCT moves.
export VM_HEADROOM := env("VM_HEADROOM", "96G")
# Overrides the Linux guest's size; empty = cache + VM_HEADROOM, same as OSv.
export LINUX_MEM := env("LINUX_MEM", "")
# CACHE_PCT's denominator. DATA_BYTES short-circuits DATA_DIR; SCALE labels the CSV
# rows so SF10 and SF100 never blend, and defaults to DATA_DIR's basename.
export DATA_DIR := env("DATA_DIR", "/scratch/ilya/tpch100")
export DATA_BYTES := env("DATA_BYTES", "")
export SCALE := env("SCALE", "")
# Per-query budget, covering all REPEAT repetitions of that one query.
export TIMEOUT_S := env("TIMEOUT_S", "1800")
# Skip a (system, scale, cache_pct, query) that already has a good row in the CSV.
export RESUME := env("RESUME", "true")
# Cache size as a % of the dataset, for `sweep`.
export CACHE_PCTS := env("CACHE_PCTS", "1 5 10 40 100")

# Config columns every row carries. sim_unit is what one simulated request covered:
# a BLOCK_SIZE chunk for cache_httpfs, a page or a prefetch batch for uCache.
cfg_header := "system,scale,cache_pct,cache_bytes,threads,block_size,evict_batch,prefetch_batch,policy,scope,chunking,sim_latency_us,sim_bandwidth_gbps,sim_unit"
# Then the 8 columns benchmarks/parse/*.awk emit, identical for both systems.
header := cfg_header + ",query,repetition,time,metadata_time,read_bytes,prefetch_used,peak_used,min_huge_blocks"
acc_header := cfg_header + ",query,cache_type,cache_hit_count,cache_miss_count,bytes_from_misses"

default:
    @just -f {{self}} --list

# Total apparent bytes of the dataset, for turning CACHE_PCT into a byte budget.
# du -b matches the NVMe copy without unbinding the disk from vfio-pci.
_data_bytes:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{DATA_BYTES}}" ]; then echo "{{DATA_BYTES}}"; exit 0; fi
    if [ -z "{{DATA_DIR}}" ]; then
        echo "CACHE_PCT needs a dataset size: set DATA_DIR to the host folder holding" >&2
        echo "the TPC-H parquet, or set DATA_BYTES directly." >&2
        exit 1
    fi
    du -bc {{DATA_DIR}}/*.parquet | tail -1 | cut -f1

# CACHE_PCT of the dataset, in exact bytes: a sub-GiB cache truncated to "0G" reads
# back as unset, and the OSv app then falls back to half of RAM.
_cache_bytes:
    @echo $(( $(just -f {{self}} _data_bytes) * {{CACHE_PCT}} / 100 ))

# VM size for either system: the cache, rounded up to whole GiB, plus VM_HEADROOM.
_vm_mem:
    #!/usr/bin/env bash
    set -euo pipefail
    cache=$(just -f {{self}} _cache_bytes)
    cache_g=$(( (cache + 1073741823) / 1073741824 ))
    headroom="{{VM_HEADROOM}}"
    echo "$(( cache_g + ${headroom%[Gg]} ))G"

# The config prefix both systems stamp on every row they write.
_cfg system cache_bytes:
    #!/usr/bin/env bash
    set -euo pipefail
    scale="{{SCALE}}"; [ -n "$scale" ] || scale=$(basename "{{DATA_DIR}}")
    chunking="{{CHUNKING}}"; [ -n "$chunking" ] || chunking="fixed"
    if [ "{{system}}" = "ucache" ]; then
        # block_size/policy/scope/chunking are cache_httpfs knobs with no uCache twin.
        echo "ucache,$scale,{{CACHE_PCT}},{{cache_bytes}},{{THREADS}},na,{{EVICT_BATCH}},{{PREFETCH_BATCH}},na,na,na,{{LATENCY_US}},{{BANDWIDTH}},page+batch"
    else
        echo "cache_httpfs,$scale,{{CACHE_PCT}},{{cache_bytes}},{{THREADS}},{{BLOCK_SIZE}},na,na,{{POLICY}},{{SCOPE}},$chunking,{{LATENCY_US}},{{BANDWIDTH}},block"
    fi

# Exit 0 if the CSV already holds a real timing for this (system, scale, cache_pct,
# query). A TIMEOUT/FAIL/ERROR row parses as 0, so a failed point is retried.
_done system query:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{result_file}}" ] || exit 1
    scale="{{SCALE}}"; [ -n "$scale" ] || scale=$(basename "{{DATA_DIR}}")
    gawk -F, -v s="{{system}}" -v sc="$scale" -v p="{{CACHE_PCT}}" -v q="{{query}}" \
        '$1==s && $2==sc && $3==p && $15==q && $17+0>0 { found=1 }
         END { exit !found }' "{{result_file}}"

# The workload script cache_httpfs pipes into duckdb for one query: settings, that
# query REPEAT times, then the cache-access dump. Inspect it without booting a VM:
#   just -f benchmarks/cachefs_compare.just _script 06 3221225472
_script query cache_bytes:
    #!/usr/bin/env bash
    set -uo pipefail
    # The extension reads these settings when it builds its cache on first access;
    # setting them later does nothing. .timer goes last so the SETs emit no Run Time.
    {
        echo "SET threads={{THREADS}};"
        echo "SET memory_limit='{{DDB_MEM}}';"
        # Empty temp_directory makes DuckDB throw rather than spill, as on OSv.
        echo "SET temp_directory='';"
        echo "SET enable_external_file_cache=false;"
        echo "SET cache_httpfs_type='in_mem';"
        echo "SET cache_httpfs_cache_block_size={{BLOCK_SIZE}};"
        echo "SET cache_httpfs_in_mem_cache_storage='policy';"
        echo "SET cache_httpfs_in_mem_cache_bytes={{cache_bytes}};"
        echo "SET cache_httpfs_eviction_policy='{{POLICY}}';"
        echo "SET cache_httpfs_policy_scope='{{SCOPE}}';"
        [ -n "{{FILE_POLICIES}}" ] && echo "SET cache_httpfs_file_policies='{{FILE_POLICIES}}';"
        [ -n "{{CHUNKING}}" ] && echo "SET cache_httpfs_chunking='{{CHUNKING}}';"
        echo "SET cache_httpfs_in_mem_cache_block_timeout_millisec=86400000;"
        echo "SET cache_httpfs_sim_latency_us={{LATENCY_US}};"
        echo "SET cache_httpfs_sim_bandwidth_gbps={{BANDWIDTH}};"
        echo "SET cache_httpfs_profile_type='temp';"
        # Needed: without it /nvme/... never reaches CacheFileSystem, and reads
        # bypass both the cache and the simulated cost.
        echo "SELECT cache_httpfs_wrap_cache_filesystem('LocalFileSystem');"
        echo ".bail on"
        # No result rows: the OSv app only prints them under TPCH_PRINT=1.
        echo ".mode trash"
        echo ".timer on"
        for _ in $(seq {{REPEAT}}); do
            cat "{{proot}}/osv/benchmarks/duckdb/tpch/q{{query}}.sql"
        done
        # Timer off first, or the COPY emits a Run Time line the parser would read as
        # one more repetition.
        echo ".timer off"
        echo "COPY (SELECT * FROM cache_httpfs_cache_access_info_query()) TO '/root/benchmarks/results/cachefs_access_q{{query}}.csv' (FORMAT CSV, HEADER);"
    } > "{{results_dir}}/cachefs_workload_q{{query}}.sql"
    if [ "{{CHUNKING}}" = "column_chunk" ]; then
        echo "!! CHUNKING=column_chunk also needs cache_httpfs_register_parquet_layout()" >&2
        echo "!! per file, which this harness does not emit. Files without a registered" >&2
        echo "!! layout silently fall back to fixed blocks." >&2
    fi

compare:
    just -f {{self}} ucache
    just -f {{self}} cachefs

# Cache size as a % of the dataset, both legs, over CACHE_PCTS.
sweep:
    #!/usr/bin/env bash
    set -euo pipefail
    for pct in {{CACHE_PCTS}}; do
        CACHE_PCT="$pct" just -f {{self}} compare
    done

plot:
    cd {{proot}}/benchmarks/plots && python3 cachefs_compare.py

# One fresh OSv boot per query, REPEAT repetitions inside it.
ucache:
    #!/usr/bin/env bash
    set -uo pipefail
    # Ctrl-C aborts the sweep; it reaches this shell only while it sits in `wait` below.
    trap 'echo "    !! interrupted - now: pkill qemu-system"; exit 130' INT
    RF="{{result_file}}"; mkdir -p "{{results_dir}}"
    [ -f "$RF" ] || echo "{{header}}" > "$RF"
    cache=$(just -f {{self}} _cache_bytes) || exit 1
    cfg=$(just -f {{self}} _cfg ucache "$cache")
    mem=$(just -f {{self}} _vm_mem) || exit 1

    echo "==> [ucache] {{REPEAT}}x each of {{QUERIES}} (cache=$((cache / 1024 / 1024))MiB = {{CACHE_PCT}}%, mem=$mem)"
    for q in {{QUERIES}}; do
        if [ "{{RESUME}}" = "true" ] && just -f {{self}} _done ucache "$q" 2>/dev/null; then
            echo "    -- q$q already recorded, skipping"
            continue
        fi
        echo "==> [ucache] q$q"
        # </dev/null is needed: `timeout` puts QEMU in its own process group, where
        # touching the controlling tty stops it on SIGTTIN. Log to a file, not a
        # variable, so a long query still prints and a Ctrl-C keeps what it wrote.
        log="{{results_dir}}/ucache_run.log"
        # Backgrounded and waited on: a foreground child holds the INT trap until it
        # returns, and this one never sees the Ctrl-C itself.
        timeout {{TIMEOUT_S}} bash -c \
            "cd {{proot}}/osv && just run-duckdb ${q#0} {{REPEAT}} $mem {{THREADS}} $cache {{DDB_MEM}} {{EVICT_BATCH}} {{PREFETCH_BATCH}} '' {{LATENCY_US}} {{BANDWIDTH}}" \
            > "$log" 2>&1 </dev/null &
        wait $!
        rc=$?
        if [ $rc -ne 0 ]; then
            [ $rc -eq 124 ] && st=TIMEOUT || st=FAIL
            echo "$cfg,$q,1,$st,na,na,na,na,na" >> "$RF"
            cp "$log" "{{results_dir}}/failed_ucache_q$q.log"
            echo "    !! q$q $st, see failed_ucache_q$q.log"
            continue
        fi
        # A run can also FAIL while exiting 0, in which case no @@ROW lines appear.
        n=$(gawk -f {{parse}}/osv_rows.awk "$log" \
            | gawk -F, -v pre="$cfg" '{ print pre "," $0 }' | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "$cfg,$q,1,ERROR,na,na,na,na,na" >> "$RF"
            cp "$log" "{{results_dir}}/failed_ucache_q$q.log"
            echo "    !! q$q produced no @@ROW lines, rebuild the OSv image (just build-duckdb), or see failed_ucache_q$q.log"
        elif [ "$n" -lt {{REPEAT}} ]; then
            echo "    !! q$q produced only $n of {{REPEAT}} repetitions"
        fi
        just check_downgraded_link || true
    done

# One guest boot for all queries, then a fresh duckdb process per query: the in_mem
# cache lives in the process, and drop os file caches between runs.
cachefs:
    #!/usr/bin/env bash
    set -uo pipefail
    # Ctrl-C aborts the sweep; it reaches this shell only while it sits in `wait` below.
    trap 'echo "    !! interrupted - now: pkill qemu-system"; exit 130' INT
    RF="{{result_file}}"; AF="{{access_file}}"; mkdir -p "{{results_dir}}"
    [ -f "$RF" ] || echo "{{header}}" > "$RF"
    [ -f "$AF" ] || echo "{{acc_header}}" > "$AF"
    cache=$(just -f {{self}} _cache_bytes) || exit 1
    cfg=$(just -f {{self}} _cfg cachefs "$cache")

    # Nothing to do is worth knowing before spending a minute on a VM boot.
    todo=""
    for q in {{QUERIES}}; do
        if [ "{{RESUME}}" = "true" ] && just -f {{self}} _done cache_httpfs "$q" 2>/dev/null; then
            echo "    -- q$q already recorded, skipping"
        else
            todo="$todo $q"
        fi
    done
    [ -n "$todo" ] || exit 0

    linux_mem="{{LINUX_MEM}}"; [ -n "$linux_mem" ] || linux_mem=$(just -f {{self}} _vm_mem)
    echo "==> [cache_httpfs] {{REPEAT}}x each of$todo (cache=$((cache / 1024 / 1024))MiB = {{CACHE_PCT}}%, mem=$linux_mem)"
    # </dev/null on every VM/ssh call: see the note in ucache.
    # Keep qemu's stderr: it is the only place a VFIO/memlock failure is reported.
    just linux_vm {{THREADS}} "$linux_mem" > "{{results_dir}}/linux_vm.log" 2>&1 < /dev/null &
    # Poll for sshd rather than sleeping: a cold boot runs fsck long before sshd is up.
    booted=0
    for _ in $(seq 60); do
        just ssh true < /dev/null > /dev/null 2>&1 && { booted=1; break; }
        sleep 5
    done
    if [ "$booted" -ne 1 ]; then
        echo "    !! guest never came up, see {{results_dir}}/linux_vm.log"
        just check_downgraded_link || true
        exit 0
    fi
    # -o ro as osv/justfile run-duckdb-linux does: a rw mount would write atime back
    # to the disk under test.
    just ssh "mkdir -p /nvme; mount -o ro /dev/nvme0n1 /nvme" < /dev/null || true

    for q in $todo; do
        echo "==> [cache_httpfs] q$q"
        rm -f "{{results_dir}}/cachefs_access_q$q.csv"
        just -f {{self}} _script "$q" "$cache" || continue
        # A fresh process per query, so the in_mem cache starts empty; drop_caches so
        # the guest page cache does too.
        just ssh "echo 3 > /proc/sys/vm/drop_caches" < /dev/null > /dev/null 2>&1 || true
        # The repo root is 9p-mounted at /root in the guest, so the script generated on
        # the host is readable there directly. Capture first, then parse, so the output
        # of a run that died is kept. -cmd, not -c: -c exits without reading stdin.
        log="{{results_dir}}/cachefs_run.log"
        # Backgrounded and waited on: a foreground child holds the INT trap.
        timeout {{TIMEOUT_S}} just ssh \
            "duckdb -init /dev/null -cmd 'set enable_progress_bar = false' < /root/benchmarks/results/cachefs_workload_q$q.sql" \
            < /dev/null > "$log" 2>&1 &
        wait $!
        rc=$?
        if [ $rc -eq 124 ]; then
            echo "$cfg,$q,1,TIMEOUT,na,na,na,na,na" >> "$RF"
            cp "$log" "{{results_dir}}/failed_cachefs_q$q.log"
            echo "    !! q$q TIMEOUT, see failed_cachefs_q$q.log"
            continue
        fi
        n=$(gawk -v q="$q" -f {{parse}}/duckdb_rows.awk "$log" \
            | gawk -F, -v pre="$cfg" '{ print pre "," $0 }' | tee -a "$RF" | wc -l)
        if [ "$n" -eq 0 ]; then
            echo "$cfg,$q,1,ERROR,na,na,na,na,na" >> "$RF"
            cp "$log" "{{results_dir}}/failed_cachefs_q$q.log"
            echo "    !! q$q produced no timings (rc=$rc), see failed_cachefs_q$q.log"
            continue
        fi
        [ "$n" -lt {{REPEAT}} ] && echo "    !! q$q produced only $n of {{REPEAT}} repetitions"
        # Process-wide hit/miss totals for this query, so kept out of the per-rep rows.
        af="{{results_dir}}/cachefs_access_q$q.csv"
        [ -e "$af" ] && gawk -F, -v pre="$cfg,$q" 'NR>1 { print pre "," $1 "," $2 "," $3 "," $4 }' "$af" >> "$AF"
    done

    just ssh "poweroff" > /dev/null 2>&1 < /dev/null || true
    sleep 20
    just check_downgraded_link || true

# Cache entry size. cache_httpfs only: uCache faults at mmu::page_size and has no
# BLOCK_SIZE counterpart today.
block_sizes := env("BLOCK_SIZES", "131072 262144 524288 1048576 2097152 4194304")
sweep-block-size:
    #!/usr/bin/env bash
    set -euo pipefail
    for bs in {{block_sizes}}; do
        BLOCK_SIZE="$bs" just -f {{self}} cachefs
    done

# Simulated remote penalty, as latency_us:bandwidth_gbps pairs. cache_httpfs only
# until uCache gets a matching charge.
penalties := env("PENALTIES", "1400:0.7 10000:0.5 40000:0.5")
sweep-penalty:
    #!/usr/bin/env bash
    set -euo pipefail
    for pen in {{penalties}}; do
        LATENCY_US="${pen%%:*}" BANDWIDTH="${pen##*:}" just -f {{self}} cachefs
    done

# Eviction policy. cache_httpfs only: uCache uses duckdb_evict_policy, which is not
# selectable at runtime.
policies_list := env("POLICIES", "lru fifo clock mru")
sweep-policy:
    #!/usr/bin/env bash
    set -euo pipefail
    for p in {{policies_list}}; do
        POLICY="$p" just -f {{self}} cachefs
    done

clean-results:
    rm -f {{result_file}} {{access_file}} {{results_dir}}/cachefs_access_q*.csv \
          {{results_dir}}/cachefs_workload_q*.sql {{results_dir}}/failed_cachefs_q*.log \
          {{results_dir}}/failed_ucache_q*.log
