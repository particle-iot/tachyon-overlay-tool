#
# This makefile does this:
#
# - takes in N number of fully qualified overlay paths that contain
#    (a) stacks over overlays (for top level control)
#    (b) overlay files itself
#    These directories are searched in order they are presented to the makefile
#
# - the stack name to apply (sourced from the above list of dirs)
#
# - a link to an image to apply the overlay files to which is either
#    (a) an uncompressed system image
#    (b) a compressed system image (bundle)
#
# - an optional resources directory that contains files that the overlay might want to reference
#    The overlay tool does not care about the format of this directory, it just makes it available
#
# - a set of environment variables that can be used to parameterize the overlay files
#
# - a debug flag (optional) that is either:
#    (a) true - which will print out all commands as they are executed
#    (b) false - (default) - no debug
#    (c) chroot - which will drop the user into a chroot inside the image after all overlays have been applied.
#         Logs are also printed out with this option
#
# How this works:
#
# The makefile modifies the filesystem in place. 
# If an optional output file is wanted, the user has to pass in a optional output file
# which is either (a) a new system image directory to write to or (b) a new bundle file to write to.
#
# Internally, it uses docker to run all commands - docker is managed by the Dockerfile in this project 
# and its recreated whenever the version changes inside the Dockerfile and the local image is not built.
#
# Process wise, the makefile contains the commands to perform the main actions, but overlay.py is used 
# to do the actualy overlay magic. A helper script that runs inside the docker container (run-overlay.sh)
# is used because it is easier to manage the logic of the overlay process in a script than in a makefile.
# The makefile contains some commands that the script uses to run things (like mounting the image etc...).

# Disable all built-in implicit rules & built-in variables
MAKEFLAGS += -rR
.SUFFIXES:

# Derive VERSION from the latest semantic tag in the repo
VERSION := $(shell \
  tag=$$(git describe --tags --abbrev=0 2>/dev/null || echo ""); \
  if echo "$$tag" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
    echo $$tag; \
  elif [ -z "$$tag" ]; then \
    echo "Error: No version tag found. Please create one (e.g. git tag 0.1.0)" >&2; \
    exit 1; \
  else \
    echo "Error: Latest tag '$$tag' is not a valid semantic version (x.y.z)" >&2; \
    exit 1; \
  fi)

# Default directories
DEFAULT_TMP_ROOT_DIR := ./.tmp
DEFAULT_TMP_INPUT_DIR := ./.tmp/input
DEFAULT_TMP_OUTPUT_DIR := ./.tmp/output

# Parameters (overridable by user)
INPUT_OVERLAY_PATH ?=
INPUT_STACK_NAME ?=
INPUT_SYSTEM_IMAGE ?=
INPUT_RESOURCES_DIR ?=
OUTPUT_SYSTEM_IMAGE ?=
INPUT_ENV_VARS ?=
DEBUG ?= false         # true | false | chroot

# Working directories
TMP_ROOT_DIR ?= $(DEFAULT_TMP_ROOT_DIR)
TMP_INPUT_DIR ?= $(DEFAULT_TMP_INPUT_DIR)
TMP_OUTPUT_DIR ?= $(DEFAULT_TMP_OUTPUT_DIR)

# -------------------------------------------------------------------
# Validation helpers
# -------------------------------------------------------------------
define check_required_param
	@if [ -z "$($(1))" ]; then \
		echo "Error: $(1) parameter is required"; \
		echo "Usage: make apply INPUT_OVERLAY_PATH=\"<dir1> [<dir2> ...]\" INPUT_STACK_NAME=<stack> INPUT_SYSTEM_IMAGE=<image_or_bundle> [OUTPUT_SYSTEM_IMAGE=<output_path>] [INPUT_RESOURCES_DIR=<dir>] [INPUT_ENV_VARS=KEY1=VAL1,...] [DEBUG=<true|false|chroot>]"; \
		exit 1; \
	fi
