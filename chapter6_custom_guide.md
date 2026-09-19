# 第6章 ローカルからEKSへ移行する (カスタム手順)

この手順書は、本プロジェクト（Helm、Makefile、GitHub Actionsが導入済み）の現在の状況に合わせて、PDF教材の「第6章」をカスタマイズした移行手順です。

## 移行の前提条件
- 第5章で作成したEKSクラスター（`todo-eks-cluster`）が起動していること。
- AWS CLI, `eksctl`, `kubectl`, `helm` が使用可能であること。
- EKSクラスターへkubectlのコンテキストが切り替わっていること。

```bash
# EKSクラスターへのコンテキスト切り替え（例）
kubectl config use-context arn:aws:eks:ap-northeast-1:123871313128:cluster/todo-eks-cluster
```

---

## 1. 移行チェックリスト（本プロジェクト向け）

| 項目 | minikube環境 | EKS環境 | 変更対応 |
| --- | --- | --- | --- |
| GatewayClass | Envoy | AWS Load Balancer Controller (ALB) | **要変更** |
| StorageClass | standard / hostPath | EBS CSI Driver (gp3) | **要変更** |
| コンテナレジストリ | Docker Hub | Amazon ECR | **対応済** (`make helm-deploy-ecr` を利用) |
| ConfigMap / Secret | 手動作成 | Helm / SealedSecret管理 | **不要** (Helmデプロイ時に自動作成されるため手動移行は不要) |

---

## 2. AWS Load Balancer Controller のインストール

EKSでALBを自動構築するために、AWS Load Balancer Controller (AWS LBC) をインストールします。
*(※第5章で `todo-eks-lbc-role` のIAMロールやPod Identity関連付けが完了している前提です)*

### 2.1 Gateway API CRDs のインストール
AWS LBCを起動する前に、Gateway APIのCRDをインストールしておく必要があります。
```bash
# Gateway API (v1)のインストール
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v1.2.1" | kubectl apply -f -; }
```

### 2.2 AWS LBCのHelmインストール
```bash
# AWS Load Balancer Controller のインストール
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --version 1.14.0 \
  --set clusterName=todo-eks-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set controllerConfig.featureGates.ALBGatewayAPI=true
```

---

## 3. EKS向けマニフェストの適用準備

本プロジェクトではアプリケーション本体をHelmチャート (`todo-app/`) で管理しています。EKS移行に合わせて一部の設定を追加・修正します。

### 3.1 Gateway / GatewayClass の作成

EKS用のGatewayClassとALB設定を定義します。`eks/manifests/gateway.yaml` というファイルを作成し、以下の内容を保存してください。

```yaml
# eks/manifests/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: amazon-alb
spec:
  controllerName: gateway.k8s.aws/alb
---
apiVersion: gateway.k8s.aws/v1beta1
kind: LoadBalancerConfiguration
metadata:
  name: todo-lb-config
  namespace: todo-app
spec:
  scheme: internet-facing
  ipAddressType: ipv4
---
apiVersion: gateway.k8s.aws/v1beta1
kind: TargetGroupConfiguration
metadata:
  name: todo-frontend-tgc
  namespace: todo-app
spec:
  targetReference:
    kind: Service
    name: todo-frontend
  defaultConfiguration:
    targetType: ip
---
apiVersion: gateway.k8s.aws/v1beta1
kind: TargetGroupConfiguration
metadata:
  name: todo-api-tgc
  namespace: todo-app
spec:
  targetReference:
    kind: Service
    name: todo-api
  defaultConfiguration:
    targetType: ip
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: todo-gateway
  namespace: todo-app
spec:
  gatewayClassName: amazon-alb
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: todo-lb-config
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: todo-route
  namespace: todo-app
spec:
  parentRefs:
  - name: todo-gateway
    namespace: todo-app
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api/
    backendRefs:
    - name: todo-api
      port: 8080
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: todo-frontend
      port: 80
```

### 3.2 StorageClass の作成

`eks/manifests/storageclass.yaml` を作成します。

```yaml
# eks/manifests/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

### 3.3 Helmチャート (PostgreSQL) の修正

EBSボリュームのマウント時に `lost+found` ディレクトリが存在するとDB初期化に失敗するため、`todo-app/templates/db-deployment.yaml` を修正し `subPath` を追加します。

```yaml
# todo-app/templates/db-deployment.yaml の volumeMounts 部分を以下のように修正します
          volumeMounts:
            - name: db-data
              mountPath: /var/lib/postgresql/data
              subPath: pgdata   # ← この行を追加
