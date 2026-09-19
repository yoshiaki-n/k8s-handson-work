#!/bin/bash
set -euo pipefail
echo "⚠️  EKS クラスターを削除します。これにより AWS の課金が停止します。"
echo ""
read -p "本当に削除しますか？ (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "キャンセルしました。"
  exit 0
fi

echo "LoadBalancer リソースの事前確認..."
kubectl get svc --all-namespaces -o wide | grep LoadBalancer || echo "LoadBalancer なし"
kubectl get gateway --all-namespaces 2>/dev/null || echo "Gateway なし"

echo ""
echo "EKS クラスターを削除中...（10〜15分かかります）"
eksctl delete cluster -f 01-cluster-config.yaml --wait

echo ""
echo "Done. AWS マネジメントコンソールで以下を確認してください:"
echo "  - EKS コンソール: クラスターが存在しないこと"
echo "  - EC2 コンソール: 関連するインスタンスが終了していること"
echo "  - VPC コンソール: eksctl が作成した VPC が削除されていること"
