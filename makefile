.PHONY: \
	help \
	image-build \
	k8s-apply-all \
	k8s-apply-api \
	k8s-apply-api-service \
	k8s-apply-db \
	k8s-apply-db-service \
	k8s-apply-frontend \
	k8s-apply-frontend-service \
	k8s-cluster-create \
	k8s-cluster-delete \
	k8s-cluster-list \
	k8s-delete-all \
	k8s-use-cluster

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

# データベース（todo-db） Deployment のマニフェストをクラスターに適用する
k8s-apply-db:
	kubectl apply -f ./k8s-todo/todo-db-deployment.yaml

# API（todo-api） Deployment のマニフェストをクラスターに適用する
k8s-apply-api:
	kubectl apply -f ./k8s-todo/todo-api-deployment.yaml

# フロントエンド（todo-frontend） Deployment のマニフェストをクラスターに適用する
k8s-apply-frontend:
	kubectl apply -f ./k8s-todo/todo-frontend-deployment.yaml

# 全マニフェストをクラスタに適用する
k8s-apply-all:
	echo "apply all manifests"
	$(MAKE) k8s-apply-db
	$(MAKE) k8s-apply-api
	$(MAKE) k8s-apply-frontend
	kubectl apply -f ./k8s-todo/gateway-class.yaml
	kubectl apply -f ./k8s-todo/todo-gateway.yaml
	kubectl apply -f ./k8s-todo/metallb-config.yaml
	kubectl apply -f ./k8s-todo/todo-httproute.yaml
	echo "Done!!"

# データベース（todo-db） Service のマニフェストをクラスターに適用する
k8s-apply-db-service:
	kubectl apply -f ./k8s-todo/todo-db-service.yaml

# API（todo-api） Service のマニフェストをクラスターに適用する
k8s-apply-api-service:
	kubectl apply -f ./k8s-todo/todo-api-service.yaml

# Frontend（todo-frontend） Service のマニフェストをクラスターに適用する
k8s-apply-frontend-service:
	kubectl apply -f ./k8s-todo/todo-frontend-service.yaml

# 全マニフェストをクラスタから削除する
k8s-delete-all:
	echo "delete all manifests"
	kubectl delete -f ./k8s-todo/todo-httproute.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/metallb-config.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/todo-gateway.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/gateway-class.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/todo-db-deployment.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/todo-api-deployment.yaml --ignore-not-found
	kubectl delete -f ./k8s-todo/todo-frontend-deployment.yaml --ignore-not-found
	echo "Done!!"