endef

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------
.PHONY: help
help:
	@echo "Tachyon Overlay Tool v$(VERSION)"
	@echo ""
	@echo "Available commands:"
	@echo "  apply                       Apply overlay stack to a system image"
	@echo "  docker                      Build the Docker container image"
	@echo "  docker/shell                Open an interactive shell in the Docker environment"
	@echo "  doctor                      Check host prerequisites (docker, git)"
	@echo "  clean                       Remove temporary files"
	@echo "  help                        Show this help message"
	@echo "  version                     Version info"
	@echo ""
	@echo "Required parameters for apply:"
	@echo "  INPUT_OVERLAY_PATH          One or more overlay directories (separate multiple paths with space or ':')"
	@echo "  INPUT_STACK_NAME            Name of the overlay stack to apply"
	@echo "  INPUT_SYSTEM_IMAGE          Path or URL of the system image (or .zip bundle) to modify"
	@echo ""
	@echo "Optional parameters:"
	@echo "  OUTPUT_SYSTEM_IMAGE         Output path for modified image (new bundle .zip file or directory)"
	@echo "  INPUT_RESOURCES_DIR         Path to additional resources for overlays (if needed)"
	@echo "  INPUT_ENV_VARS              Comma-separated list of KEY=VALUE pairs to set inside chroot (optional)"
	@echo "  DEBUG                       Debug mode: true (pause before apply), false (normal), chroot (pause after apply)"
	@echo ""
	@echo "Example:"
	@echo "  make apply INPUT_OVERLAY_PATH=\"./overlays_common ./overlays_project\" \\"
	@echo "       INPUT_STACK_NAME=my_stack INPUT_SYSTEM_IMAGE=base_image.zip OUTPUT_SYSTEM_IMAGE=output_bundle.zip"
	@echo ""

##########################################################
# Docker image build and run targets
##########################################################
DOCKERFILE           ?= Dockerfile
DOCKER_CONTEXT       ?= .
define GET_COMMENT_KV
sed -nE 's/^[[:space:]]*#[[:space:]]*$(1)[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' $(DOCKERFILE) | head -n1
endef
PARTICLE_DOCKERFILE_VERSION := $(strip $(shell $(call GET_COMMENT_KV,particle-dockerfile-version)))
DOCKER_VERSION ?= $(if $(PARTICLE_DOCKERFILE_VERSION),$(PARTICLE_DOCKERFILE_VERSION),dev)
IMAGE_NAME           ?= tachyon-overlay-builder
IMAGE_TAG            ?= $(IMAGE_NAME):$(DOCKER_VERSION)
BASE_IMAGE           ?= ubuntu:24.04
UID                  ?= $(shell id -u 2>/dev/null || echo 1000)
GID                  ?= $(shell id -g 2>/dev/null || echo 1000)
PUSH_IMAGE           ?=
DOCKER_EXTRA_BUILD_ARGS ?=
export DOCKER_BUILDKIT ?= 1

STAMP_DIR            := $(DEFAULT_TMP_ROOT_DIR)/.build/docker
STAMP_NAME           := $(subst /,_,$(subst :,_,$(IMAGE_TAG)))
DOCKER_STAMP         := $(STAMP_DIR)/$(STAMP_NAME).stamp

.PHONY: docker docker/build docker/push docker/clean docker/rebuild
docker: docker/build

docker/build: $(DOCKER_STAMP)

# Build the Docker image (if not already present)
$(DOCKER_STAMP): $(DOCKERFILE)
	@mkdir -p $(STAMP_DIR)
	@echo "==> Checking if Docker image $(IMAGE_TAG) exists locally..."
	@if docker image inspect "$(IMAGE_TAG)" >/dev/null 2>&1; then \
	  echo "Image $(IMAGE_TAG) already exists locally, skipping build"; \
	else \
	  echo "==> Trying to pull $(IMAGE_TAG)"; \
	  if echo "$(IMAGE_TAG)" | cut -d '/' -f1 | grep -q 'particle' && docker pull "$(IMAGE_TAG)"; then \
	    echo "Image $(IMAGE_TAG) pulled from registry"; \
	  else \
	    echo "==> Building Docker image $(IMAGE_TAG)"; \
	    docker build -t "$(IMAGE_TAG)" --load \
	      --file "$(DOCKERFILE)" \
	      --build-arg UID="$(UID)" \
	      --build-arg GID="$(GID)" \
	      --build-arg BASE_IMAGE="$(BASE_IMAGE)" \
	      $(DOCKER_EXTRA_BUILD_ARGS) \
	      "$(DOCKER_CONTEXT)"; \
	    if echo "$(IMAGE_TAG)" | cut -d '/' -f1 | grep -q 'particle' && [ -n "$(PUSH_IMAGE)" ]; then \
	      echo "==> Pushing image $(IMAGE_TAG)"; \
	      docker push "$(IMAGE_TAG)" || echo "Failed to push (docker login needed)"; \
	    else \
	      echo "PUSH_IMAGE not set, skipping push"; \
	    fi; \
	  fi; \
	fi
	@touch "$@"

