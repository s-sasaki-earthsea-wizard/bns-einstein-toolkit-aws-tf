# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Shared style and data-loading helpers for the post-processing figures.

Every script here reads from the synced run directory (``make fetch-results``)
and writes into an output directory; both arrive as CLI arguments with
defaults matching the bind mounts in makefiles/post.mk (/data and /out).

The ASCII readers all deduplicate on the leading iteration/time column. A run
recovered after a spot interruption rewinds to the last checkpoint and
re-emits the iterations it had already written, appending them to the same
file -- the same reason the upstream gallery's join.sh runs its gawk filter.
"""

import numpy as np

# Okabe-Ito colorblind-safe palette, assigned in fixed order (never cycled).
BLUE = "#0072B2"
VERMILLION = "#D55E00"
GREEN = "#009E73"
ORANGE = "#E69F00"

# Coordinate merger time in M_sun, from the production run (CLAUDE.md: the
# Psi4 peak at r=500 arrives at t=1213 M, minus the extraction radius).
MERGER_TIME = 713.0

FIGSIZE = (7.0, 4.2)


def apply_style():
    """Talk-oriented matplotlib defaults: big fonts, recessive grid."""
    import matplotlib

    matplotlib.rcParams.update(
        {
            "font.size": 13,
            "axes.labelsize": 14,
            "axes.titlesize": 14,
            "legend.fontsize": 12,
            "xtick.labelsize": 12,
            "ytick.labelsize": 12,
            "axes.grid": True,
            "grid.alpha": 0.3,
            "grid.linestyle": ":",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "savefig.dpi": 300,
            "savefig.bbox": "tight",
        }
    )


def save(fig, outdir, stem):
    """Save PNG (for slides) and PDF (for anything that scales)."""
    for ext in ("png", "pdf"):
        path = f"{outdir}/{stem}.{ext}"
        fig.savefig(path)
        print(f"wrote {path}")


def dedup_sorted(key, *cols):
    """Sort by key and drop duplicate keys, keeping the first occurrence.

    Recovery re-emits iterations it had already written; the recomputed rows
    are identical, so which duplicate survives does not matter.
    """
    order = np.argsort(key, kind="stable")
    key = key[order]
    keep = np.concatenate(([True], np.diff(key) > 0))
    out = [key[keep]]
    for c in cols:
        out.append(c[order][keep])
    return out


def load_scalar_asc(path):
    """CarpetIOScalar file: columns iteration, time, value."""
    data = np.loadtxt(path, comments="#", ndmin=2)
    it, t, v = data[:, 0], data[:, 1], data[:, 2]
    it, t, v = dedup_sorted(it, t, v)
    return t, v


def load_ah_diagnostics(path):
    """AHFinderDirect BH_diagnostics.ah*.gp.

    Returns time, centroid x, centroid y, mean coordinate radius and
    irreducible mass (columns 2, 3, 4, 8 and 27 of the file, 1-based).
    """
    data = np.loadtxt(path, comments="#", ndmin=2)
    it = data[:, 0]
    it, t, cx, cy, r, m = dedup_sorted(
        it, data[:, 1], data[:, 2], data[:, 3], data[:, 7], data[:, 26]
    )
    return t, cx, cy, r, m
