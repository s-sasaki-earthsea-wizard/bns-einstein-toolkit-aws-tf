# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Plot the (l=2, m=2) mode of Psi4 at the outermost extraction radius.

Reads the Multipole thorn's HDF5 output directly (mp_psi4.h5). The ASCII
multipole files of this run are useless for this figure -- they carry the
same 15.36 M sampling but were confused with the reference run's dense ones
once already, so the HDF5 file is the single source here.

Sampling honesty: dt = 15.36 M gives ~7 samples per gravitational-wave cycle
through merger and ~5 in ringdown. The chirp and the peak are resolved; the
ringdown tail is visibly angular. That is a property of the run's Multipole
output cadence, not of this script, and it cannot be improved after the fact.
"""

import argparse

import h5py
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from common import BLUE, FIGSIZE, VERMILLION, apply_style, dedup_sorted, save


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/data/run", help="synced run directory")
    ap.add_argument("--out", default="/out", help="output directory")
    ap.add_argument("--mode", default="l2_m2", help="spherical harmonic mode")
    ap.add_argument(
        "--radius", default=None, help="extraction radius label, e.g. 500.00 (default: outermost)"
    )
    args = ap.parse_args()

    with h5py.File(f"{args.data}/data/mp_psi4.h5", "r") as f:
        radii = sorted(
            {k.rsplit("_r", 1)[1] for k in f.keys() if k.startswith(args.mode + "_r")},
            key=float,
        )
        radius = args.radius or radii[-1]
        d = f[f"{args.mode}_r{radius}"][:]

    t, re, im = dedup_sorted(d[:, 0], d[:, 1], d[:, 2])
    amp = np.hypot(re, im)
    tpk = t[amp.argmax()]

    apply_style()
    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.fill_between(t, -amp, amp, color=VERMILLION, alpha=0.15, linewidth=0)
    ax.plot(t, amp, color=VERMILLION, linewidth=1.2, label=r"$|\Psi_4|$")
    ax.plot(t, re, color=BLUE, linewidth=2.0, label=r"$\mathrm{Re}\,\Psi_4$")
    ax.axvline(tpk, color="0.5", linewidth=1, linestyle="--")
    ax.annotate(
        f"peak $t={tpk:.0f}$",
        xy=(tpk, amp.max()),
        xytext=(6, 0),
        textcoords="offset points",
        fontsize=11,
        color="0.35",
    )
    ax.set_xlabel(r"$t\ [M_\odot]$")
    ax.set_ylabel(rf"$\Psi_4^{{2,2}}$ at $r={float(radius):.0f}\,M_\odot$")
    ax.legend(loc="upper left", frameon=False)
    fig.tight_layout()
    save(fig, args.out, f"psi4_{args.mode}_r{radius}")


if __name__ == "__main__":
    main()
