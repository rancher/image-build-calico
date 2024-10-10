SEVERITIES = HIGH,CRITICAL

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

BUILD_META=-build$(shell date +%Y%m%d)
ORG ?= rancher
MACHINE := rancher
TAG ?= ${GITHUB_ACTION_TAG}
REGISTRY_IMAGE ?= $(ORG)/hardened-calico

K3S_ROOT_VERSION ?= v0.14.0

ifeq ($(TAG),)
TAG := v3.28.2$(BUILD_META)
endif

IMAGE ?= $(REGISTRY_IMAGE):$(TAG)

LABEL_ARGS = $(foreach label,$(META_LABELS),--label $(label))

ifeq (,$(filter %$(BUILD_META),$(TAG)))
$(error TAG $(TAG) needs to end with build metadata: $(BUILD_META))
endif

buildx-machine:
	@docker buildx ls | grep $(MACHINE) || \
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
push-image: buildx-machine
	docker buildx build \
	    --builder=$(MACHINE) \
		--sbom=true \
		--attest type=provenance,mode=max \
		--platform=$(TARGET_PLATFORMS) \
		--build-arg TAG=$(TAG:$(BUILD_META)=) \
		--build-arg K3S_ROOT_VERSION=$(K3S_ROOT_VERSION) \
		--output type=image,name=$(REGISTRY_IMAGE),push-by-digest=true,name-canonical=true,push=true \
		$(LABEL_ARGS) \
		--push \
		--iidfile /tmp/image.digest \
		--metadata-file /tmp/metadata.json \
		.

.PHONY: manifest-push
manifest-push:
	docker buildx imagetools create -t $(IMAGE) -t $(REGISTRY_IMAGE):latest $(IMAGE_DIGESTS)

.PHONY: image-push
image-push:
	docker push $(ORG)/hardened-calico:$(TAG)-$(ARCH)

.PHONY: image-scan
image-scan:
	trivy image --severity $(SEVERITIES) --no-progress --ignore-unfixed $(ORG)/hardened-calico:$(TAG)

PHONY: log
log:
	@echo "ARCH=$(ARCH)"
	@echo "TAG=$(TAG:$(BUILD_META)=)"
	@echo "ORG=$(ORG)"
	@echo "PKG=$(PKG)"
	@echo "SRC=$(SRC)"
	@echo "BUILD_META=$(BUILD_META)"
	@echo "UNAME_M=$(UNAME_M)"
	@echo "META_LABELS=$(META_LABELS)"
	@echo "LABEL_ARGS=$(LABEL_ARGS)"