docker/push: docker/build
	@echo "==> Pushing $(IMAGE_TAG)"
	@docker push "$(IMAGE_TAG)"

docker/clean:
	@echo "==> Cleaning Docker image and stamp"
	-@docker rmi -f "$(IMAGE_TAG)" >/dev/null 2>&1 || true
	-@rm -f "$(DOCKER_STAMP)"

docker/rebuild: docker/clean docker/build

.PHONY: docker/shell
docker/shell: docker/build
	@echo "==> Starting interactive shell in $(IMAGE_TAG)"
	$(DOCKER_RUN) bash

# Docker run command (with privileged and volume mounts)
DOCKER_RUN := docker run --rm -it --privileged -v $(PWD):/project -v $(TMP_ROOT_DIR):/tmp/work -v /dev:/dev -w /project $(IMAGE_TAG)

##########################################################
# Host controls
##########################################################
.PHONY: doctor
doctor:
	@echo "==> Checking minimal host prerequisites"
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker CLI not found. Please install Docker."; exit 1; }
	@docker version >/dev/null 2>&1 || { echo "Error: Docker daemon not reachable. Please start Docker."; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "Error: git not found. Please install git."; exit 1; }
	@echo "Host OK: docker and git are available."

.PHONY: version
version:
	@echo "Tachyon Overlay Tool version $(VERSION)"

.PHONY: clean
clean:
	@echo "==> Cleaning temporary files in $(TMP_ROOT_DIR)"
	-@rm -rf $(TMP_ROOT_DIR)
	@echo "Temporary files removed."


##########################################################
# Main target: apply overlay
##########################################################

