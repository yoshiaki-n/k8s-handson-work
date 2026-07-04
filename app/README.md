# Todo App — サンプルアプリケーション

「Kubernetes入門ハンズオン」全章で使用する3層Todoアプリケーションです。

書籍: 「Kubernetes入門ハンズオン: minikubeで学ぶPod・Service・Helm 4」

## アーキテクチャ

```
[ブラウザ] → [Frontend: nginx] → [API: Go] → [DB: PostgreSQL]
```

| レイヤー | 技術 | ポート |
|---------|------|--------|
| Frontend | nginx 1.27 + 静的HTML | 80 |
| API | Go 1.24 (net/http) | 8080 |
| DB | PostgreSQL 16 | 5432 |

## ローカル実行（Docker Compose）

```bash
docker compose up -d
```

## 動作確認

```bash
# フロントエンド表示
curl http://localhost:8080

# Todo 一覧取得（空配列）
curl http://localhost:8080/api/todos

# Todo 作成
curl -X POST http://localhost:8080/api/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Kubernetesを学ぶ"}'

# Todo 完了
curl -X PUT http://localhost:8080/api/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"completed":true}'

# Todo 削除
curl -X DELETE http://localhost:8080/api/todos/1
```

## クリーンアップ

```bash
docker compose down -v
```

## 環境変数（API サーバー）

| 変数名 | デフォルト | 説明 |
|--------|-----------|------|
| DB_HOST | localhost | PostgreSQL ホスト名 |
| DB_PORT | 5432 | PostgreSQL ポート |
| DB_NAME | tododb | データベース名 |
| DB_USER | postgres | ユーザー名 |
| DB_PASSWORD | postgres | パスワード |
| PORT | 8080 | API サーバーポート |

> **Note**: Docker Compose（ローカル確認用）のデフォルト認証情報は `postgres`/`postgres` です。
> 第6章以降のKubernetesマニフェストでは `todouser`/`todopassword` を使用します（ConfigMap + Secret で外部化）。

## API エンドポイント

| メソッド | パス | 機能 |
|---------|------|------|
| GET | /healthz | ヘルスチェック（Container Probes 用） |
| GET | /api/todos | Todo 一覧取得 |
| POST | /api/todos | Todo 作成 |
| PUT | /api/todos/{id} | Todo 更新 |
| DELETE | /api/todos/{id} | Todo 削除 |
