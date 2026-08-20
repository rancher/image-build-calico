SEVERITIES = HIGH,CRITICAL

BUILDDIR ?= $(CURDIR)/build

UNAME_M = $(shell uname -m)
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

K3S_ROOT_VERSION ?= v0.15.2
BUILD_META=-build$(shell date +%Y%m%d)
MACHINE := rancher
TAG ?= ${GITHUB_ACTION_TAG}

ifeq ($(TAG),)
TAG := $(shell cat TAG)$(BUILD_META)
endif

REPO ?= rancher
IMAGE_VARIABLES = \
	calico:--build-arg=K3S_ROOT_VERSION=$(K3S_ROOT_VERSION) \
	calico-node:--build-arg=K3S_ROOT_VERSION=$(K3S_ROOT_VERSION) \

LABEL_ARGS = $(foreach label,$(META_LABELS),--label $(label))

ifeq (,$(filter %$(BUILD_META),$(TAG)))
$(error TAG $(TAG) needs to end with build metadata: $(BUILD_META))
endif

$(BUILDDIR):
	mkdir $(BUILDDIR)

buildx-machine:
	docker buildx inspect $(MACHINE) > /dev/null 2>&1 || \
		docker buildx create --name=$(MACHINE) --platform=linux/arm64,linux/amd64

define image_targets
.PHONY: image-build-$(1)
image-build-$(1):
	docker buildx build \
		--platform=$(TARGET_PLATFORMS) \
		--pull \
		--target $(1)-image \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		$(2) \
		--tag $(REPO)/hardened-$(1):$(TAG) \
		--load \
		.

.PHONY: push-image-$(1)
push-image-$(1): $(BUILDDIR) | buildx-machine
	docker buildx build \
		--builder=$(MACHINE) \
		$(IID_FILE_FLAG) \
		--sbom=true \
		--attest type=provenance,mode=max \
		--platform=$(TARGET_PLATFORMS) \
		--target $(1)-image \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		$(2) \
		--output type=image,name=$(REPO)/hardened-$(1),push-by-digest=true,name-canonical=true,push=true \
		$(LABEL_ARGS) \
		--push \
		--metadata-file $(BUILDDIR)/$(subst /,-,$(REPO)/hardened-$(1))-$(subst /,-,$(TARGET_PLATFORMS)).metadata.json \
		.

# Four $$$$ preserve shell variables through the define/eval template expansion.
.PHONY: manifest-push-$(1)
manifest-push-$(1): | buildx-machine
	d=""; \
	for architecture in $(MULTI_ARCH); do \
		metadata_file=$(BUILDDIR)/$(subst /,-,$(REPO)/hardened-$(1))-linux-$$$${architecture}.metadata.json; \
		d="$$$$d $$$$(jq -r '."containerimage.digest"' $$$$metadata_file)"; \
	done; \
	docker buildx imagetools create \
		--builder=$(MACHINE) \
		-t $(REPO)/hardened-$(1):$(TAG) -t $(REPO)/hardened-$(1):latest \
		$$$$d
endef
$(foreach image,$(IMAGE_VARIABLES),$(eval $(call image_targets,$(word 1,$(subst :, ,$(image))),$(word 2,$(subst :, ,$(image))))))

.PHONY: image-build
image-build: image-build-calico image-build-calico-node
.PHONY: push-image
push-image: push-image-calico push-image-calico-node
.PHONY: manifest-push
manifest-push: manifest-push-calico manifest-push-calico-node

ifneq ($(strip $(IID_FILE_PATH)),)
	docker buildx imagetools inspect --format "{{json .Manifest}}" $(CALICO_IMAGE) | jq -r '.digest' > "$(IID_FILE_PATH)"
endif

.PHONY: image-scan
image-scan:
	@for image in $(IMAGE_VARIABLES); do \
		name=$${image%%:*}; \
		name=$${name#*:}; \
		trivy image --severity $(SEVERITIES) --no-progress --ignore-unfixed $(REPO)/hardened-$${name}:$(TAG); \
	done

PHONY: log
log:
	@echo "BUILDDIR=$(BUILDDIR)"
	@echo "TAG=$(TAG:$(BUILD_META)=)"
	@echo "REPO=$(REPO)"
	@echo "BUILD_META=$(BUILD_META)"
	@echo "UNAME_M=$(UNAME_M)"
	@echo "META_LABELS=$(META_LABELS)"
	@echo "LABEL_ARGS=$(LABEL_ARGS)"