.PHONY: apply
apply: docker/build
	$(call check_required_param,INPUT_OVERLAY_PATH)
	$(call check_required_param,INPUT_STACK_NAME)
	$(call check_required_param,INPUT_SYSTEM_IMAGE)
	@# Validate DEBUG parameter
	@if [ "$(DEBUG)" != "true" ] && [ "$(DEBUG)" != "false" ] && [ "$(DEBUG)" != "chroot" ]; then \
		echo "Error: DEBUG must be 'true', 'false', or 'chroot' (got '$(DEBUG)')"; \
		exit 1; \
	fi
	@# Validate overlay path(s) exist
	@for d in $(subst :, ,$(INPUT_OVERLAY_PATH)); do \
		if [ ! -d "$$d" ]; then echo "Error: Overlay path '$$d' not found"; exit 1; fi; \
	done
	@# Validate stack file exists in one of the overlay paths
	@stack_found=false; \
	for d in $(subst :, ,$(INPUT_OVERLAY_PATH)); do \
		if [ -f "$$d/stacks/$(INPUT_STACK_NAME).json" ]; then stack_found=true; break; fi; \
	done; \
	if [ "$$stack_found" = false ]; then \
		echo "Error: Stack '$(INPUT_STACK_NAME).json' not found in any overlay path"; \
		exit 1; \
	fi
	@echo "Configuration:"
	@echo "  Overlay paths:  $(INPUT_OVERLAY_PATH)"
	@echo "  Stack name:     $(INPUT_STACK_NAME)"
	@echo "  System image:   $(INPUT_SYSTEM_IMAGE)"
	@echo "  Output target:  $(if $(OUTPUT_SYSTEM_IMAGE),$(OUTPUT_SYSTEM_IMAGE),<none>)"
	@echo "  Resources dir:  $(if $(INPUT_RESOURCES_DIR),$(INPUT_RESOURCES_DIR),<none>)"
	@echo "  Env variables:  $(if $(INPUT_ENV_VARS),$(INPUT_ENV_VARS),<none>)"
	@echo "  Debug:          $(DEBUG)"
	@echo "  Temp directory: $(abspath $(TMP_ROOT_DIR))"
	@echo ""
	@echo "Preparing environment..."
	@mkdir -p $(TMP_INPUT_DIR) $(TMP_OUTPUT_DIR)
	@# Copy resources directory if provided
	@if [ -n "$(INPUT_RESOURCES_DIR)" ]; then \
		if [ ! -d "$(INPUT_RESOURCES_DIR)" ]; then \
			echo "Error: Resources directory '$(INPUT_RESOURCES_DIR)' not found"; \
			exit 1; \
		fi; \
		rm -rf $(TMP_INPUT_DIR)/resources; \
		cp -r "$(INPUT_RESOURCES_DIR)" $(TMP_INPUT_DIR)/resources; \
	fi

	@# ---- Stage overlays & stacks into .tmp/input so the container can see them
	@echo "Staging overlays & stacks into $(TMP_INPUT_DIR) ..."
	@rm -rf "$(TMP_INPUT_DIR)/overlays" "$(TMP_INPUT_DIR)/stacks"
	@mkdir -p "$(TMP_INPUT_DIR)/overlays" "$(TMP_INPUT_DIR)/stacks"
	@paths="$$(printf '%s\n' '$(INPUT_OVERLAY_PATH)' | sed 's/[[:space:]]\+/:/g')"; \
	OLDIFS="$$IFS"; IFS=":"; set -- $$paths; IFS="$$OLDIFS"; \
	for path in "$$@"; do \
		[ -d "$$path" ] || { echo "Warning: overlay root not found: $$path"; continue; }; \
		if [ -d "$$path/overlays" ]; then \
			for od in "$$path/overlays"/*; do \
				[ -d "$$od" ] || continue; \
				name=$$(basename "$$od"); \
				if [ ! -e "$(TMP_INPUT_DIR)/overlays/$$name" ]; then \
					echo "  + overlay $$name (from $$path)"; \
					cp -a "$$od" "$(TMP_INPUT_DIR)/overlays/"; \
				fi; \
			done; \
		fi; \
		if [ -d "$$path/stacks" ]; then \
			for sf in "$$path/stacks"/*.json; do \
				[ -f "$$sf" ] || continue; \
				name=$$(basename "$$sf"); \
				if [ ! -e "$(TMP_INPUT_DIR)/stacks/$$name" ]; then \
					echo "  + stack $$name (from $$path)"; \
					cp "$$sf" "$(TMP_INPUT_DIR)/stacks/"; \
				fi; \
			done; \
		fi; \
	done

	@# Copy resources directory if provided
	@if [ -n "$(INPUT_RESOURCES_DIR)" ]; then \
		if [ ! -d "$(INPUT_RESOURCES_DIR)" ]; then \
			echo "Error: Resources directory '$(INPUT_RESOURCES_DIR)' not found"; \
			exit 1; \
		fi; \
		rm -rf "$(TMP_INPUT_DIR)/resources"; \
		cp -r "$(INPUT_RESOURCES_DIR)" "$(TMP_INPUT_DIR)/resources"; \
	fi

	@# === System image staging (ZIP or directory only) =========================
	@echo "Staging system image into $(TMP_INPUT_DIR)/sys_image ..."
	@rm -rf $(TMP_INPUT_DIR)/sys_image
	@mkdir -p $(TMP_INPUT_DIR)/sys_image
	@if echo "$(INPUT_SYSTEM_IMAGE)" | grep -qE '^https?://'; then \
		echo "Error: INPUT_SYSTEM_IMAGE must be a local .zip file or a directory, not a URL. Use 'make download-and-unzip-release' first."; \
		exit 1; \
	fi
	@if [ -d "$(INPUT_SYSTEM_IMAGE)" ]; then \
		echo "Copying directory '$(INPUT_SYSTEM_IMAGE)' → $(TMP_INPUT_DIR)/sys_image"; \
		cp -a "$(INPUT_SYSTEM_IMAGE)"/. "$(TMP_INPUT_DIR)/sys_image/"; \
	elif echo "$(INPUT_SYSTEM_IMAGE)" | grep -qE '\.zip$$'; then \
		echo "Copying ZIP '$(INPUT_SYSTEM_IMAGE)' → $(TMP_INPUT_DIR)"; \
		cp "$(INPUT_SYSTEM_IMAGE)" "$(TMP_INPUT_DIR)/"; \
		echo "Unzipping into $(TMP_INPUT_DIR)/sys_image ..."; \
		$(DOCKER_RUN) bash -lc 'set -euo pipefail; cd /tmp/work/input; fname="$(notdir $(INPUT_SYSTEM_IMAGE))"; unzip -o "$$fname" -d sys_image >/dev/null'; \
	else \
		echo "Error: INPUT_SYSTEM_IMAGE must be either a directory or a .zip file (got '$(INPUT_SYSTEM_IMAGE)')"; \
		exit 1; \
	fi

	@# === Determine fixed image path inside sys_image/ =========================
	@echo "Validating expected image path under sys_image/ ..."
	@if [ ! -f "$(TMP_INPUT_DIR)/sys_image/images/qcm6490/edl/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4" ]; then \
		echo "Error: expected image not found:"; \
		echo "  $(TMP_INPUT_DIR)/sys_image/images/qcm6490/edl/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4"; \
		echo "Directory listing (top-level of sys_image):"; \
		ls -al "$(TMP_INPUT_DIR)/sys_image" || true; \
		exit 1; \
	fi
	@echo "Main image file: sys_image/images/qcm6490/edl/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4"

	@# === Run overlay application inside Docker ================================
	@echo "Applying overlay stack '$(INPUT_STACK_NAME)'..."
	@$(DOCKER_RUN) bash ./run-overlay.sh \
		-f "/tmp/work/input/sys_image/images/qcm6490/edl/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4" \
		-r "/tmp/work/input/resources" \
		-s "$(INPUT_STACK_NAME)" \
		-d "$(DEBUG)"$(if $(INPUT_ENV_VARS), -e "$(INPUT_ENV_VARS)",)
	@echo "Overlay application completed."

	@# === Package output (zip of sys_image/, or xz/raw of ext4) ================
	@if [ -n "$(OUTPUT_SYSTEM_IMAGE)" ]; then \
		echo "Packaging output..."; \
		if echo "$(OUTPUT_SYSTEM_IMAGE)" | grep -qE '\.zip$$'; then \
			$(DOCKER_RUN) bash -lc "cd /tmp/work/input/sys_image && zip -r -q /tmp/work/output/$(notdir $(OUTPUT_SYSTEM_IMAGE)) ."; \
			mv "$(TMP_OUTPUT_DIR)/$(notdir $(OUTPUT_SYSTEM_IMAGE))" "$(OUTPUT_SYSTEM_IMAGE)"; \
			echo "Output bundle created: $(abspath $(OUTPUT_SYSTEM_IMAGE))"; \
		else \
			mv "$(TMP_INPUT_DIR)/sys_image/images/qcm6490/edl/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4" "$(OUTPUT_SYSTEM_IMAGE)"; \
			echo "Output image file created: $(abspath $(OUTPUT_SYSTEM_IMAGE))"; \
		fi; \
	else \
		echo "No output specified; modified image remains in $(abspath $(TMP_INPUT_DIR))/sys_image."; \
	fi

## Unsparse (convert) the system image if needed
docker-unsparse-image:
	@echo "Converting sparse image to raw image (if applicable): $(SYSTEM_IMAGE) -> $(SYSTEM_OUTPUT)"
	@# If the input is an Android sparse image, use simg2img; if not, just copy it
	-@simg2img $(SYSTEM_IMAGE) $(SYSTEM_OUTPUT) || { \
	    echo "Not a sparse image, copying directly to raw file."; \
	    cp $(SYSTEM_IMAGE) $(SYSTEM_OUTPUT); \
	}
	@file $(SYSTEM_IMAGE)
	@file $(SYSTEM_OUTPUT)
	@ls -alh $(SYSTEM_IMAGE) $(SYSTEM_OUTPUT)

## Repack the system image to sparse format
docker-sparse-image:
	@echo "Repacking raw image to sparse format: $(SYSTEM_IMAGE).raw -> $(SYSTEM_IMAGE)"
	@e2fsck -fp $(SYSTEM_IMAGE).raw || true
	@# Resize filesystem to 1GB larger than minimum (will expand on boot)
	@MINIMUM_SIZE=$$(resize2fs $(SYSTEM_IMAGE).raw -P | grep -oP '\d+'); \
	NEW_SIZE=$$((MINIMUM_SIZE + 262144)); \
	resize2fs $(SYSTEM_IMAGE).raw $$NEW_SIZE
	@img2simg $(SYSTEM_IMAGE).raw $(SYSTEM_IMAGE)

##########################################################
# Helper functions
##########################################################

# -------------------------------------------------------------------
# Download a release artifact into .tmp/input
#
# Usage:
#   make download-release INPUT_SYSTEM_IMAGE=tachyon-ubuntu-20.04-RoW-desktop-1.0.167
#   # or (still supported)
#   make download-release INPUT_SYSTEM_IMAGE=https://linux-dist.particle.io/release/tachyon-ubuntu-20.04-RoW-desktop-1.0.167
# -------------------------------------------------------------------
.PHONY: download-release-helper
download-release-helper: docker/build
	$(call check_required_param,INPUT_SYSTEM_IMAGE)
	@# Prepare temp directory
	@mkdir -p $(TMP_INPUT_DIR)
	@rm -rf $(TMP_INPUT_DIR)/*
	@echo "Resolving download URL for INPUT_SYSTEM_IMAGE='$(INPUT_SYSTEM_IMAGE)'"
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; cd /tmp/work/input; \
		url="$(INPUT_SYSTEM_IMAGE)"; \
		if ! echo "$$url" | grep -qE "^https?://"; then \
			url="https://linux-dist.particle.io/release/$${url}.zip"; \
		fi; \
		fname="$${url##*/}"; \
		echo "Downloading release from $$url ..."; \
		if [ -f "$$fname" ]; then \
			echo "File $$fname already exists, skipping download"; \
		else \
			curl -fL --retry 3 -o "$$fname" "$$url" || { echo "Error: failed to download $$url"; rm -f "$$fname"; exit 1; }; \
			test -s "$$fname" || { echo "Error: downloaded file is empty: $$fname"; exit 1; }; \
		fi; \
		echo "Downloaded: $$fname"; \
		ls -alh "$$fname"'
	@echo "Downloaded file is in $(abspath $(TMP_INPUT_DIR))"


