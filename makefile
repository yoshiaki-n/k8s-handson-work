.PHONY: \
	help \
	image-build \
	k8s-contexts \
	k8s-current-context \
	k8s-use-context \
	k8s-namespace-create \
	k8s-setup-gateway \
	k8s-setup-sealed-secrets \
	k8s-setup-monitoring \
	k8s-port-forward-monitoring \
	k8s-cluster-create \
	k8s-cluster-delete \
	k8s-cluster-list \
	k8s-port-forward-gateway \
	helm-template \
	helm-install \
	helm-upgrade \
	helm-deploy-ecr \
	helm-rollback \
	helm-uninstall \
	helm-port-forward-frontend \
	eks-cluster-dry-run \
	eks-cluster-create \
	eks-cluster-delete

ENV ?= dev

# ヘルプを表示する
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^# /{ desc=$$0; sub(/^# /, "", desc) } /^[a-zA-Z0-9_-]+:/{ if(desc) { sub(/:.*/, "", $$1); printf "  %-20s %s\n", $$1, desc; desc="" } }' $(MAKEFILE_LIST)

# 接続可能なKubernetesコンテキストの一覧を表示する
k8s-contexts:
	kubectl config get-contexts

# 現在のKubernetesコンテキストを表示する
k8s-current-context:
	kubectl config current-context

# Kubernetesコンテキストを切り替える (例: make k8s-use-context CTX=kind-kind)
k8s-use-context:
	@if [ -z "$(CTX)" ]; then \
		echo "Error: CTX is required. Usage: make k8s-use-context CTX=<context-name>"; \
		exit 1; \
	fi
	kubectl config use-context $(CTX)

# Create todo-app namespace
k8s-namespace-create:
	kubectl create namespace todo-app --dry-run=client -o yaml | kubectl apply -f -

# Gateway API, Envoy Gateway, MetalLBの前提リソースをインストールする
k8s-setup-gateway:
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
	kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.3.0/install.yaml
	kubectl apply --server-side -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
	kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s

# SealedSecretsのコントローラーをインストールする
k8s-setup-sealed-secrets:
	helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
	helm repo update
	helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system --create-namespace

# Helm ChartでPrometheus Stackをインストールする
k8s-setup-monitoring:
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update
	kubectl create configmap todo-app-dashboard --from-file=todo-app-dashboard.json=monitoring/grafana-dashboard.json -n monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring -f monitoring/prometheus-values.yaml
	kubectl apply -f monitoring/servicemonitor.yaml
	kubectl apply -f monitoring/alert-rules.yaml

k8s-port-forward-monitoring:
	kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80

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
	helm upgrade --install todo-release ./todo-app -n todo-app

# ECR上の最新イメージ（Gitのコミットハッシュ）を使用してHelmデプロイ（アップグレード）を行う
helm-deploy-ecr:
	@AWS_ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \
	ECR_REGISTRY=$${AWS_ACCOUNT_ID}.dkr.ecr.ap-northeast-1.amazonaws.com; \
	GIT_HEAD=$$(git rev-parse HEAD); \
	echo "Deploying images from: $$ECR_REGISTRY with tag: $$GIT_HEAD"; \
	helm upgrade --install todo-release ./todo-app -n todo-app --create-namespace \
		--set api.image.repository=$$ECR_REGISTRY/todo-api \
		--set api.image.tag=$$GIT_HEAD \
		--set frontend.image.repository=$$ECR_REGISTRY/todo-frontend \
		--set frontend.image.tag=$$GIT_HEAD

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
	kubectl port-forward svc/todo-frontend 8080:80 -n todo-app

# EKSクラスター定義のDry-Run
eks-cluster-dry-run:
	eksctl create cluster -f eks/cluster-config.yaml --dry-run

# EKSクラスターの作成
eks-cluster-create:
	eksctl create cluster -f eks/cluster-config.yaml

# EKSクラスターの削除
eks-cluster-delete:
	eksctl delete cluster -f eks/cluster-config.yaml --wait

# AWS POD用のロール作成
create-pod-iam-role:
	# IAMロールの作成
	aws iam create-role \
	--role-name todo-eks-ebs-csi-role \
	--assume-role-policy-document file://eks/trust-policy.json
	# AWSマネージドポリシーのアタッチ
	aws iam attach-role-policy \
	--role-name todo-eks-ebs-csi-role \
	--policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
	# Pod Identityの関連付
	aws eks create-pod-identity-association \
	--cluster-name todo-eks-cluster \
	--namespace kube-system \
	--service-account ebs-csi-controller-sa \
	--role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/todo-eks-ebs-csi-role
