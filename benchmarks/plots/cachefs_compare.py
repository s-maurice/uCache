#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Plot results/cachefs_compare.csv: Linux+cache_httpfs vs OSv+uCache.
# cachefs_compare.pdf: per-query runtime, 4 bars/query (each system: cold, warm).
# cachefs_sweep.pdf: total runtime and ratio vs cache_pct.
# cachefs_compare_diag.pdf: uCache prefetch coverage and cache_httpfs hit ratio.
from matplotlib.patches import Patch
from common import *

COLD_ALPHA = 0.55

CSV = os.path.join(result_dir, "cachefs_compare.csv")
ACCESS_CSV = os.path.join(result_dir, "cachefs_access.csv")

SYSTEM_ORDER = ["cache_httpfs", "ucache"]
HATCH = {"cache_httpfs": hatch_def[2], "ucache": hatch_def[1]}
COLORS = {"cache_httpfs": palette[0], "ucache": palette[1]}
KEY = ["system", "scale", "cache_pct", "query", "repetition"]

NUMERIC = ["time", "metadata_time", "read_bytes", "prefetch_used", "peak_used",
           "min_huge_blocks", "cache_bytes", "cache_pct", "repetition",
           "evict_batch", "prefetch_batch", "block_size"]


def load_data(path=CSV) -> pd.DataFrame:
    df = pd.read_csv(path)
    # FAIL / TIMEOUT / ERROR / "na" -> NaN, so a dead run is a missing bar, not a 0.
    for col in NUMERIC:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    # Append-only file: keep the newest row per key so a re-run is not averaged
    # together with the rows it supersedes.
    dup = df.duplicated(KEY, keep="last")
    if dup.any():
        print(f"note: dropped {dup.sum()} superseded row(s) from re-runs")
        df = df[~dup]
    df["query"] = df["query"].astype(str).str.zfill(2)
    # SF10 and SF100 rows are not comparable. Keep whichever scale dominates the file.
    scales = df["scale"].value_counts()
    if len(scales) > 1:
        keep = scales.index[0]
        print(f"note: {len(scales)} scales in the file {list(scales.index)}; "
              f"plotting {keep} only")
        df = df[df["scale"] == keep]
    return df


def split_reps(df):
    """(cold, warm): rep 1, and the median of reps 2..N (empty if REPEAT was 1)."""
    cold = df[df["repetition"] == 1]
    warm = df[df["repetition"] >= 2]
    if len(warm):
        warm = (warm.groupby(["system", "cache_pct", "query"], as_index=False)
                    .agg({"time": "median", "read_bytes": "median",
                          "prefetch_used": "median"}))
    return cold, warm


def _style(ax):
    ax.tick_params(labelsize=FONTSIZE - 1)
    ax.set_axisbelow(True)


