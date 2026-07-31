import? "../justfile"

# DuckDB comparison harness: Linux guest-VM CLI vs OSv+uCache, for the WITH and
# WITHOUT variants (check out the recorded SHA of the one you want first).
# run-cold/run-warm drive the inner recipes: cold runs each query once, warm 3x.
# All TPC-H queries except 15 (needs a nonexistent revenue.parquet). Run from the
# repo root: just -f benchmarks/duckdb_compare.just run-cold with

self := proot+"/benchmarks/duckdb_compare.just"
result_file := proot+"/benchmarks/results/duckdb_compare.csv"
queries := "01 02 03 04 05 06 07 08 09 10 11 12 13 14 16 17 18 19 20 21 22"
cores := "16"
vcpus := "16"
timeout_s := "300"
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
        if [ $? -ne 0 ]; then
            echo "ucache,{{variant}},{{memfit}},cold,$q,1,OOM,na,na,na,na,na" >> "$RF"
        else
            echo "$out" | gawk -v q="$q" -v variant="{{variant}}" -v mf="{{memfit}}" '
                function tob(v,u){ if(u=="GiB")return v*1073741824; if(u=="MiB")return v*1048576; if(u=="KiB")return v*1024; return v }
                /rows=/ && /time=/ { rep++; split($2,a,"="); t=a[2]/1000.0; split($4,p,"="); peak=tob(p[2],$5); split($6,m,"="); mhb=m[2] }
                /\[metadata\] time=/ { split($2,mt,"="); meta=mt[2]/1000.0 }
                /^read_bytes:/ { rb=tob($2,$3) }
                /^prefetch_used_by_faults:/ { printf "ucache,%s,%s,cold,%s,%d,%.3f,%.3f,%.0f,%.0f,%.0f,%s\n", variant, mf, q, rep, t, meta, rb, tob($2,$3), peak, mhb }
            ' >> "$RF"
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
        if [ $? -ne 0 ]; then
            echo "ucache,{{variant}},{{memfit}},warm,$q,1,OOM,na,na,na,na,na" >> "$RF"
        else
            echo "$out" | gawk -v q="$q" -v variant="{{variant}}" -v mf="{{memfit}}" '
                function tob(v,u){ if(u=="GiB")return v*1073741824; if(u=="MiB")return v*1048576; if(u=="KiB")return v*1024; return v }
                /rows=/ && /time=/ { rep++; split($2,a,"="); t=a[2]/1000.0; split($4,p,"="); peak=tob(p[2],$5); split($6,m,"="); mhb=m[2] }
                /\[metadata\] time=/ { split($2,mt,"="); meta=mt[2]/1000.0 }
                /^read_bytes:/ { rb=tob($2,$3) }
                /^prefetch_used_by_faults:/ { printf "ucache,%s,%s,warm,%s,%d,%.3f,%.3f,%.0f,%.0f,%.0f,%s\n", variant, mf, q, rep, t, meta, rb, tob($2,$3), peak, mhb }
            ' >> "$RF"
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
        just ssh "echo 1 > /proc/sys/vm/drop_caches; rm -f /nvme/db.tmp; duckdb -no-stdin -c 'set enable_progress_bar = false' -c '.timer on' -c '.read /root/osv/benchmarks/duckdb/tpch/q${q}.sql' /nvme/db.tmp" < /dev/null \
            | grep "Run Time" \
            | gawk -v q="$q" -v mf="{{memfit}}" '{printf "duckdb,na,%s,cold,%s,%s,%.3f,na,na,na,na,na\n", mf, q, NR, $5}' >> "$RF"
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
        just ssh "echo 1 > /proc/sys/vm/drop_caches; rm -f /nvme/db.tmp; duckdb -no-stdin -c 'set enable_progress_bar = false' -c '.timer on' -c '.read /root/osv/benchmarks/duckdb/tpch/q${q}_repeat.sql' /nvme/db.tmp" < /dev/null \
            | grep "Run Time" \
            | gawk -v q="$q" -v mf="{{memfit}}" '{printf "duckdb,na,%s,warm,%s,%s,%.3f,na,na,na,na,na\n", mf, q, NR, $5}' >> "$RF"
        sleep 5
    done
    just ssh "poweroff" > /dev/null 2>&1 < /dev/null || true
    sleep 20
    just check_downgraded_link || true
