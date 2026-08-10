.PHONY: \
	help \
	image-build \
	k8s-namespace-create \
	k8s-apply \
	k8s-cluster-create \
	k8s-cluster-delete \
	k8s-cluster-list \
	k8s-delete \
	k8s-port-forward-gateway \
	k8s-use-cluster \
	helm-template \
	helm-install \
	helm-upgrade \
	helm-rollback \
	helm-uninstall \
	helm-port-forward-frontend

ENV ?= dev

# ヘルプを表示する
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^# /{ desc=$$0; sub(/^# /, "", desc) } /^[a-zA-Z0-9_-]+:/{ if(desc) { sub(/:.*/, "", $$1); printf "  %-20s %s\n", $$1, desc; desc="" } }' $(MAKEFILE_LIST)

# Create todo-app namespace
k8s-namespace-create:
	kubectl create namespace todo-app

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
	docker build -t yoshiakin/todo-api:v1.0.0 ./app/api
	docker build -t yoshiakin/todo-frontend:v1.0.0 ./app/frontend
	kind load docker-image yoshiakin/todo-api:v1.0.0 --name kind-multinode
	kind load docker-image yoshiakin/todo-frontend:v1.0.0 --name kind-multinode

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

# Helm templateの確認
helm-template:
	helm template todo-release ./todo-app

# Helm install（todo-app namespaceに自動作成してインストール）
helm-install:
	helm install todo-release ./todo-app -n todo-app --create-namespace

# Check Helm
helm-list:
	helm list -n todo-app

# Upgrade Helm
helm-upgrade:
	helm upgrade todo-release ./todo-app -n todo-app

# history Helm
helm-history:
	helm history todo-release -n todo-app

# Helmリリースを指定リビジョンにロールバックする（例: make helm-rollback REVISION=1）
helm-rollback:
	@if [ -z "$(REVISION)" ]; then \
		echo "エラー: リビジョン番号を指定してください"; \
		echo "Usage: make helm-rollback REVISION=<revision-number>"; \
		echo ""; \
		echo "利用可能なリビジョンは 'make helm-history' で確認できます"; \
		exit 1; \
	fi
	helm rollback todo-release $(REVISION) -n todo-app

# Uninstall Helm
helm-uninstall:
	helm uninstall todo-release -n todo-app

# フロントエンドのServiceをlocalhost:8080でポートフォワードする
helm-port-forward-frontend:
	kubectl port-forward svc/todo-release-frontend 8080:80 -n todo-app
