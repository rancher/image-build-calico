SEVERITIES = HIGH,CRITICAL

.PHONY: all
all:
	docker build --build-arg TAG=$(TAG) -t ranchertest/calico:$(TAG) .

.PHONY: image-push
image-push:
	docker push ranchertest/calico:$(TAG) >> /dev/null

.PHONY: scan
image-scan:
	trivy --severity $(SEVERITIES) --no-progress --skip-update --ignore-unfixed ranchertest/calico:$(TAG)

.PHONY: image-manifest
image-manifest:
	docker image inspect ranchertest/calico:$(TAG)
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create ranchertest/calico:$(TAG) \
		$(shell docker image inspect ranchertest/calico:$(TAG) | jq -r '.[] | .RepoDigests[0]')
