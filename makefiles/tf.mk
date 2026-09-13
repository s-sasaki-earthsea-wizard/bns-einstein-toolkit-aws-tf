# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
# Terraform targets
# =======================================================
# Three stacks with different lifetimes:
#
#   bootstrap   the state bucket. Applied once, then left alone.
#   foundation  VPC, data bucket, ECR, IAM, budgets. Months. Idle cost ~0.
#   compute     the spot instance. Created for a run, destroyed after.
#
# Ordinary flow:  make setup -> check-permissions -> bootstrap -> foundation
#                 -> check-alerts -> push-image -> fetch-inputs
#                 -> upload-inputs -> run -> ssm -> stop
#
# Everything that talks to AWS needs a session first:
#
#   eval "$(make login)"
#
# which assumes the operator role with MFA and puts the temporary credentials
# in the environment. Terraform cannot prompt for an MFA token itself. The
# offline targets -- fmt, validate, check-secrets, check -- need no session.
#
# Watching a run needs no session either. The read-only targets run against
# the observer profile, which is assumed without MFA:
#
#   make throughput AWS_PROFILE=gw230529-observer
#   make heartbeat  AWS_PROFILE=gw230529-observer
#   make validate-run AWS_PROFILE=gw230529-observer
#   make ledger       AWS_PROFILE=gw230529-observer
#
# A command line variable is the reliable way to pass it, because the include
# below would otherwise override the environment -- but see the unexport just
# after it, which is why this has to be a shell with no operator session in
# it.

# Load .env when present (AWS_PROFILE, AWS_REGION, scout settings).
ifneq (,$(wildcard .env))
include .env
export
endif

# A session from `make login` has to win over the profile in .env.
#
# Without this, every recipe gets AWS_PROFILE re-exported underneath the
# temporary credentials, and the SDK goes back to resolving that profile --
# which means assuming the operator role by itself, which it cannot do,
# because it cannot prompt for an MFA token. The eval would appear to succeed
# and the very next make target would fail.
#
# The consequence for AWS_PROFILE=gw230529-observer: in a shell that has
# already run `eval "$(make login)"`, the operator session in the environment
# wins and the profile is ignored. That fails *silently*, because the operator
# can do everything the observer can -- so a check meant to prove the observer
# works would pass without ever using it. Verify from a clean shell, or:
#
#   env -u AWS_SESSION_TOKEN -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
#     make throughput AWS_PROFILE=gw230529-observer
ifdef AWS_SESSION_TOKEN
unexport AWS_PROFILE
endif

TF := terraform
LOCAL_IMAGE ?= gw230529-et:local
IMAGE_TAG ?= latest

# Where the Einstein Toolkit gallery artefacts live locally. `make
# fetch-inputs` downloads them here from the gallery, checksum-pinned; the
# directory is gitignored because the files are upstream material that this
# project uses but does not redistribute.
#
# It used to default into the simulation repository's checkout, which quietly
# made a production run impossible from a standalone clone. Point INPUTS_DIR
# back at any directory that already holds them to skip the download.
INPUTS_DIR ?= upstream

# Wall clock cap for the throughput probe parfile, in minutes. Long enough for
# the reading to settle -- Carpet averages its own over ten minutes, and the
# start of a run is dominated by things that happen once -- and long enough
# that the hourly checkpoint fires inside it, since the seconds it stops every
# rank belong in the budget as much as the evolution does.
PROBE_MINUTES ?= 90

# Share one copy of the provider plugins across all three stacks. The AWS
# provider is ~840 MB; without this, each stack keeps its own copy under
# .terraform/ and the checkout grows to 2.5 GB.
export TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache

##@ Setup

.PHONY: setup
setup: ## Create .env, backend.hcl and terraform.tfvars from the templates
	@test -f .env || (cp .env.example .env && echo "created .env")
	@for s in bootstrap foundation compute; do \
		if [ -f stacks/$$s/terraform.tfvars.example ]; then \
			test -f stacks/$$s/terraform.tfvars || \
				(cp stacks/$$s/terraform.tfvars.example stacks/$$s/terraform.tfvars && \
				 echo "created stacks/$$s/terraform.tfvars"); \
		fi; \
		if [ -f stacks/$$s/backend.hcl.example ]; then \
			test -f stacks/$$s/backend.hcl || \
				(cp stacks/$$s/backend.hcl.example stacks/$$s/backend.hcl && \
				 echo "created stacks/$$s/backend.hcl"); \
		fi; \
	done
	@echo ""
	@echo "Now edit the CHANGEME values. None of these files are tracked by git."

