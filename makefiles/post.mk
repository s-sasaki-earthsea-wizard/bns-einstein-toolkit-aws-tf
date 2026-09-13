# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
# Post-processing targets
# =======================================================
# Figures and the movie for the finished run, produced locally from a synced
# copy of the S3 output. Everything here is read-only towards AWS, so the
# observer profile is enough for the one target that talks to it at all:
#
#   make fetch-results AWS_PROFILE=gw230529-observer
#   make postproc-image
#   make figures
#   make movie
#   make pack-results        # when the figures are done and approved
#
# Local rather than cloud on purpose. The whole run wrote ~10 GB and the
# figures read ~300 MB of it; that is a download, not a reason to ship a
# rendering environment into Lambda or EC2. The analysis runs inside a
# pinned Docker image so the figures reproduce months later; the scripts are
# bind mounted, so editing one never requires an image rebuild.

POSTPROC_IMAGE ?= gw230529-postproc:local
RESULTS_ROOT := results

# The run to process: the sole directory under results/, override with
# RUN_NAME=... when more than one run has been fetched.
RUN_NAME ?= $(notdir $(patsubst %/,%,$(firstword $(wildcard $(RESULTS_ROOT)/*/))))

# The container runs as the invoking user so the outputs are not root-owned;
# the two /tmp cache dirs silence matplotlib and fontconfig complaints that
# a read-only home causes.
define POSTPROC_RUN
docker run --rm -u $$(id -u):$$(id -g) \
	-e MPLCONFIGDIR=/tmp -e XDG_CACHE_HOME=/tmp \
	-v $(abspath postprocessing):/app:ro \
	-v $(abspath $(RESULTS_ROOT)/$(RUN_NAME)):/data:ro \
	-v $(abspath postprocessing/out/$(RUN_NAME)):/out \
	-w /app $(POSTPROC_IMAGE)
endef

.PHONY: postproc-preflight
postproc-preflight:
	@test -n "$(RUN_NAME)" || \
		{ echo "no run under $(RESULTS_ROOT)/ -- run make fetch-results first, or set RUN_NAME="; exit 1; }
	@test -d "$(RESULTS_ROOT)/$(RUN_NAME)/run" || \
		{ echo "$(RESULTS_ROOT)/$(RUN_NAME)/run is missing -- is the fetch complete?"; exit 1; }
	@docker image inspect $(POSTPROC_IMAGE) >/dev/null 2>&1 || \
		{ echo "image $(POSTPROC_IMAGE) not found -- run make postproc-image"; exit 1; }
	@mkdir -p postprocessing/out/$(RUN_NAME)

##@ Post-processing

.PHONY: fetch-results
fetch-results: ## Sync the run's output from S3 into results/ (observer profile works)
	@TF="$(TF)" scripts/fetch_results.sh $(ARGS)

.PHONY: postproc-image
postproc-image: ## Build the pinned Docker image the figures are rendered in
	@docker build -t $(POSTPROC_IMAGE) postprocessing

.PHONY: figures
figures: postproc-preflight ## Render the Psi4 waveform and the time-series figures
	@$(POSTPROC_RUN) python plot_psi4.py
	@$(POSTPROC_RUN) python plot_timeseries.py

.PHONY: movie
movie: postproc-preflight ## Render the density frames, movie and 3-panel snapshot (ARGS=--help)
	@$(POSTPROC_RUN) python render_frames.py $(ARGS)

.PHONY: pack-results
pack-results: ## Compress a fetched results tree to tar.gz and delete the tree (asks first)
	@scripts/pack_results.sh $(ARGS)
