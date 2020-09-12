SEVERITIES = HIGH,CRITICAL

.PHONY: all
all:
	docker build --build-arg TAG=$(TAG) -t rancher/hardened-calico:$(TAG) .

.PHONY: image-push
image-push:
	docker push rancher/hardened-calico:$(TAG) >> /dev/null

.PHONY: scan
image-scan:
	trivy --severity $(SEVERITIES) --no-progress --skip-update --ignore-unfixed rancher/hardened-calico:$(TAG)

.PHONY: image-manifest
image-manifest:
	docker image inspect rancher/hardened-calico:$(TAG)
	DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create rancher/hardened-calico:$(TAG) \
		$(shell docker image inspect rancher/hardened-calico:$(TAG) | jq -r '.[] | .RepoDigests[0]')
