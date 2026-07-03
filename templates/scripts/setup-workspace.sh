#!/usr/bin/env bash
#
# setup-workspace.sh — 新メンバーの初回セットアップ用スクリプト。
#
# やること:
#   1. 前提ツールの確認（git / gh / gh auth status）
#   2. sync-repos.sh を呼び出して権限のあるリポを一括clone
#   3. ワークスペース直下にコンテキストファイルが無ければ、
#      templates/ 配下のテンプレートをコピー（案内 or コピー実行）
#   4. ローカル専用フォルダの作成（LOCAL_DIRS 配列で定義。デフォルトは空）
#   5. 完了メッセージ（AIエージェント起動の案内）
#
# 使い方（ターミナルで実行）:
#   bash templates/scripts/setup-workspace.sh
#
# ※ 実際のワークスペースでは、このスクリプトを workspace-setup 相当のリポジトリ
#    （ワークスペース直下）の scripts/ に置く。sync-repos.sh と同ディレクトリに置くこと。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ワークスペースルート = スクリプト位置の2階層上
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- ローカル専用フォルダ（Git管理しない作業用フォルダ）---
# チームごとに異なるため、必要なものをここに追記する。デフォルトは空。
# 例: LOCAL_DIRS=("websites" "downloads")
LOCAL_DIRS=()

# コピー対象のコンテキストファイル。
# "コピー先ファイル名:テンプレート相対パス（TEMPLATES_DIR基準）" で指定。
# ワークスペース直下に同名ファイルが無ければコピーする。
CONTEXT_FILES=(
  "CLAUDE.md:CLAUDE.md"
  "AGENTS.md:AGENTS.md"
)
# テンプレート格納ディレクトリ（scripts/ と同階層の templates/ を想定。
# つまり workspace-setup リポジトリの templates/ にテンプレート原本を置く）
TEMPLATES_DIR="$SCRIPT_DIR/../templates"

echo "========================================"
echo " ワークスペース初回セットアップ"
echo "========================================"
echo "ワークスペース: $WORKSPACE_ROOT"
echo

# --- Step 1: 前提ツールの確認 ---
echo "[1/4] 前提ツールの確認"
if ! command -v git >/dev/null 2>&1; then
  echo "  ✗ git が見つかりません。git をインストールしてください。" >&2
  exit 1
fi
echo "  ✓ git: $(git --version)"

HAS_GH=0
if command -v gh >/dev/null 2>&1; then
  HAS_GH=1
  echo "  ✓ gh: $(gh --version | head -n1)"
  if gh auth status >/dev/null 2>&1; then
    echo "  ✓ gh 認証済み"
  else
    echo "  ⚠ gh 未認証です。'gh auth login' で認証すると private リポも clone できます。"
  fi
else
  echo "  ⚠ gh が見つかりません。git clone（https）で続行します。"
  echo "    （private リポを clone するには gh CLI か認証情報の設定が必要です）"
fi
echo

# --- Step 2: リポジトリの一括clone ---
echo "[2/4] リポジトリの同期（sync-repos.sh）"
if [ -f "$SCRIPT_DIR/sync-repos.sh" ]; then
  bash "$SCRIPT_DIR/sync-repos.sh"
else
  echo "  ⚠ sync-repos.sh が見つかりません（$SCRIPT_DIR）。同期をスキップします。"
fi
echo

# --- Step 3: コンテキストファイルのコピー ---
echo "[3/4] AIコンテキストファイルの配置"
for entry in "${CONTEXT_FILES[@]}"; do
  dest_name="${entry%%:*}"
  src_rel="${entry#*:}"
  dest="$WORKSPACE_ROOT/$dest_name"
  src="$TEMPLATES_DIR/$src_rel"

  if [ -e "$dest" ]; then
    echo "  ✓ 既存: $dest_name（そのまま利用）"
    continue
  fi
  if [ -f "$src" ]; then
    cp "$src" "$dest"
    echo "  ✔ コピー: $src_rel → $dest_name"
  else
    echo "  ⏭  テンプレート未提供: $src_rel（$dest_name は手動で用意してください）"
  fi
done
echo

# --- Step 4: ローカル専用フォルダの作成 ---
echo "[4/4] ローカル専用フォルダの作成"
if [ "${#LOCAL_DIRS[@]}" -eq 0 ]; then
  echo "  （LOCAL_DIRS は空です。必要ならスクリプト冒頭で定義してください）"
else
  for d in "${LOCAL_DIRS[@]}"; do
    mkdir -p "$WORKSPACE_ROOT/$d"
    echo "  ✔ 作成: $d/"
  done
fi
echo

echo "========================================"
echo " セットアップ完了"
echo "========================================"
echo "ワークスペースで AIエージェントを起動してください（ターミナルで実行）:"
echo
echo "    claude   # Claude Code の場合"
echo "    codex    # Codex の場合"
echo
echo "起動したら「今日の作業を始めたい」等と話しかければOKです。"