def plot_runtime(cold, warm):
    """Per-query bars, one panel per cache_pct, 4 bars/query: each system's
    cold bar next to its warm bar, grouped by system in SYSTEM_ORDER."""
    cold = cold.assign(style="cold")
    warm = warm.assign(style="warm")
    df = pd.concat([cold, warm], ignore_index=True)
    if not len(df):
        print("note: no repetitions; skipping cachefs_compare.pdf")
        return
    df["label"] = df["system"] + " " + df["style"]
    order = [f"{s} {st}" for s in SYSTEM_ORDER for st in ("cold", "warm")]
    present = [l for l in order if l in set(df["label"])]
    pcts = sorted(df["cache_pct"].unique())
    fig, axes = plt.subplots(len(pcts), 1, sharex=True, squeeze=False,
                             figsize=(figwidth_full, (fig_height + 0.5) * len(pcts)))
    for ax, pct in zip(axes.flat, pcts):
        sub = df[df["cache_pct"] == pct]
        sns.barplot(data=sub, x="query", y="time", hue="label", hue_order=present,
                    palette=[COLORS[l.split()[0]] for l in present],
                    edgecolor="black", linewidth=0.5, ax=ax, legend=False)
        for bars, l in zip(ax.containers, present):
            system, style = l.split()
            for b in bars:
                b.set_hatch(HATCH[system])
                if style == "cold":
                    b.set_alpha(COLD_ALPHA)
        ax.set_ylabel("Time (s)")
        ax.set_title(f"cache = {pct:g}% of dataset", fontsize=FONTSIZE)
        _style(ax)
    axes.flat[-1].set_xlabel("TPC-H query")
    fig.suptitle("cache_httpfs vs uCache, cold vs warm, " + lower_better_str,
                 fontsize=FONTSIZE, color="navy", y=1.05)
    fig.tight_layout()
    handles = [Patch(facecolor=COLORS[l.split()[0]], edgecolor="black",
                      hatch=HATCH[l.split()[0]],
                      alpha=(COLD_ALPHA if l.split()[1] == "cold" else 1.0), label=l)
               for l in present]
    fig.legend(handles=handles, ncol=len(handles), frameon=False,
               fontsize=FONTSIZE, loc="lower center", bbox_to_anchor=(0.5, 1.0))
    out = os.path.join(result_dir, "cachefs_compare.pdf")
    fig.savefig(out, format="pdf", bbox_inches="tight")
    print("wrote", out)


def _totals(df):
    """Total time per (system, cache_pct), over the queries both systems ran
    everywhere: summing what is present would reward a system for its failures."""
    t = df.pivot_table(index=["cache_pct", "query"], columns="system", values="time")
    if not {"ucache", "cache_httpfs"} <= set(t.columns):
        return None, 0
    t = t.dropna()
    per_pct = t.groupby(level="query").size()
    common = per_pct[per_pct == t.index.get_level_values("cache_pct").nunique()].index
    t = t[t.index.get_level_values("query").isin(common)]
    return t.groupby(level="cache_pct").sum(), len(common)


def plot_sweep(cold, warm):
    """Total runtime against cache size, the point of the CACHE_PCTS sweep."""
    fig, (a1, a2) = plt.subplots(2, 1, sharex=True,
                                 figsize=(figwidth_half, (fig_height + 0.4) * 2))
    drawn = False
    pcts = sorted(set(cold["cache_pct"]) | set(warm["cache_pct"]))
    for j, (style, df, ls) in enumerate((("cold", cold, "-"), ("warm", warm, "--"))):
        tot, n = _totals(df) if len(df) else (None, 0)
        if tot is None or len(tot) < 2:
            continue
        drawn = True
        for i, s in enumerate(SYSTEM_ORDER):
            a1.plot(tot.index, tot[s], ls, marker=marker_def[i], color=COLORS[s],
                    markersize=3, label=f"{s} ({style}, n={n})")
        a2.plot(tot.index, tot["ucache"] / tot["cache_httpfs"], ls,
                marker=marker_def[j], color=COLORS["ucache"], markersize=3, label=style)
    if not drawn:
        print("note: need both systems at 2+ cache_pcts for the sweep; skipping")
        plt.close(fig)
        return
    # Log x (1..100% spans two decades) but ticked at the points actually measured,
    # not at the decades.
    a1.set_xscale("log")
    a1.set_xticks(pcts)
    a1.xaxis.set_major_formatter(ticker.ScalarFormatter())
    a1.xaxis.set_minor_locator(ticker.NullLocator())
    a1.set_ylabel("Total time (s)")
    a1.set_title("Query-set runtime vs cache size, " + lower_better_str,
                 fontsize=FONTSIZE)
    a1.legend(fontsize=FONTSIZE - 1)
    _style(a1)
    a2.axhline(1.0, color="black", linewidth=0.8)
    a2.set_ylabel("uCache / cache_httpfs")
    a2.set_xlabel("Cache size (% of dataset)")
    a2.set_title("Slowdown factor, 1.0 = parity", fontsize=FONTSIZE)
    a2.legend(fontsize=FONTSIZE - 1)
    _style(a2)
    fig.tight_layout()
    out = os.path.join(result_dir, "cachefs_sweep.pdf")
    fig.savefig(out, format="pdf", bbox_inches="tight")
    print("wrote", out)


