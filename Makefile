# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
# GW230529 BH-NS Einstein Toolkit -- AWS infrastructure
# =====================================================
# Run `make help` for the list of targets.
# Functionality is split across sub-makefiles under makefiles/.

.DEFAULT_GOAL := help

include makefiles/tf.mk
include makefiles/post.mk

.PHONY: help
help: ## Show this help
	@echo "GW230529 AWS infrastructure -- available targets:"
	@echo ""
	@awk 'BEGIN{FS=":.*?## "} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z0-9_%.-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo "Stack names: bootstrap, foundation, compute"
	@echo ""