.PHONY: region-scout
region-scout: ## Compare candidate regions on spot score, price and quota
	@scripts/region_scout.sh

.PHONY: check-permissions
check-permissions: ## Simulate every IAM action against a live principal (PRINCIPAL=<arn>)
	@scripts/check_permissions.sh $(PRINCIPAL)

.PHONY: check-permissions-policy
check-permissions-policy: ## Simulate the same actions against policies/terraform-operator.json
	@scripts/check_permissions.sh --policy policies/terraform-operator.json

.PHONY: login
login: ## Assume the operator role with MFA: eval "$(make login)"
	@scripts/assume_operator_role.sh

.PHONY: check-alerts
check-alerts: ## Fail unless both SNS topics still have a confirmed subscriber
	@scripts/check_alerts.sh

##@ Quality

.PHONY: fmt
fmt: ## Rewrite all Terraform files in canonical format
	@$(TF) fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not canonically formatted
	@$(TF) fmt -recursive -check -diff .

.PHONY: validate
validate: ## Validate every stack without contacting a backend
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@# Only initialise a stack that has never been initialised. `init
	@# -backend=false` sounds offline and is not: once a directory has been
	@# initialised against the S3 backend, every later init still reaches for
	@# it, so re-running it here made a pre-commit check depend on a live AWS
	@# session. That went unnoticed while a static access key answered
	@# silently; requiring MFA to assume the operator role turned it into a
	@# hard failure. `validate` on its own is genuinely offline.
	@#
	@# A stack whose modules or providers changed will fail with terraform
	@# saying so and naming init as the fix, which is the right place to be
	@# told.
	@for s in bootstrap foundation compute; do \
		echo "--- validating stacks/$$s ---"; \
		if [ ! -d stacks/$$s/.terraform ]; then \
			$(TF) -chdir=stacks/$$s init -backend=false -input=false >/dev/null || exit 1; \
		fi; \
		$(TF) -chdir=stacks/$$s validate || exit 1; \
	done

.PHONY: check-secrets
check-secrets: ## Fail if a tracked file contains an account id, ARN or access key
	@scripts/check_secrets.sh

.PHONY: check
check: fmt-check validate check-secrets ## Run every pre-commit check

##@ Stacks

.PHONY: init-%
init-%: ## Initialise a stack, e.g. make init-foundation
	@mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@if [ "$*" = "bootstrap" ]; then \
		$(TF) -chdir=stacks/$* init -input=false; \
	else \
		test -f stacks/$*/backend.hcl || \
			{ echo "stacks/$*/backend.hcl is missing -- run make setup"; exit 1; }; \
		$(TF) -chdir=stacks/$* init -input=false -backend-config=backend.hcl; \
	fi

.PHONY: plan-%
plan-%: ## Show the plan for a stack, e.g. make plan-foundation
	@$(TF) -chdir=stacks/$* plan -input=false

.PHONY: apply-%
apply-%: ## Apply a stack, e.g. make apply-foundation
	@$(TF) -chdir=stacks/$* apply -input=false

.PHONY: destroy-%
destroy-%: ## Destroy a stack, e.g. make destroy-compute
	@$(TF) -chdir=stacks/$* destroy -input=false

.PHONY: output-%
output-%: ## Show a stack's outputs, e.g. make output-foundation
	@$(TF) -chdir=stacks/$* output

##@ Image and inputs

.PHONY: fetch-inputs
fetch-inputs: ## Download the gallery artefacts, checksum pinned (ARGS=--reference adds the reference run log)
	@INPUTS_DIR="$(INPUTS_DIR)" scripts/fetch_inputs.sh $(ARGS)

