# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
"""Render the rest-mass density on the orbital plane: frames, movie, panel.

kuibit assembles the eight refinement levels of the CarpetHDF5 output onto a
uniform grid; matplotlib renders each of the 29 stored iterations; ffmpeg
strings the frames into a movie. Apparent horizons are overlaid as circles at
the AHFinderDirect centroid with the mean coordinate radius -- an honest
approximation of a mildly distorted horizon on a global-scale view.

29 frames is all the run wrote (IO::out2D_every = 1024, one frame per
61.44 M) and it cannot be densified after the fact: the checkpoints that
could replay the merger with finer output cadence were pruned by the
two-generation retention long ago. At the default 3 fps the movie runs ~10 s;
the snapshot panel exists because three well-chosen stills often serve a
slide better than a choppy animation.
"""

import argparse
import os
import subprocess

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from kuibit.grid_data import UniformGrid
from kuibit.simdir import SimDir
from matplotlib.colors import LogNorm

from common import MERGER_TIME, apply_style, load_ah_diagnostics


def load_horizons(datadir):
    horizons = []
    for n in (1, 2):
        path = f"{datadir}/BH/BH_diagnostics.ah{n}.gp"
        if os.path.exists(path):
            horizons.append(load_ah_diagnostics(path))
    return horizons


def draw_horizons(ax, horizons, t):
    for th, cx, cy, r, _ in horizons:
        # The horizon exists only while AHFinderDirect reports it; never
        # extrapolate a circle beyond the last row.
        if t < th[0] - 1e-9 or t > th[-1] + 1e-9:
            continue
        x = np.interp(t, th, cx)
        y = np.interp(t, th, cy)
        rad = np.interp(t, th, r)
        ax.add_patch(plt.Circle((x, y), rad, facecolor="black", edgecolor="white", linewidth=0.8))


def render(ax, rho, it, grid, horizons, vmin, vmax):
    data = rho.read_on_grid(it, grid)
    t = rho.time_at_iteration(it)
    x, y = data.coordinates_from_grid()
    # rasterized keeps the PDF panel small: the 800^2 mesh embeds as an
    # image while axes and labels stay vector. Without it the panel PDF
    # carries three full vector meshes and lands north of 30 MB.
    im = ax.pcolormesh(
        x,
        y,
        np.clip(data.data.T, vmin, None),
        cmap="inferno",
        norm=LogNorm(vmin=vmin, vmax=vmax),
        rasterized=True,
    )
    draw_horizons(ax, horizons, t)
    ax.set_aspect("equal")
    ax.set_xlabel(r"$x\ [M_\odot]$")
    ax.set_ylabel(r"$y\ [M_\odot]$")
    ax.set_title(rf"$t = {t:.0f}\ M_\odot$")
    ax.grid(False)
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="/data/run", help="synced run directory")
    ap.add_argument("--out", default="/out", help="output directory")
    ap.add_argument("--extent", type=float, default=80.0, help="half-width of the view in M_sun")
    ap.add_argument("--points", type=int, default=800, help="resampling grid points per axis")
    ap.add_argument("--vmin", type=float, default=1e-11, help="density colour floor")
    ap.add_argument("--vmax", type=float, default=2e-3, help="density colour ceiling")
    ap.add_argument("--fps", type=int, default=3, help="movie frame rate")
    ap.add_argument(
        "--panel-iterations",
        default=None,
        help="comma-separated iterations for the 3-panel snapshot "
        "(default: first, nearest to merger, last)",
    )
    args = ap.parse_args()

    apply_style()
    sd = SimDir(args.data)
    rho = sd.gridfunctions.xy["rho"]
    iterations = sorted(rho.available_iterations)
    horizons = load_horizons(args.data)
    grid = UniformGrid(
        [args.points, args.points],
        x0=[-args.extent, -args.extent],
        x1=[args.extent, args.extent],
    )

    framedir = f"{args.out}/frames"
    os.makedirs(framedir, exist_ok=True)
    for i, it in enumerate(iterations):
        fig, ax = plt.subplots(figsize=(6.4, 5.4))
        im = render(ax, rho, it, grid, horizons, args.vmin, args.vmax)
        fig.colorbar(im, ax=ax, label=r"$\rho\ [M_\odot^{-2}]$", pad=0.02)
        fig.tight_layout()
        path = f"{framedir}/rho_{i:04d}.png"
        fig.savefig(path, dpi=150)
        plt.close(fig)
        print(f"wrote {path} (iteration {it})")

    movie = f"{args.out}/rho_xy.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-framerate", str(args.fps),
            "-i", f"{framedir}/rho_%04d.png",
            # yuv420p needs even dimensions; pad by at most one pixel.
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-pix_fmt", "yuv420p", "-vcodec", "libx264", "-crf", "22",
            movie,
        ],
        check=True,
    )
    print(f"wrote {movie}")

    if args.panel_iterations:
        panel_its = [int(s) for s in args.panel_iterations.split(",")]
    else:
        times = np.array([rho.time_at_iteration(it) for it in iterations])
        panel_its = [
            iterations[0],
            iterations[int(np.abs(times - MERGER_TIME).argmin())],
            iterations[-1],
        ]

    fig, axes = plt.subplots(1, 3, figsize=(15, 5.2), sharey=True)
    for ax, it in zip(axes, panel_its):
        im = render(ax, rho, it, grid, horizons, args.vmin, args.vmax)
    for ax in axes[1:]:
        ax.set_ylabel("")
    fig.colorbar(im, ax=axes, label=r"$\rho\ [M_\odot^{-2}]$", pad=0.01, fraction=0.03)
    path_stem = f"{args.out}/rho_panel"
    for ext in ("png", "pdf"):
        fig.savefig(f"{path_stem}.{ext}", dpi=300)
        print(f"wrote {path_stem}.{ext}")


if __name__ == "__main__":
    main()
