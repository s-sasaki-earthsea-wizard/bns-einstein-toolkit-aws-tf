# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Time-series figures: maximum rest-mass density, horizon masses, rest mass.

Three separate figures rather than one with two y-axes -- the quantities have
different scales, and a dual-axis chart invites misreading. Each carries the
coordinate merger time as a reference line so the three can be read side by
side in a talk.
"""

import argparse
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from common import (
    BLUE,
    FIGSIZE,
    GREEN,
    MERGER_TIME,
    VERMILLION,
    apply_style,
    dedup_sorted,
    load_ah_diagnostics,
    load_scalar_asc,
    save,
)


def merger_line(ax):
    ax.axvline(MERGER_TIME, color="0.5", linewidth=1, linestyle="--")
    ax.annotate(
        "merger",
        xy=(MERGER_TIME, 1.0),
        xycoords=("data", "axes fraction"),
        xytext=(4, -12),
        textcoords="offset points",
        fontsize=11,
        color="0.35",
    )


def plot_rho_max(datadir, outdir):
    t, rho = load_scalar_asc(f"{datadir}/data/hydrobase-rho.maximum.asc")
    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.semilogy(t, rho, color=BLUE, linewidth=2.0)
    merger_line(ax)
    ax.set_xlabel(r"$t\ [M_\odot]$")
    ax.set_ylabel(r"$\max\ \rho\ [M_\odot^{-2}]$")
    fig.tight_layout()
    save(fig, outdir, "rho_max")


def plot_ah_masses(datadir, outdir):
    fig, ax = plt.subplots(figsize=FIGSIZE)
    # Fixed identity -> fixed color: AH1 is the black hole tracked from t=0,
    # AH2 the post-merger horizon found once the star is swallowed.
    for n, color, label in ((1, BLUE, "AH1 (initial BH)"), (2, VERMILLION, "AH2 (remnant)")):
        path = f"{datadir}/BH/BH_diagnostics.ah{n}.gp"
        if not os.path.exists(path):
            continue
        t, _, _, _, m = load_ah_diagnostics(path)
        ax.plot(t, m, color=color, linewidth=2.0, label=label)
    merger_line(ax)
    ax.set_xlabel(r"$t\ [M_\odot]$")
    ax.set_ylabel(r"$M_\mathrm{irr}\ [M_\odot]$")
    ax.legend(loc="center left", frameon=False)
    fig.tight_layout()
    save(fig, outdir, "ah_masses")


def plot_rest_mass(datadir, outdir):
    # VolumeIntegrals-GRMHD: column 1 is time, column 8 the rest-mass
    # integral over the full grid (see the file's own header). Normalised to
    # its initial value: what remains outside the horizon after merger is the
    # accretion-disk material.
    data = np.loadtxt(f"{datadir}/volume_integration/volume_integrals-GRMHD.asc", ndmin=2)
    t, m = dedup_sorted(data[:, 0], data[:, 7])
    fig, ax = plt.subplots(figsize=FIGSIZE)
    ax.plot(t, m / m[0], color=GREEN, linewidth=2.0)
    merger_line(ax)
    ax.set_xlabel(r"$t\ [M_\odot]$")
    ax.set_ylabel(r"$M_0(t)\,/\,M_0(0)$")
    fig.tight_layout()
    save(fig, outdir, "rest_mass")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/data/run", help="synced run directory")
    ap.add_argument("--out", default="/out", help="output directory")
    args = ap.parse_args()

    apply_style()
    plot_rho_max(args.data, args.out)
    plot_ah_masses(args.data, args.out)
    plot_rest_mass(args.data, args.out)


if __name__ == "__main__":
    main()
