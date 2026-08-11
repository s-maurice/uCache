#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Plot results/duckdb_compare.csv: Linux DuckDB vs OSv+uCache, one plot per
# memory-fit and style, into duckdb_compare.pdf (runtime) and
# duckdb_compare_io.pdf (uCache read_bytes).
from common import *

CSV = os.path.join(result_dir, "duckdb_compare.csv")


def config_label(system, variant):
    return f"{system}/{variant}"

CONFIG_ORDER = ["duckdb/na", "ucache/without", "ucache/with"]


def load_data() -> pd.DataFrame:
    df = pd.read_csv(CSV)
    # OOM / non-numeric timings -> NaN (missing bar); bytes likewise.
    for col in ["time", "metadata_time", "read_bytes", "prefetch_used", "peak_used", "min_huge_blocks"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    df["config"] = [config_label(s, v) for s, v in zip(df["system"], df["variant"])]
    # The CSV is append-only: keep the newest row per key so a re-run is not
    # averaged together with the rows it supersedes.
    key = ["system", "variant", "memfit", "style", "query", "repetition"]
    dup = df.duplicated(key, keep="last")
    if dup.any():
        print(f"note: dropped {dup.sum()} superseded row(s) from re-run legs")
        df = df[~dup]
    # Warm: drop the cold first repetition; cold: keep its single rep.
    df = df[(df["style"] == "cold") | (df["repetition"] > 1)]
    # zero-pad query for stable ordering on the x-axis
    df["query"] = df["query"].astype(str).str.zfill(2)
    return df


def facet_bar(data, y, ylabel, outfile, title):
    g = sns.catplot(
        data=data, kind="bar",
        x="query", y=y, hue="config",
        hue_order=[c for c in CONFIG_ORDER if c in data["config"].unique()],
        row="memfit", col="style",
        row_order=[m for m in ["fits", "nofit"] if m in data["memfit"].unique()],
        col_order=[s for s in ["cold", "warm"] if s in data["style"].unique()],
        errorbar="sd", edgecolor="black",
        height=fig_height + 0.6, aspect=3.2, legend_out=False,
    )
    g.set_axis_labels("Query", ylabel)
    g.set_titles("{row_name} / {col_name}")
    for ax in g.axes.flat:
        ax.tick_params(labelsize=FONTSIZE - 1)
        # annotate empty (OOM / missing) bars
        for bar in ax.patches:
            if np.isnan(bar.get_height()) or bar.get_height() == 0:
                ax.annotate("×", (bar.get_x() + bar.get_width() / 2, 0),
                            ha="center", va="bottom", color="red",
                            fontsize=FONTSIZE - 2, weight="bold")
    if g.legend is not None:
        g.legend.set_title(None)
    g.figure.suptitle(title, fontsize=FONTSIZE, color="navy", y=1.02)
    g.tight_layout()
    out = os.path.join(result_dir, outfile)
    g.savefig(out, format="pdf", bbox_inches="tight")
    print("wrote", out)


def main():
    data = load_data()

    # Warn when a config has no rows, since it plots the same as no difference.
    present = set(data["config"])
    missing = [c for c in CONFIG_ORDER if c not in present]
    if missing:
        print("WARNING: no rows for " + ", ".join(missing) + ", those series are absent, not equal")
    for (mf, st), grp in data.groupby(["memfit", "style"]):
        absent = [c for c in CONFIG_ORDER if c in present and c not in set(grp["config"])]
        if absent:
            print(f"WARNING: {mf}/{st} is missing " + ", ".join(absent))

    # 1) runtime, all configs
    facet_bar(data, "time", "Time (s)", "duckdb_compare.pdf",
              "duckdb/na vs ucache/without vs ucache/with, " + lower_better_str)

    # 2) IO volume, uCache configs only (DuckDB has no read_bytes)
    io = data[(data["system"] == "ucache") & data["read_bytes"].notna()].copy()
    if not io.empty:
        io["read_gib"] = io["read_bytes"] / (1024 ** 3)
        facet_bar(io, "read_gib", "read_bytes (GiB)", "duckdb_compare_io.pdf",
                  "uCache IO per query, " + lower_better_str)

    # quick console summary, per memfit/style, over the queries each pair shares
    piv = (data.dropna(subset=["time"])
               .groupby(["memfit", "style", "config", "query"])["time"].mean()
               .reset_index())
    for (mf, st), grp in piv.groupby(["memfit", "style"]):
        series = {c: g.set_index("query")["time"] for c, g in grp.groupby("config")}
        for num, den in [("ucache/without", "ucache/with"), ("duckdb/na", "ucache/with")]:
            if num in series and den in series:
                common_q = series[num].index.intersection(series[den].index)
                if len(common_q):
                    ratio = (series[num].loc[common_q] / series[den].loc[common_q]).mean()
                    print(f"{mf}/{st}: mean {num} / {den} = {ratio:.2f}x  (n={len(common_q)})")


if __name__ == "__main__":
    main()
