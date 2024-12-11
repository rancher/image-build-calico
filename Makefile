SEVERITIES = HIGH,CRITICAL

BUILDDIR ?= $(CURDIR)/build

UNAME_M = $(shell uname -m)
ARCH=
ifeq ($(UNAME_M), x86_64)
	ARCH=amd64
else ifeq ($(UNAME_M), aarch64)
	ARCH=arm64
else 
	ARCH=$(UNAME_M)
endif

ifndef TARGET_PLATFORMS
	ifeq ($(UNAME_M), x86_64)
		TARGET_PLATFORMS:=linux/amd64
	else ifeq ($(UNAME_M), aarch64)
		TARGET_PLATFORMS:=linux/arm64
	else 
		TARGET_PLATFORMS:=linux/$(UNAME_M)
	endif
endif

IID_FILE_FLAG ?=
IID_FILE_PATH := $(if $(IID_FILE_FLAG),$(word 2, $(IID_FILE_FLAG)))

K3S_ROOT_VERSION ?= v0.14.1
BUILD_META=-build$(shell date +%Y%m%d)
MACHINE := rancher
TAG ?= ${GITHUB_ACTION_TAG}

ifeq ($(TAG),)
TAG := v3.29.1$(BUILD_META)
endif

REPO ?= rancher
IMAGE_NAME = hardened-calico
REGISTRY_IMAGE = $(REPO)/$(IMAGE_NAME)
IMAGE = $(REGISTRY_IMAGE):$(TAG)

METADATA_FILE ?= $(BUILDDIR)/$(subst /,-,$(REGISTRY_IMAGE))-$(ARCH).metadata.json

LABEL_ARGS = $(foreach label,$(META_LABELS),--label $(label))

ifeq (,$(filter %$(BUILD_META),$(TAG)))
$(error TAG $(TAG) needs to end with build metadata: $(BUILD_META))
endif

$(BUILDDIR):
	mkdir $(BUILDDIR)

buildx-machine:
	docker buildx inspect $(MACHINE) > /dev/null 2>&1 || \
		docker buildx create --name=$(MACHINE) --platform=linux/arm64,linux/amd64

.PHONY: image-build
image-build:
	docker buildx build --no-cache \
		--platform=$(ARCH) \
		--pull \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		--build-arg K3S_ROOT_VERSION=$(K3S_ROOT_VERSION) \
		--tag $(IMAGE) \
		--tag $(IMAGE)-$(ARCH) \
		--load \
		.

.PHONY: push-image
push-image: $(BUILDDIR) | buildx-machine
	docker buildx build \
		--builder=$(MACHINE) \
		$(IID_FILE_FLAG) \
		--sbom=true \
		--attest type=provenance,mode=max \
		--platform=$(TARGET_PLATFORMS) \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		--build-arg K3S_ROOT_VERSION=$(K3S_ROOT_VERSION) \
		--output type=image,name=$(REGISTRY_IMAGE),push-by-digest=true,name-canonical=true,push=true \
		$(LABEL_ARGS) \
		--push \
		--metadata-file $(METADATA_FILE) \
		.

.PHONY: manifest-push
manifest-push: $(BUILDDIR) | buildx-machine
	docker buildx imagetools create \
		--builder=$(MACHINE) \
		-t $(IMAGE) -t $(REGISTRY_IMAGE):latest \
		$$(jq -r '.["containerimage.digest"]' $(METADATA_FILE))

ifneq ($(strip $(IID_FILE_PATH)),)
	docker buildx imagetools inspect --format "{{json .Manifest}}" $(IMAGE) | jq -r '.digest' > "$(IID_FILE_PATH)"
endif

.PHONY: image-scan
image-scan:
	trivy image --severity $(SEVERITIES) --no-progress --ignore-unfixed $(IMAGE)

PHONY: log
log:
	@echo "BUILDDIR=$(BUILDDIR)"
	@echo "ARCH=$(ARCH)"
	@echo "TAG=$(TAG:$(BUILD_META)=)"
	@echo "REPO=$(REPO)"
	@echo "REGISTRY_IMAGE=$(REGISTRY_IMAGE)"
	@echo "METADATA_FILE=$(METADATA_FILE)"
	@echo "PKG=$(PKG)"
	@echo "SRC=$(SRC)"
	@echo "BUILD_META=$(BUILD_META)"
	@echo "UNAME_M=$(UNAME_M)"
	@echo "META_LABELS=$(META_LABELS)"
	@echo "LABEL_ARGS=$(LABEL_ARGS)"
