.DEFAULT_GOAL := all

CCACHE_DIR := $(CURDIR)/ccache
SRC_DIR := $(CURDIR)/src
IMAGE_NAME := $(notdir $(CURDIR))
REPO := https://github.com/Penqle/tortoise-wow.git

.PHONY: all build pull submodules clone clean update

all:
	if [ -d "$(SRC_DIR)/.git" ]; then \
		$(MAKE) update; \
	else \
		$(MAKE) clone; \
	fi
	$(MAKE) build

build:
	mkdir -p "$(CCACHE_DIR)"
	podman build \
		--build-arg BUILD_JOBS=$$(nproc) \
		--volume "$(CCACHE_DIR):/ccache:Z" \
		-t dr1s/$(IMAGE_NAME):modules .

build-extractors:
	podman build \
		--build-arg BUILD_JOBS=$$(nproc) \
		--build-arg EXTRACTORS_ONLY=ON \
		--volume "$(CCACHE_DIR):/ccache:Z" \
		-t dr1s/$(IMAGE_NAME):extractors .
pull:
	git -C "$(SRC_DIR)" pull

submodules:
	git -C "$(SRC_DIR)" submodule update --init --recursive

update: pull submodules

clone:
	git clone "$(REPO)" "$(SRC_DIR)"

clean:
	rm -rf "$(CCACHE_DIR)" "$(SRC_DIR)"