# -------------------------------------------------------------------
# Download a release artifact and unzip it into .tmp/input
#
# Usage:
#   make download-and-unzip-release INPUT_SYSTEM_IMAGE=tachyon-ubuntu-20.04-RoW-desktop-1.0.167.zip
#   # or (still supported)
#   make download-and-unzip-release INPUT_SYSTEM_IMAGE=https://linux-dist.particle.io/release/tachyon-ubuntu-20.04-RoW-desktop-1.0.167.zip
# Notes:
#   - This expects the downloaded file to be a ZIP archive. It will fail if not.
# -------------------------------------------------------------------
.PHONY: download-and-unzip-release-helper
download-and-unzip-release-helper: docker/build
	$(call check_required_param,INPUT_SYSTEM_IMAGE)
	@# Prepare temp directory
	@mkdir -p $(TMP_INPUT_DIR)
	@rm -rf $(TMP_INPUT_DIR)/*
	@echo "Resolving download URL for INPUT_SYSTEM_IMAGE='$(INPUT_SYSTEM_IMAGE)'"
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; cd /tmp/work/input; \
		url="$(INPUT_SYSTEM_IMAGE)"; \
		if ! echo "$$url" | grep -qE "^https?://"; then \
			url="https://linux-dist.particle.io/release/$${url}.zip"; \
		fi; \
		fname="$${url##*/}"; \
		dirname="$${fname%.zip}"; \
		echo "Downloading release from $$url ..."; \
		if [ -f "$$fname" ]; then \
			echo "File $$fname already exists, skipping download"; \
		else \
			curl -fL --retry 3 -o "$$fname" "$$url" || { echo "Error: failed to download $$url"; rm -f "$$fname"; exit 1; }; \
			test -s "$$fname" || { echo "Error: downloaded file is empty: $$fname"; exit 1; }; \
		fi; \
		echo "Unzipping $$fname into $$dirname ..."; \
		mkdir -p "$$dirname"; \
		if unzip -o "$$fname" -d "$$dirname" >/dev/null; then \
			echo "Unzipped: $$fname -> $$dirname"; \
		else \
			echo "Error: $$fname is not a zip archive or unzip failed"; \
			exit 1; \
		fi; \
		echo "Directory contents after unzip:"; ls -alh "$$dirname"'
	@echo "Downloaded and unzipped files are in $(abspath $(TMP_INPUT_DIR))/<zipname-without-extension>"
