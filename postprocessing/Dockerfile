# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Post-processing environment for the GW230529 run output.
#
# Dependencies only -- the analysis scripts are bind mounted at run time by
# the make targets, so editing a script never requires a rebuild. The image
# exists because the figures for a talk must be reproducible months later on
# any machine with Docker, not because the tools are exotic: kuibit for
# reading CarpetHDF5 grid data (assembling refinement levels by hand is real
# work), matplotlib for the figures, ffmpeg for the movie.
#
# kuibit rather than VisIt, although the upstream gallery renders its movie
# with VisIt: a multi-GB GUI-oriented install for 29 frames of 2D data is the
# wrong trade, and the gallery itself already uses kuibit for the Psi4 plot.

FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Version pins: the figures for the talk must not change under a silent
# upgrade between two invocations months apart.
RUN pip install --no-cache-dir \
    kuibit==1.5.1 \
    matplotlib==3.10.5 \
    h5py==3.14.0

WORKDIR /app