.PHONY: upload-inputs
upload-inputs: ## Derive the cloud parfile, check it, and upload it with the initial data
	@INPUTS_DIR="$(INPUTS_DIR)" TF="$(TF)" scripts/upload_inputs.sh $(ARGS)

.PHONY: upload-probe
upload-probe: ## Also derive a walltime-capped throughput probe parfile (PROBE_MINUTES=90)
	@INPUTS_DIR="$(INPUTS_DIR)" TF="$(TF)" \
		scripts/upload_inputs.sh --probe $(PROBE_MINUTES)

.PHONY: push-image
push-image: ## Push the locally built Einstein Toolkit image to ECR
	@repo=$$($(TF) -chdir=stacks/foundation output -raw ecr_repository_url) && \
	region=$$($(TF) -chdir=stacks/foundation output -raw aws_region) && \
	aws ecr get-login-password --region $$region \
		| docker login --username AWS --password-stdin $$repo && \
	docker tag $(LOCAL_IMAGE) $$repo:$(IMAGE_TAG) && \
	docker push $$repo:$(IMAGE_TAG) && \
	echo "" && \
	echo "Pushed. Pin production runs to the digest above rather than the tag."

##@ Run control

.PHONY: run
run: ## Launch the spot instance and start a run
	@if [ -z "$(SKIP_ALERT_CHECK)" ]; then \
		scripts/check_alerts.sh || \
		{ echo ""; \
		  echo "Refusing to start billing with the alerts disarmed."; \
		  echo "Fix the subscription, or override with:"; \
		  echo "  make run SKIP_ALERT_CHECK=1"; \
		  exit 1; }; \
		echo ""; \
	fi
	@echo "This starts billing. The node self-terminates when the run ends."
	@$(TF) -chdir=stacks/compute apply -input=false -var run_enabled=true

.PHONY: stop
stop: ## Terminate the spot instance, keeping the launch template
	@$(TF) -chdir=stacks/compute apply -input=false -var run_enabled=false

.PHONY: status
status: ## Show the current run's instance id and S3 prefix
	@$(TF) -chdir=stacks/compute output

.PHONY: ssm
ssm: ## Open a shell on the running node through SSM Session Manager
# Two distinct failures, separated on purpose (#14). A terraform that cannot
# read the state -- typically a shell with no operator session -- exits
# non-zero with its own message left visible on stderr; only a terraform that
# succeeds with an empty value means no instance. The previous version
# discarded stderr and short-circuited past its own explanation, so both
# arrived as a bare "Error 1" -- at the one moment this target is wanted,
# while an instance is billing.
	@cmd=$$($(TF) -chdir=stacks/compute output -raw ssm_session_command) || \
		{ echo ""; \
		  echo "could not read the compute stack (terraform message above)."; \
		  echo "No session in this shell? Try: eval \"\$$(make login)\""; \
		  exit 1; }; \
	if [ -z "$$cmd" ] || [ "$$cmd" = "null" ]; then \
		echo "no instance is running -- make run first"; exit 1; \
	fi; \
	echo "$$cmd" && exec $$cmd

.PHONY: throughput
throughput: ## Read sec/iter and the cost projection out of a run log
	@scripts/read_throughput.sh $(ARGS)

# NOT "validate" -- that name belongs to the terraform check above, and
# `check` depends on it. Defining it twice silently replaced it.
.PHONY: validate-run
validate-run: ## Compare a live run against the published reference run
	@scripts/validate_against_reference.sh $(ARGS)

.PHONY: ledger
ledger: ## Show every node that served a run: uptime, downtime, effective compute
	@scripts/run_ledger.sh $(ARGS)

.PHONY: heartbeat
heartbeat: ## Print the latest heartbeat object written by the node
# Same two-failure separation as make ssm above (#14).
	@url=$$($(TF) -chdir=stacks/compute output -raw heartbeat_url) || \
		{ echo ""; \
		  echo "could not read the compute stack (terraform message above)."; \
		  echo "No session in this shell? Try: eval \"\$$(make login)\""; \
		  exit 1; }; \
	aws s3 cp $$url - 2>/dev/null || \
		echo "no heartbeat yet at $$url"
