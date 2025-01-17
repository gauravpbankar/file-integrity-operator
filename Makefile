include version.Makefile

# Operator variables
# ==================
export APP_NAME=file-integrity-operator

# Container image variables
# =========================
IMAGE_REPO?=quay.io/file-integrity-operator
RUNTIME?=podman
# Required for podman < 3.4.7 and buildah to use microdnf in fedora 35
RUNTIME_BUILD_OPTS=--security-opt seccomp=unconfined

ifeq ($(RUNTIME),buildah)
RUNTIME_BUILD_CMD=bud
else
RUNTIME_BUILD_CMD=build
endif

# Git options.
GIT_OPTS?=
# Set this to the remote used for the upstream repo (for release)
GIT_REMOTE?=origin

# Image tag to use. Set this if you want to use a specific tag for building
# or your e2e tests.
TAG?=latest

# Image path to use. Set this if you want to use a specific path for building
# or your e2e tests. This is overwritten if we bulid the image and push it to
# the cluster or if we're on CI.
RELATED_IMAGE_OPERATOR_PATH?=$(IMAGE_REPO)/$(APP_NAME)
BUNDLE_IMAGE_PATH=$(IMAGE_REPO)/$(APP_NAME)-bundle
BUNDLE_IMAGE_TAG?=$(TAG)
TEST_BUNDLE_IMAGE_TAG?=testonly
INDEX_IMAGE_NAME=$(APP_NAME)-index
INDEX_IMAGE_PATH=$(IMAGE_REPO)/$(INDEX_IMAGE_NAME)
INDEX_IMAGE_TAG?=latest
NEW_IMAGE_BASE?=$(RELATED_IMAGE_OPERATOR_PATH)

TARGET_DIR=$(PWD)/build/bin
GO=GOFLAGS=-mod=vendor GO111MODULE=auto go
TARGET_OPERATOR=$(TARGET_DIR)/manager
MAIN_PKG=main.go
PKGS=$(shell go list ./... | grep -v -E '/vendor/|/tests|/examples')

# go source files, ignore vendor directory
SRC = $(shell find . -type f -name '*.go' -not -path "./vendor/*" -not -path "./_output/*")

KUBECONFIG?=$(HOME)/.kube/config
export NAMESPACE=openshift-file-integrity

# Operator-sdk variables
# ======================
SDK_BIN?=
SDK_VERSION?=1.15.0

# Test variables
# ==============
TEST_SETUP_DIR=tests/_setup
TEST_CRD=$(TEST_SETUP_DIR)/crd.yaml
TEST_DEPLOY=$(TEST_SETUP_DIR)/deploy_rbac.yaml
# Pass extra flags to the e2e test run.
# e.g. to run a specific test in the e2e test suite, do:
# E2E_GO_TEST_FLAGS="-v -timeout 20m -run TestFileIntegrityLogAndReinitDatabase" make e2e
E2E_GO_TEST_FLAGS?=-v -timeout 60m
E2E_ARGS=-root=$(PROJECT_DIR) -globalMan=$(TEST_CRD) -namespacedMan=$(TEST_DEPLOY) -skipCleanupOnError=true
# Skip pushing the container to your cluster
E2E_SKIP_CONTAINER_PUSH?=false
# Use default images in the e2e test run. Note that this takes precedence over E2E_SKIP_CONTAINER_PUSH
E2E_USE_DEFAULT_IMAGES?=false

# The name of the primary generated role
ROLE ?= $(APP_NAME)

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
DEFAULT_CHANNEL="alpha"
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# openshift.io/file-integrity-operator-bundle:$VERSION and openshift.io/file-integrity-operator-catalog:$VERSION.
IMAGE_TAG_BASE=$(IMAGE_REPO)/$(APP_NAME)

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:$(TAG)

# Image URL to use all building/pushing image targets
IMG ?= $(IMAGE_TAG_BASE):$(TAG)
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.22

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:$(TAG)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Setup targets (prep/tools/clean)
# =============

.PHONY: openshift-user
openshift-user:
ifeq ($(shell oc whoami 2>/dev/null),kube:admin)
	$(eval OPENSHIFT_USER = kubeadmin)
else
	$(eval OPENSHIFT_USER = $(shell oc whoami))
endif

.PHONY: check-operator-version
check-operator-version:
ifndef VERSION
	$(error VERSION must be defined)
endif

