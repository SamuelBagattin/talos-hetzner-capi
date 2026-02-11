# Talos Kubernetes on Hetzner Cloud via Cluster API
#
# Prerequisites:
#   brew install kind helm packer kubectl
#   brew install siderolabs/tap/talosctl
#   curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.10.10/clusterctl-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) -o /usr/local/bin/clusterctl && chmod +x /usr/local/bin/clusterctl
#
# Usage:
#   export HCLOUD_TOKEN=$(op item get f3dybczercjvuktbt46hc5tkou --fields "api key" --reveal)
#   make image      # Build Talos image snapshot
#   make bootstrap  # Full cluster bootstrap
#   make pivot      # Move CAPI to self-managed

CLUSTER_NAME    ?= k8s
TALOS_VERSION   ?= v1.12.2
K8S_VERSION     ?= v1.35.0
LOCATION        ?= nbg1

# CAPI provider versions
# renovate: datasource=github-releases depName=kubernetes-sigs/cluster-api
CAPI_VERSION    ?= v1.12.2
# renovate: datasource=github-releases depName=syself/cluster-api-provider-hetzner
CAPH_VERSION    ?= v1.0.7
# renovate: datasource=github-releases depName=siderolabs/cluster-api-bootstrap-provider-talos
CABPT_VERSION   ?= v0.6.11
# renovate: datasource=github-releases depName=siderolabs/cluster-api-control-plane-provider-talos
CACPPT_VERSION  ?= v0.5.12
# renovate: datasource=github-releases depName=kubernetes-sigs/cluster-api-addon-provider-helm
CAAPH_VERSION   ?= v0.6.0

# Output paths
MGMT_KUBECONFIG ?= /tmp/$(CLUSTER_NAME)-mgmt.kubeconfig
WL_KUBECONFIG   ?= /tmp/$(CLUSTER_NAME).kubeconfig
TALOSCONFIG     ?= /tmp/$(CLUSTER_NAME).talosconfig

.PHONY: image bootstrap pivot clean \
        kind-create capi-init secret apply \
        wait-ready kubeconfig talosconfig \
        firewall firewall-apply \
        status

# ---------- Image Build ----------

image:
	@if [ -z "$$HCLOUD_TOKEN" ]; then echo "Error: HCLOUD_TOKEN not set"; exit 1; fi
	cd packer && packer init . && packer build -var "talos_version=$(TALOS_VERSION)" .

# ---------- Bootstrap Workflow ----------

bootstrap: kind-create capi-init secret apply wait-ready kubeconfig talosconfig
	@echo ""
	@echo "=== Bootstrap complete ==="
	@echo "Workload kubeconfig: $(WL_KUBECONFIG)"
	@echo "Talosconfig:         $(TALOSCONFIG)"
	@echo ""
	@echo "Next steps:"
	@echo "  make firewall       # Create Hetzner firewall (recommended)"
	@echo "  make firewall-apply # Apply firewall to cluster servers"
	@echo "  make pivot          # Move CAPI controllers to workload cluster"

kind-create:
	@echo "==> Creating kind bootstrap cluster..."
	kind create cluster --name $(CLUSTER_NAME)-mgmt 2>/dev/null || true
	kind get kubeconfig --name $(CLUSTER_NAME)-mgmt > $(MGMT_KUBECONFIG)

capi-init:
	@echo "==> Installing CAPI providers (including CAAPH)..."
	KUBECONFIG=$(MGMT_KUBECONFIG) clusterctl init \
		--config cluster-api/clusterctl.yaml \
		--core cluster-api:$(CAPI_VERSION) \
		--bootstrap talos:$(CABPT_VERSION) \
		--control-plane talos:$(CACPPT_VERSION) \
		--infrastructure hetzner:$(CAPH_VERSION) \
		--addon helm:$(CAAPH_VERSION)
	@echo "Waiting for controllers to be ready..."
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n capi-system --timeout=120s
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n caph-system --timeout=120s
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n cabpt-system --timeout=120s
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n cacppt-system --timeout=120s
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n caaph-system --timeout=120s

