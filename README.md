# k8s-handson-work


## Gateway APIが解決すること

|機能|Ingress|Gateway API|
|:---|:---|:---|
|HTTP/HTTPSルーティング|あり|あり|
|パスベースルーティング|あり|あり|
|トラフィック分割|アノテーションのみ|ネイティブサポート|
|ヘッダーベースルーティング|アノテーションのみ|ネイティブサポート|
|リダイレクト|アノテーションのみ|ネイティブサポート|
|役割分担(インフラ/アプリ)|不十分|明確に定義|

### GatewayClass

インフラストラクチャプロバイダーが管理するリソース。どのコントローラーがGatewayを実装するのかを定義します。
StorageClassのGateway版と考えると理解やすい。

### Gateway

クラスタ運用者が管理するリソース。「どのポートで」「どのプロトコルで」トラフィックを受け付けるかを定義します。

### HTTP Route

アプリ開発者が管理するリソース。「どのパスに来たリクエストを」「どのServiceに」転送するかを定義します。

####　Gateway　API CRDインストール

CRD(Custom Resource Definition)として追加でインストール

```bash
 kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

#### Envoy Gateway をインストールする

```bash
kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.3.0/install.yaml
```

## MetalLBの導入手順（ローカル環境でのLoadBalancer対応）

Kindなどのローカル環境でGateway API（LoadBalancer Service）にIPアドレスを割り当てるために、MetalLBをインストールします。

### 1. MetalLBのインストール

MetalLBの公式マニフェストを適用してインストールします。

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
```

Podが起動してReadyになるまで少し待ちます。

```bash
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

### 2. IPアドレスプールの設定

MetalLBがLoadBalancerに割り当てるIPアドレスの範囲を指定します。
KindクラスタのDockerネットワークのサブネット（今回お使いの環境では `172.20.0.0/16`）から、他と競合しない範囲（例: `172.20.255.200-172.20.255.250`）を指定します。

以下のコマンドを実行して、IPアドレスを割り当てるための設定リソース（`IPAddressPool` と `L2Advertisement`）を作成します。

```bash
kubectl apply -f k8s-todo/metallb-config.yaml
```

### 3. GatewayへのIPアドレス割り当て確認

MetalLBの設定が完了すると、自動的にEnvoy GatewayのLoadBalancer ServiceにIPが割り当てられます。
しばらく待ってから、以下のコマンドを実行し `PROGRAMMED` が `True` になり、`ADDRESS` にIPが表示されるか確認してください。

```bash
# ServiceにEXTERNAL-IPが付与されていることを確認
kubectl get svc -n envoy-gateway-system

# GatewayがPROGRAMMEDになり、ADDRESSが表示されることを確認
kubectl get gateways
```

### 4. Mac（ローカル）からのアクセス確認

Mac環境（Docker Desktopなど）からKindクラスタ内のMetalLBのIPへ直接アクセスすることはネットワークの仕様上できません。そのため、`kubectl port-forward` を使ってアクセス確認を行います。

1. **ポートフォワードの実行:**
   別のターミナルを開き、GatewayのServiceをMacのローカルポート（ここでは8080）に転送します。
   
   ```bash
   # Service名は環境によって異なるため、適宜 kubectl get svc -n envoy-gateway-system で確認してください
   kubectl port-forward svc/envoy-default-todo-gateway-0a9e0667 -n envoy-gateway-system 8080:80
   ```

2. **curlでの動作確認:**
   元のターミナルから `localhost:8080` に対してアクセスし、それぞれのアプリケーションにルーティングされているか確認します。
   
   ```bash
   # /api/ へのアクセス (todo-api へのルーティング)
   curl http://localhost:8080/api/
   
   # / へのアクセス (todo-frontend へのルーティング)
   curl http://localhost:8080/
   ```