```

---

## 4. アプリケーションのデプロイ (Helm & ECR)

EKS用のインフラ設定を適用します。

```bash
# EKS用マニフェストの適用
kubectl apply -f eks/manifests/storageclass.yaml
kubectl apply -f eks/manifests/gateway.yaml
```

続いて、アプリケーションをデプロイしますが、**新しいEKSクラスターへ初めてデプロイする場合は事前準備と注意点があります**。

### 4.1 Sealed Secretsコントローラーのインストール
Helmチャート内に `SealedSecret` リソースが含まれているため、事前にCRDとコントローラーをインストールしておかないとデプロイ時にエラー（`no matches for kind "SealedSecret"`）になります。

```bash
# Sealed Secretsのインストール
make k8s-setup-sealed-secrets
```

### 4.2 SealedSecretの再暗号化（重要）
Helmチャート内の `sealed-secret.yaml` は、移行前のクラスター（minikube）の公開鍵で暗号化されています。新しいEKSクラスターでは復号できず、`todo-db` の起動時に `CreateContainerConfigError` （Secretが見つからないエラー）が発生します。
必ず以下のコマンドで再暗号化を行ってください。

```bash
# 新しいクラスターの鍵で再暗号化して上書きする
kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml < secret-raw.yaml > todo-app/templates/sealed-secret.yaml
```

### 4.3 アプリケーションのデプロイ

既存のMakefileを活用して、ECRから最新のイメージを使ってHelmデプロイを行います。

> [!WARNING]
> 新しいクラスターへの初回デプロイ時、既存の `makefile` のまま `make helm-deploy-ecr` を実行すると、`helm upgrade` コマンドが「アップグレード対象のリリースが存在しない」としてエラー（`UPGRADE FAILED: "todo-release" has no deployed releases`）になります。
> 実行前に `makefile` の `helm-deploy-ecr` ターゲットを修正し、`helm upgrade --install` と `--create-namespace` を追加してください（すでに修正済みの場合はそのまま進めてください）。

```bash
# todo-app のデプロイ
make helm-deploy-ecr
```

---

## 5. 動作確認

Podが正常に起動しているか確認します。
```bash
kubectl get pods -n todo-app -w
```

ALBが作成され、DNS名が割り当てられたか確認します。
```bash
kubectl get gateway -n todo-app
```
`ADDRESS` 欄に表示されたURL (例: `k8s-todoapp-todogatew-...elb.amazonaws.com`) にブラウザでアクセスして、アプリケーションが表示されることを確認します。

---

## 6. トラブルシューティング（EKS移行時のよくあるエラー）

### 6.1 `todo-api` / `todo-frontend` が `ImagePullBackOff` になる
* **原因**: `make helm-deploy-ecr` は現在のローカルのGitコミットハッシュ（`git rev-parse HEAD`）をタグとしてECRからイメージを取得しようとします。しかし、`app/` ディレクトリ配下を変更せずにコミット（例: Makefileの修正のみ）している場合、GitHub Actionsがトリガーされず、ECRにそのハッシュのイメージが存在しないためPullに失敗します。
* **対策**: `app/` 配下にダミーの変更を加えてコミット＆プッシュし、GitHub Actionsでイメージをビルドさせるか、`makefile` の `GIT_HEAD` 取得部分を `latest` に一時的に書き換えてデプロイしてください。

### 6.2 `todo-db` が `CreateContainerConfigError` になる
* **原因**: `todo-db-secret` が存在しません。Sealed Secretsコントローラーがインストールされていないか、古いクラスターの公開鍵で暗号化されたままのため復号に失敗しています。
* **対策**: 本手順の `4.1` と `4.2` を再確認し、`make k8s-setup-sealed-secrets` の実行と、`kubeseal` による再暗号化を行ってから再デプロイしてください。

---

## 7. ArgoCDの接続 (GitOpsの再開)

EKSクラスター上にArgoCDをインストールし、GitOps環境を再構築します。

```bash
# ArgoCDのインストール
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.7/manifests/install.yaml
```

ArgoCDが立ち上がったら、既存の `argocd/todo-app.yaml` を適用してGitOpsの同期を開始します。
※ この時、Git上の `sealed-secret.yaml` もEKS用に再暗号化したものに更新してプッシュしておく必要があります。

```bash
kubectl apply -f argocd/todo-app.yaml
```

これで、ローカル（minikube）で動作していたアプリケーションとGitOps環境が、完全にAmazon EKSへ移行されました。
