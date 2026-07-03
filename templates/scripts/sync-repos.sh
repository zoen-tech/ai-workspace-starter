#!/usr/bin/env bash
#
# sync-repos.sh — マニフェスト(repos.tsv)を正として、未cloneのリポジトリを
# ワークスペース直下に正しいフォルダ名で自動cloneする。
#
# 使い方（ターミナルで実行）:
#   bash templates/scripts/sync-repos.sh           # 同期実行
#   bash templates/scripts/sync-repos.sh --dry-run # 何が起きるか確認だけ
#
# ※ 実際のワークスペースでは、このスクリプトを workspace-setup 相当のリポジトリ
#    （ワークスペース直下）の scripts/ に置き、同ディレクトリに repos.tsv を置く。
#
# 動作:
#   - 既にclone済み(.gitあり)        → スキップ
#   - 未cloneでアクセス権あり         → clone（gh があれば gh、無ければ git https）
#   - 未cloneでアクセス権なし         → スキップ（権限なしと表示）
#   - GitHub org に在るがマニフェスト未登録 → ドリフト警告（追記を促す）
#
# 新メンバーは、権限付与後にこれを1回叩けば必要なリポが一式そろう。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ワークスペースルート = スクリプト位置の2階層上
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/repos.tsv"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

HAS_GH=0
command -v gh >/dev/null 2>&1 && HAS_GH=1

if [ ! -f "$MANIFEST" ]; then
  echo "✗ マニフェストが見つかりません: $MANIFEST" >&2
  exit 1
fi

echo "ワークスペース: $WORKSPACE_ROOT"
echo "マニフェスト:   $MANIFEST"
[ "$DRY_RUN" = 1 ] && echo "(dry-run: 実際のcloneは行いません)"
echo "----------------------------------------"

cloned=0; skipped=0; denied=0; failed=0
manifest_repos=""   # 登録済みリポ（ドリフト判定用）
manifest_orgs=""    # 登場したorg名（ドリフト検査対象）

# マニフェストを1行ずつ処理（タブ区切り、#と空行は無視）
while IFS=$'\t' read -r repo path kind _rest; do
  case "$repo" in ""|\#*) continue ;; esac
  [ -z "${path:-}" ] && continue
  manifest_repos="$manifest_repos $repo"

  # org名（repo の "/" より前）をユニーク抽出しておく。
  # external / personal / skip 区分の行のorgはドリフト検査対象にしない
  # （他者のorgや個人アカウントを検査すると、無関係なリポが大量に警告されるため）
  org="${repo%%/*}"
  case "${kind:-}" in
    external|personal|skip) : ;;
    *)
      case " $manifest_orgs " in
        *" $org "*) : ;;
        *) manifest_orgs="$manifest_orgs $org" ;;
      esac
      ;;
  esac

  # skip 指定はcloneしない
  if [ "${kind:-}" = "skip" ] || [ "$path" = "-" ]; then
    echo "⏭  skip指定: $repo"
    skipped=$((skipped+1)); continue
  fi

  dest="$WORKSPACE_ROOT/$path"
  if [ -d "$dest/.git" ]; then
    echo "✓ clone済み: $path"
    skipped=$((skipped+1)); continue
  fi
  if [ -e "$dest" ]; then
    echo "⚠  既存（.git無し）: $path — 手動確認してください"
    failed=$((failed+1)); continue
  fi

  echo "↓ clone対象: $repo → $path"
  if [ "$DRY_RUN" = 1 ]; then
    cloned=$((cloned+1)); continue
  fi

  mkdir -p "$(dirname "$dest")"
  if [ "$HAS_GH" = 1 ]; then
    if gh repo clone "$repo" "$dest" >/dev/null 2>&1; then
      echo "  ✔ 完了"; cloned=$((cloned+1))
    else
      echo "  ✗ 失敗（権限なし or 不存在）→ スキップ"; denied=$((denied+1))
    fi
  else
    if git clone "https://github.com/$repo.git" "$dest" >/dev/null 2>&1; then
      echo "  ✔ 完了"; cloned=$((cloned+1))
    else
      echo "  ✗ 失敗（権限なし or 認証未設定）→ スキップ"; denied=$((denied+1))
    fi
  fi
done < "$MANIFEST"

# ドリフト検出: マニフェストに登場した各 org について、
# GitHub上に在るがマニフェスト未登録のリポを警告する。
# （org名はハードコードせず、マニフェストから抽出したものを使う）
# gh CLI が無い場合はドリフト検出をスキップ。
if [ "$HAS_GH" = 1 ]; then
  echo "----------------------------------------"
  echo "ドリフト確認（各 org にあってマニフェスト未登録のリポ）:"
  drift=0
  for org in $manifest_orgs; do
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      case " $manifest_repos " in
        *" $org/$name "*) : ;;
        *) echo "  ⚠ 未登録: $org/$name → repos.tsv に追記してください"; drift=$((drift+1)) ;;
      esac
    done <<EOF
$(gh repo list "$org" --limit 200 --json name --jq '.[].name' 2>/dev/null)
EOF
  done
  [ "$drift" = 0 ] && echo "  なし（マニフェストは最新）"
fi

echo "----------------------------------------"
echo "結果: clone $cloned / 既存・skip $skipped / 権限なし $denied / 要確認 $failed"
