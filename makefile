.PHONY: \
	help \
	image-build \
	k8s-apply \
	k8s-cluster-create \
	k8s-cluster-delete \
	k8s-cluster-list \
	k8s-delete \
	k8s-port-forward-gateway \
	k8s-use-cluster

ENV ?= dev

# ヘルプを表示する
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^# /{ desc=$$0; sub(/^# /, "", desc) } /^[a-zA-Z0-9_-]+:/{ if(desc) { sub(/:.*/, "", $$1); printf "  %-20s %s\n", $$1, desc; desc="" } }' $(MAKEFILE_LIST)

# 接続可能なKubernetesクラスターの一覧を表示する
k8s-cluster-list:
	kubectl config get-clusters

# 指定したクラスター（コンテキスト）に接続先を切り替える（例: make k8s-use-cluster CLUSTER=kind-kind-multinode）
k8s-use-cluster:
	@if [ -z "$(CLUSTER)" ]; then \
		echo "Usage: make k8s-use-cluster CLUSTER=<cluster-name>"; \
		exit 1; \
	fi
	kubectl config use-context $(CLUSTER)

# Kindを使ってマルチノードのKubernetesクラスターを作成する
k8s-cluster-create:
	# kind create cluster -n kind-multinode --config ./kind/multinode-config.yaml --image=kindest/node:v1.33.12
	kind create cluster -n kind-multinode --config ./kind/multinode-nodeport.yaml --image=kindest/node:v1.33.12

# 作成したKindクラスターを削除する
k8s-cluster-delete:
	kind delete cluster -n kind-multinode

# Dockerイメージをビルドし、Kindクラスター（kind-multinode）に読み込ませる
image-build:
	docker build -t todo-api:latest ./app/api
	kind load docker-image todo-api:latest --name kind-multinode

# 全マニフェストをクラスタに適用する (例: make k8s-apply ENV=dev)
k8s-apply:
	echo "apply manifests for $(ENV) environment"
	kubectl apply -k ./k8s-todo-kustomize/overlays/$(ENV)
	kubectl apply -f ./k8s-todo/gateway-class.yaml
	kubectl apply -f ./k8s-todo/todo-gateway.yaml
	kubectl apply -f ./k8s-todo/metallb-config.yaml
	kubectl apply -f ./k8s-todo/todo-httproute.yaml
	echo "Done!!"

# 全マニフェストをクラスタから削除する (例: make k8s-delete ENV=dev)
k8s-delete:
	echo "delete manifests for $(ENV) environment"
	kubectl delete -f ./k8s-todo/todo-httproute.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/metallb-config.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/todo-gateway.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/gateway-class.yaml --ignore-not-found
	kubectl delete -k ./k8s-todo-kustomize/overlays/$(ENV) --ignore-not-found
	echo "Done!!"

# GatewayのServiceをポートフォワードする（リソース名が動的生成されるためラベルで検索）
k8s-port-forward-gateway:
	@SVC_NAME=$$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=todo-gateway,gateway.envoyproxy.io/owning-gateway-namespace=default -o jsonpath='{.items[0].metadata.name}'); \
	if [ -z "$$SVC_NAME" ]; then \
		echo "Gateway service not found."; \
		exit 1; \
	fi; \
	echo "Port-forwarding to $$SVC_NAME..."; \
	kubectl port-forward svc/$$SVC_NAME -n envoy-gateway-system 8080:80