.PHONY: clean
clean: clean-modcache clean-cache clean-output clean-test clean-kustomize ## Run all of the clean targets.

.PHONY: clean-output
clean-output: ## Remove the operator bin.
	rm -f $(TARGET_OPERATOR)

.PHONY: clean-cache
clean-cache: ## Run go clean -cache -testcache.
	$(GO) clean -cache -testcache $(PKGS)

.PHONY: clean-modcache
clean-modcache: ## Run go clean -modcache.
	$(GO) clean -modcache $(PKGS)

.PHONY: clean-test
clean-test: clean-cache ## Clean up test cache and test setup artifacts.
	rm -rf $(TEST_SETUP_DIR)

.PHONY: clean-kustomize
clean-kustomize: ## Reset kustomize changes in the repo.
	@git restore bundle/manifests/file-integrity-operator.clusterserviceversion.yaml config/manager/kustomization.yaml

.PHONY: simplify
simplify: ## Run go fmt -s against code.
	@gofmt -s -l -w $(SRC)

fmt: ## Run go fmt against code.
	$(GO) fmt ./...

vet: ## Run go vet against code.
	$(GO) vet ./...

.PHONY: verify
verify: vet gosec ## Run vet and gosec checks.

.PHONY: gosec
gosec: ## Run gosec against code.
	@$(GO) run github.com/securego/gosec/v2/cmd/gosec -severity medium -confidence medium -quiet $(PKGS)

CONTROLLER_GEN = $(shell pwd)/build/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.7.0)

KUSTOMIZE = $(shell pwd)/build/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

ENVTEST = $(shell pwd)/build/setup-envtest
envtest: ## Download envtest-setup locally if necessary.
	$(call go-get-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/build go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

.PHONY: opm
OPM = ./build/opm
opm: ## Download opm locally if necessary.
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v$(SDK_VERSION)/$${OS}-$${ARCH}-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif

.PHONY: operator-sdk
SDK_BIN = ./build/operator-sdk
operator-sdk: ## Download operator-sdk locally if necessary.
ifeq (,$(wildcard $(SDK_BIN)))
ifeq (,$(shell which operator-sdk 2>/dev/null))
	@{ \
	set -e ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(SDK_BIN) https://github.com/operator-framework/operator-sdk/releases/download/v$(SDK_VERSION)/operator-sdk_$${OS}_$${ARCH} ;\
	chmod +x $(SDK_BIN) ;\
	}
else
SDK_BIN = $(shell which operator-sdk)
endif
endif

.PHONY: update-skip-range
update-skip-range: check-operator-version
	sed -i '/replaces:/d' config/manifests/bases/file-integrity-operator.clusterserviceversion.yaml
	sed -i "s/\(olm.skipRange: '>=.*\)<.*'/\1<$(VERSION)'/" config/manifests/bases/file-integrity-operator.clusterserviceversion.yaml

.PHONY: namespace
namespace:
	@oc apply -f config/ns/ns.yaml

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


##@ Generate

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=$(ROLE) crd webhook paths=./pkg/apis/fileintegrity/v1alpha1 output:crd:artifacts:config=config/crd/bases

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths=./pkg/apis/fileintegrity/v1alpha1


##@ Build

.PHONY: all
all: images

.PHONY: images
images: image bundle-image  ## Build operator and bundle images.

build: generate ## Build the operator binary.
	$(GO) build -o $(TARGET_OPERATOR) $(MAIN_PKG)

image: test-unit ## Build the operator image.
	$(RUNTIME) $(RUNTIME_BUILD_CMD) $(RUNTIME_BUILD_OPTS) -f build/Dockerfile -t ${IMG} .

.PHONY: bundle
bundle: check-operator-version operator-sdk manifests update-skip-range kustomize ## Generate bundle manifests and metadata, then validate generated files.
	$(SDK_BIN) generate kustomize manifests --apis-dir=./pkg/apis -q
	@echo "kustomize using deployment image $(IMG)"
	cd config/manager && $(KUSTOMIZE) edit set image $(APP_NAME)=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(SDK_BIN) generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(SDK_BIN) bundle validate ./bundle

.PHONY: bundle-image
bundle-image: bundle ## Build the bundle image.
	$(RUNTIME) $(RUNTIME_BUILD_CMD) -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-image
catalog-image: opm ## Build a catalog image.
	$(OPM) index add --container-tool $(RUNTIME) --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

.PHONY: catalog
catalog: catalog-image catalog-push ## Build and push a catalog image.

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	$(GO) run ./$(MAIN_PKG)


##@ Deploy

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config or KUBECONFIG.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config or KUBECONFIG.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config or KUBECONFIG.
	cd config/manager && $(KUSTOMIZE) edit set image $(APP_NAME)=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

undeploy: manifests kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config or KUBECONFIG.
	$(KUSTOMIZE) build config/default | kubectl delete -f -

.PHONY: tear-down
tear-down: undeploy uninstall ## Run undeploy and uninstall targets.

.PHONY: catalog-deploy
catalog-deploy: namespace ## Deploy from the config/catalog sources.
	@echo "WARNING: This will temporarily modify config/catalog/catalog-source.yaml"
	@echo "Replacing image reference in config/catalog/catalog-source.yaml"
	@sed -i 's%quay.io/file-integrity-operator/file-integrity-operator-catalog:latest%$(CATALOG_IMG)%' config/catalog/catalog-source.yaml
	@oc apply -f config/catalog/catalog-source.yaml
	@echo "Restoring image reference in config/catalog/catalog-source.yaml"
	@sed -i 's%$(CATALOG_IMG)%quay.io/file-integrity-operator/file-integrity-operator-catalog:latest%' config/catalog/catalog-source.yaml
	@oc apply -f config/catalog/operator-group.yaml
	@oc apply -f config/catalog/subscription.yaml

.PHONY: catalog-undeploy
catalog-undeploy: undeploy
	@oc delete -f config/catalog/

##@ Push

.PHONY: push
push: image-push bundle-push ## Push the operator and bundle images.

image-push: ## Push the operator image.
	$(RUNTIME) push ${IMG}

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) image-push IMG=$(BUNDLE_IMG)

