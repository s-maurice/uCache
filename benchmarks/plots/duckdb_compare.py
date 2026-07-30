#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Plot results/duckdb_compare.csv: Linux DuckDB vs OSv+uCache, one plot per
# memory-fit and style, into duckdb_compare.pdf (runtime) and
# duckdb_compare_io.pdf (uCache read_bytes).
from common import *

CSV = os.path.join(result_dir, "duckdb_compare.csv")

# system+variant -> display config
def config_label(system, variant):
    if system == "duckdb":
        return "DuckDB"
    if system == "ucache" and variant == "with":
        return "uCache (with)"
    if system == "ucache" and variant == "without":
        return "uCache (base)"
    return f"{system}/{variant}"

CONFIG_ORDER = ["DuckDB", "uCache (base)", "uCache (with)"]


def load_data() -> pd.DataFrame:
    df = pd.read_csv(CSV)
    # OOM / non-numeric timings -> NaN (missing bar); bytes likewise.
    for col in ["time", "read_bytes", "prefetch_used", "peak_used", "min_huge_blocks"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    df["config"] = [config_label(s, v) for s, v in zip(df["system"], df["variant"])]
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

    # 1) runtime, all configs
    facet_bar(data, "time", "Time (s)", "duckdb_compare.pdf",
              "DuckDB vs uCache (with/without), " + lower_better_str)

    # 2) IO volume, uCache configs only (DuckDB has no read_bytes)
    io = data[(data["system"] == "ucache") & data["read_bytes"].notna()].copy()
    if not io.empty:
        io["read_gib"] = io["read_bytes"] / (1024 ** 3)
        facet_bar(io, "read_gib", "read_bytes (GiB)", "duckdb_compare_io.pdf",
                  "uCache IO per query, " + lower_better_str)

    # quick console summary: mean speedup uCache(with) vs DuckDB, per memfit/style
    piv = (data.dropna(subset=["time"])
               .groupby(["memfit", "style", "config", "query"])["time"].mean()
               .reset_index())
    for (mf, st), grp in piv.groupby(["memfit", "style"]):
        w = grp[grp.config == "uCache (with)"].set_index("query")["time"]
        d = grp[grp.config == "DuckDB"].set_index("query")["time"]
        common_q = w.index.intersection(d.index)
        if len(common_q):
            ratio = (d.loc[common_q] / w.loc[common_q]).mean()
            print(f"{mf}/{st}: mean DuckDB/uCache(with) speedup = {ratio:.2f}x")


if __name__ == "__main__":
    main()
