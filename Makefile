# Container-based dev/test targets.
# Uses scripts/container-test.sh which auto-detects podman (preferred) or
# docker. Force an engine with: make container-test CONTAINER_ENGINE=docker

.PHONY: container-build container-test

container-build:
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" ./scripts/container-test.sh build

container-test:
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" ./scripts/container-test.sh test