.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) image-push IMG=$(CATALOG_IMG)


##@ Testing

.PHONY: test-unit
test-unit: fmt vet ## Run tests.
	$(GO) test $(PKGS)

.PHONY: e2e
e2e: e2e-set-image prep-e2e
	@$(GO) test ./tests/e2e $(E2E_GO_TEST_FLAGS) -args $(E2E_ARGS)

.PHONY: prep-e2e
prep-e2e: kustomize
	rm -rf $(TEST_SETUP_DIR)
	mkdir -p $(TEST_SETUP_DIR)
	$(KUSTOMIZE) build config/e2e > $(TEST_DEPLOY)
	$(KUSTOMIZE) build config/crd > $(TEST_CRD)

ifdef IMAGE_FROM_CI
e2e-set-image: kustomize
	cd config/manager && $(KUSTOMIZE) edit set image $(APP_NAME)=$(IMAGE_FROM_CI)
else
e2e-set-image: kustomize
	cd config/manager && $(KUSTOMIZE) edit set image $(APP_NAME)=$(IMG)
endif

##@ Release

.PHONY: package-version-to-tag
package-version-to-tag: check-operator-version
	@echo "Overriding default tag '$(TAG)' with release tag '$(VERSION)'"
	$(eval TAG = $(VERSION))

.PHONY: git-release
git-release: fetch-git-tags package-version-to-tag changelog
	git checkout -b "release-v$(TAG)"
	sed -i "s/\(.*Version = \"\).*/\1$(TAG)\"/" version/version.go
	sed -i "s/\(.*VERSION?=\).*/\1$(TAG)/" version.Makefile
	git add version* bundle CHANGELOG.md config/manifests/bases
	git restore config/manager/kustomization.yaml

.PHONY: fetch-git-tags
fetch-git-tags:
	# Make sure we are caught up with tags
	git fetch -t

.PHONY: prepare-release
prepare-release: package-version-to-tag images git-release

.PHONY: push-release
push-release: package-version-to-tag ## Do an official release (Requires permissions)
	git commit -m "Release v$(TAG)"
	git tag "v$(TAG)"
	git push $(GIT_OPTS) $(GIT_REMOTE) "v$(TAG)"
	git push $(GIT_OPTS) $(GIT_REMOTE) "release-v$(TAG)"

.PHONY: release-images
release-images: package-version-to-tag push catalog
	# This will ensure that we also push to the latest tag
	$(MAKE) push TAG=latest

.PHONY: changelog
changelog:
	@utils/update_changelog.sh "$(TAG)"