def _hit_ratio():
    """cache_httpfs hit ratio per (cache_pct, query), from the access-info dump."""
    if not os.path.exists(ACCESS_CSV):
        return None
    a = pd.read_csv(ACCESS_CSV)
    for c in ["cache_pct", "cache_hit_count", "cache_miss_count"]:
        a[c] = pd.to_numeric(a[c], errors="coerce")
    a["query"] = a["query"].astype(str).str.zfill(2)
    g = a.groupby(["cache_pct", "query"])[["cache_hit_count", "cache_miss_count"]].sum()
    total = g["cache_hit_count"] + g["cache_miss_count"]
    return (100 * g["cache_hit_count"] / total.replace(0, np.nan))


def plot_diagnostics(df):
    """Prefetch coverage and hit ratio at the largest cache_pct measured, as
    stacked panels sharing the query axis since the scales differ."""
    pct = sorted(df["cache_pct"].unique())[-1]
    sub = df[df["cache_pct"] == pct]
    u = sub[sub["system"] == "ucache"].set_index("query")
    if not len(u):
        print("note: no uCache rows for the diagnostics panel; skipping")
        return
    cov = 100 * u["prefetch_used"] / u["read_bytes"]

    fig, (a1, a2) = plt.subplots(2, 1, sharex=True,
                                 figsize=(figwidth_full, (fig_height + 0.4) * 2))
    a1.bar(cov.index, cov, color=COLORS["ucache"], edgecolor="black",
           linewidth=0.5, hatch=HATCH["ucache"])
    a1.set_ylabel("Prefetch coverage (%)")
    a1.set_title(f"uCache bytes arriving via prefetch (cache = {pct:g}%), the rest "
                 "demand-fault one page per request", fontsize=FONTSIZE)
    _style(a1)

    hits = _hit_ratio()
    if hits is not None and pct in hits.index.get_level_values("cache_pct"):
        h = hits.xs(pct, level="cache_pct").reindex(cov.index)
        a2.bar(h.index, h, color=COLORS["cache_httpfs"], edgecolor="black",
               linewidth=0.5, hatch=HATCH["cache_httpfs"])
        a2.set_title("cache_httpfs block hit ratio, same point", fontsize=FONTSIZE)
    else:
        a2.set_title("cache_httpfs hit ratio: no cachefs_access.csv rows at this "
                     "cache_pct", fontsize=FONTSIZE)
    a2.set_ylabel("Hit ratio (%)")
    a2.set_xlabel("TPC-H query")
    _style(a2)

    fig.tight_layout()
    out = os.path.join(result_dir, "cachefs_compare_diag.pdf")
    fig.savefig(out, format="pdf", bbox_inches="tight")
    print("wrote", out)


def main():
    df = load_data()
    present = set(df["system"])
    missing = [s for s in SYSTEM_ORDER if s not in present]
    if missing:
        print("WARNING: no rows for " + ", ".join(missing) + ", absent, not equal")

    df = df.dropna(subset=["time"])
    cold, warm = split_reps(df)
    plot_runtime(cold, warm)
    plot_sweep(cold, warm)
    plot_diagnostics(warm if len(warm) else cold)

    # Console summary over the queries both systems actually ran.
    for style, d in (("cold", cold), ("warm", warm)):
        for pct, grp in d.groupby("cache_pct"):
            t = grp.pivot_table(index="query", columns="system", values="time").dropna()
            if {"ucache", "cache_httpfs"} <= set(t.columns) and len(t):
                print(f"{style} cache_pct={pct:g}: uCache {t['ucache'].sum():.1f}s  "
                      f"cache_httpfs {t['cache_httpfs'].sum():.1f}s  "
                      f"ratio {t['ucache'].sum() / t['cache_httpfs'].sum():.2f}x  (n={len(t)})")


if __name__ == "__main__":
    main()
