SEVERITIES = HIGH,CRITICAL

ifeq ($(ARCH),)
ARCH=$(shell go env GOARCH)
endif

ORG ?= rancher
TAG ?= v3.13.3

ifneq ($(DRONE_TAG),)
TAG := $(DRONE_TAG)
endif

CNI_PLUGINS_VERSION ?= v0.8.7

.PHONY: image-build
image-build:
	docker build \
		--build-arg ARCH=$(ARCH) \
		--build-arg CNI_PLUGINS_VERSION=$(CNI_PLUGINS_VERSION) \
		--build-arg TAG=$(TAG) \
		--tag $(ORG)/hardened-calico:$(TAG) \
		--tag $(ORG)/hardened-calico:$(TAG)-$(ARCH) \
	.

.PHONY: image-push
image-push:
	docker push $(ORG)/hardened-calico:$(TAG)-$(ARCH)

.PHONY: image-manifest
image-manifest:
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create --amend \
		$(ORG)/hardened-calico:$(TAG) \
		$(ORG)/hardened-calico:$(TAG)-$(ARCH)
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest push \
		$(ORG)/hardened-calico:$(TAG)

.PHONY: image-scan
image-scan:
	trivy --severity $(SEVERITIES) --no-progress --ignore-unfixed $(ORG)/hardened-calico:$(TAG)
