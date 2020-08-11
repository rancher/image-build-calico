SEVERITIES = HIGH,CRITICAL

.PHONY: all
all:
	docker build --build-arg TAG=$(TAG) -t rancher/calico:$(TAG) .

.PHONY: image-push
image-push:
	docker push rancher/calico:$(TAG) >> /dev/null

.PHONY: scan
image-scan:
	trivy --severity $(SEVERITIES) --no-progress --skip-update --ignore-unfixed rancher/calico:$(TAG)

.PHONY: image-manifest
image-manifest:
	docker image inspect rancher/calico:$(TAG)
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create rancher/calico:$(TAG) \
		$(shell docker image inspect rancher/calico:$(TAG) | jq -r '.[] | .RepoDigests[0]')