secret:
	@if [ -z "$$HCLOUD_TOKEN" ]; then echo "Error: HCLOUD_TOKEN not set"; exit 1; fi
	@echo "==> Creating Hetzner secret in management cluster..."
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl create secret generic hetzner \
		--from-literal=hcloud-token="$$HCLOUD_TOKEN" \
		--dry-run=client -o yaml | \
		KUBECONFIG=$(MGMT_KUBECONFIG) kubectl apply -f -
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl label secret hetzner \
		clusterctl.cluster.x-k8s.io/move="" --overwrite
	@echo "==> Creating hcloud-secret-manifest for ClusterResourceSet..."
	@echo "    (ClusterResourceSet will apply this manifest to the workload cluster)"
	@INNER=$$(printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: hcloud\n  namespace: kube-system\ntype: Opaque\nstringData:\n  token: "%s"\n  network: "%s"\n' "$$HCLOUD_TOKEN" "$(CLUSTER_NAME)"); \
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl create secret generic hcloud-secret-manifest \
		--from-literal="hcloud-secret.yaml=$$INNER" \
		--type="addons.cluster.x-k8s.io/resource-set" \
		--dry-run=client -o yaml | \
		KUBECONFIG=$(MGMT_KUBECONFIG) kubectl apply -f -

apply:
	@echo "==> Applying cluster and addon manifests..."
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl apply -f cluster-api/cluster.yaml
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl apply -f cluster-api/addons.yaml

wait-ready:
	@echo "==> Waiting for kubeconfig secret (server provisioning + Talos bootstrap)..."
	@echo "    This takes 5-10 minutes."
	@until KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get secret $(CLUSTER_NAME)-kubeconfig 2>/dev/null; do \
		echo "    Waiting for kubeconfig secret..."; \
		sleep 15; \
	done
	@echo "    Kubeconfig secret available."
	@echo "==> Waiting for nodes to become Ready (CAAPH installs addons automatically)..."
	@KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get secret $(CLUSTER_NAME)-kubeconfig \
		-o jsonpath='{.data.value}' | base64 -d > $(WL_KUBECONFIG)
	@chmod 600 $(WL_KUBECONFIG)
	@until [ "$$(KUBECONFIG=$(WL_KUBECONFIG) kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 1 ] 2>/dev/null; do \
		echo "    Waiting for at least 1 Ready node..."; \
		sleep 10; \
	done
	@echo "    Nodes are Ready."
	KUBECONFIG=$(WL_KUBECONFIG) kubectl get nodes -o wide
	@echo "==> Checking HelmChartProxy status..."
	-KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get helmchartproxy -o wide
	-KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get helmreleaseproxy -o wide

kubeconfig:
	@echo "==> Extracting workload kubeconfig..."
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get secret $(CLUSTER_NAME)-kubeconfig \
		-o jsonpath='{.data.value}' | base64 -d > $(WL_KUBECONFIG)
	chmod 600 $(WL_KUBECONFIG)
	@echo "    Written to $(WL_KUBECONFIG)"

talosconfig:
	@echo "==> Extracting talosconfig..."
	KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get secret $(CLUSTER_NAME)-talosconfig \
		-o jsonpath='{.data.talosconfig}' | base64 -d > $(TALOSCONFIG)
	chmod 600 $(TALOSCONFIG)
	@echo "    Written to $(TALOSCONFIG)"

# ---------- Firewall (CAPH doesn't manage firewalls) ----------

firewall:
	@echo "==> Creating Hetzner firewall..."
	hcloud firewall create --name $(CLUSTER_NAME)-firewall 2>/dev/null || true
	hcloud firewall add-rule $(CLUSTER_NAME)-firewall \
		--direction in --protocol tcp --port 6443 \
		--source-ips 10.0.0.0/8 --source-ips 172.16.0.0/12 --source-ips 192.168.0.0/16 \
		--description "Kubernetes API" 2>/dev/null || true
	hcloud firewall add-rule $(CLUSTER_NAME)-firewall \
		--direction in --protocol tcp --port 50000 \
		--source-ips 10.0.0.0/8 --source-ips 172.16.0.0/12 --source-ips 192.168.0.0/16 \
		--description "Talos API" 2>/dev/null || true
	@echo "    Firewall $(CLUSTER_NAME)-firewall created."

firewall-apply:
	@echo "==> Applying firewall to cluster servers..."
	@for server_id in $$(hcloud server list -o noheader -o columns=id,name | grep "$(CLUSTER_NAME)-" | awk '{print $$1}'); do \
		echo "    Applying to server $$server_id..."; \
		hcloud firewall apply-to-resource $(CLUSTER_NAME)-firewall --type server --server $$server_id 2>/dev/null || true; \
	done
	@echo "    Firewall applied."

# ---------- Pivot to Self-Managed ----------

pivot:
	@echo "==> Pivoting CAPI to workload cluster..."
	@if [ -z "$$HCLOUD_TOKEN" ]; then echo "Error: HCLOUD_TOKEN not set"; exit 1; fi
	@echo "    Installing CAPI providers on workload cluster..."
	KUBECONFIG=$(WL_KUBECONFIG) clusterctl init \
		--config cluster-api/clusterctl.yaml \
		--core cluster-api:$(CAPI_VERSION) \
		--bootstrap talos:$(CABPT_VERSION) \
		--control-plane talos:$(CACPPT_VERSION) \
		--infrastructure hetzner:$(CAPH_VERSION) \
		--addon helm:$(CAAPH_VERSION)
	@echo "    Waiting for controllers to be ready on workload cluster..."
	KUBECONFIG=$(WL_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n capi-system --timeout=120s
	KUBECONFIG=$(WL_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n caph-system --timeout=120s
	KUBECONFIG=$(WL_KUBECONFIG) kubectl wait --for=condition=Available deployment --all -n caaph-system --timeout=120s
	@echo "    Creating Hetzner secret on workload cluster..."
	KUBECONFIG=$(WL_KUBECONFIG) kubectl create secret generic hetzner \
		--from-literal=hcloud-token="$$HCLOUD_TOKEN" \
		--dry-run=client -o yaml | \
		KUBECONFIG=$(WL_KUBECONFIG) kubectl apply -f -
	KUBECONFIG=$(WL_KUBECONFIG) kubectl label secret hetzner \
		clusterctl.cluster.x-k8s.io/move="" --overwrite
	@echo "    Moving CAPI resources..."
	KUBECONFIG=$(MGMT_KUBECONFIG) clusterctl move \
		--to-kubeconfig=$(WL_KUBECONFIG)
	@echo ""
	@echo "=== Pivot complete ==="
	@echo "Management cluster can be deleted: make clean"

# ---------- Status & Utilities ----------

status:
	@echo "=== Management Cluster ==="
	-KUBECONFIG=$(MGMT_KUBECONFIG) clusterctl describe cluster $(CLUSTER_NAME) 2>/dev/null
	@echo ""
	-KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get helmchartproxy -o wide 2>/dev/null
	-KUBECONFIG=$(MGMT_KUBECONFIG) kubectl get helmreleaseproxy -o wide 2>/dev/null
	@echo ""
	@echo "=== Workload Cluster ==="
	-KUBECONFIG=$(WL_KUBECONFIG) kubectl get nodes -o wide 2>/dev/null
	@echo ""
	-KUBECONFIG=$(WL_KUBECONFIG) kubectl get pods -n kube-system 2>/dev/null

clean:
	@echo "==> Deleting kind management cluster..."
	kind delete cluster --name $(CLUSTER_NAME)-mgmt 2>/dev/null || true
	rm -f $(MGMT_KUBECONFIG)
	@echo "    Cleaned up."
