#!/bin/bash
# local-backup.sh — ワークスペース内のローカル専用ファイル（Git管理外）の暗号化バックアップ
#
# 対象: .env等の秘匿ファイル / ローカル専用フォルダ / CLI認証情報 /
#       launchd設定 / ~/.claude の設定・メモリ・スキル / ワークスペース直下のコンテキストファイル
# 方式: staging→tar→age暗号化（公開鍵）→ローカル復号検証→クラウドストレージへアップロード
#       →ダウンロード再検証→世代管理（保持数超過分を削除）→成功マーカー
# 失敗時: メールで通知
#
# 前提:
#   - age / rsync / python3 / Google Workspace CLI（gws）が利用できること
#   - ~/.config/backup/backup.conf に設定を定義（下の「設定読み込み」参照）
#   - ~/.config/backup/age.key（秘密鍵・復元用）と age.pub（公開鍵・暗号化用）
#   - 秘密鍵はバックアップ対象に含めない（保存先が侵害されても復号されないための設計）
#   - 設計思想・セットアップ・復元手順 → tutorial/08-local-backup.md
#
# 使い方（ターミナルで実行）:
#   bash scripts/local-backup.sh
#   （通常はlaunchd/cronから毎日1回実行する）

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CONF="$HOME/.config/backup/backup.conf"
AGE_PUB="$HOME/.config/backup/age.pub"
AGE_KEY="$HOME/.config/backup/age.key"
STATE_DIR="$HOME/.local/state/workspace-backup"
LOG="$STATE_DIR/backup.log"
LOCK="$STATE_DIR/lock.d"

# --- ワークスペース内のローカル専用フォルダ（Git管理外で失うと困るもの）---
# 環境ごとに異なるため、必要なものをここに追記する。デフォルトは空。
# WORKSPACE_DIR からの相対パスで、末尾に / を付けて指定する。
# 例: LOCAL_DIRS=("mcp-servers/" "apps-script/")
LOCAL_DIRS=()

mkdir -p "$STATE_DIR"
# ログの肥大化防止（5MB超で直近2000行に切り詰め）
if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG" 2>/dev/null || stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1
echo "===== backup start: $(date '+%Y-%m-%d %H:%M:%S') ====="

# gws が credentials.enc + keyring 認証の場合、旧環境変数が残っていると401になる
unset GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE 2>/dev/null || true
# gws を nvm 経由で入れている場合に備え、gws 実体を含む node バージョンの bin を解決する
for bin in $(ls -d "$HOME/.nvm/versions/node"/*/bin 2>/dev/null | sort -rV || true); do
  if [ -x "$bin/gws" ]; then export PATH="$bin:$PATH"; break; fi
done

# ---- 通知・エラーハンドラ（設定読み込みより先に仕込む） ----
NOTIFY_EMAIL=""   # conf読み込み前の失敗でも参照できるよう先に初期化
notify_failure() {
  local msg="$1"
  echo "[ERROR] $msg"
  [ -n "$NOTIFY_EMAIL" ] || { echo "[ERROR] NOTIFY_EMAIL未設定のためメール通知不可"; return 0; }
  command -v gws >/dev/null || { echo "[ERROR] gwsが見つからずメール通知不可"; return 0; }
  local subject="[ALERT] ローカルバックアップ失敗 ($(hostname)) $(date '+%m/%d %H:%M')"
  local subject_b64
  subject_b64=$(printf '%s' "$subject" | base64 | tr -d '\n')
  local body="local-backup.sh が失敗しました。

ホスト: $(hostname)
エラー: $msg

ログ: $LOG
復元手順: tutorial/08-local-backup.md"
  local raw
  raw=$(printf 'To: %s\nSubject: =?UTF-8?B?%s?=\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s' \
        "$NOTIFY_EMAIL" "$subject_b64" "$body" \
        | base64 | tr '+/' '-_' | tr -d '=\n')
  gws gmail users messages send --params '{"userId":"me"}' --json "{\"raw\":\"$raw\"}" \
    || echo "[ERROR] 失敗通知メールの送信にも失敗"
}

fail() { notify_failure "$1"; exit 1; }
on_error() { notify_failure "line $1 で異常終了（詳細はログ参照）"; exit 1; }
trap 'on_error $LINENO' ERR

# ---- 設定読み込み ----
# backup.conf の例:
#   WORKSPACE_DIR="$HOME/your-workspace"   # バックアップ対象のワークスペース
#   FOLDER_ID="xxxxxxxxxxxxxxxxxxxxx"      # 保存先クラウドフォルダのID
#   NOTIFY_EMAIL="you@example.com"         # 失敗通知の宛先
#   RETENTION=14                           # 保持する世代数
#   PLIST_PREFIXES="com.example com.yourname"  # 収集するlaunchdラベルの接頭辞（スペース区切り）
[ -f "$CONF" ] || fail "設定ファイルがありません: $CONF"
# shellcheck source=/dev/null
source "$CONF"
[ -n "${WORKSPACE_DIR:-}" ] || fail "backup.conf に WORKSPACE_DIR がありません"
[ -n "${FOLDER_ID:-}" ] || fail "backup.conf に FOLDER_ID がありません"
[ -n "${NOTIFY_EMAIL:-}" ] || fail "backup.conf に NOTIFY_EMAIL がありません"
RETENTION="${RETENTION:-14}"
[ "$RETENTION" -ge 1 ] 2>/dev/null || fail "RETENTION が不正です: $RETENTION"
PLIST_PREFIXES="${PLIST_PREFIXES:-}"
WS="$WORKSPACE_DIR"
[ -d "$WS" ] || fail "ワークスペースがありません: $WS"
[ -f "$AGE_PUB" ] || fail "公開鍵がありません: $AGE_PUB"
[ -f "$AGE_KEY" ] || fail "秘密鍵がありません: $AGE_KEY"
command -v gws >/dev/null || fail "gws コマンドが見つかりません（nvm配下を確認）"
command -v age >/dev/null || fail "age コマンドが見つかりません（brew install age）"

# ---- 多重起動防止（mkdirによるアトミックなロック） ----
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "別のバックアップが実行中（pid=$pid）。スキップ"
    exit 0
  fi
  echo "残留ロックを回収（pid=${pid:-不明} は非稼働）"
  rm -rf "$LOCK"
  mkdir "$LOCK" || fail "ロック取得に失敗"
fi
echo $$ > "$LOCK/pid"
LOCK_OWNED=1

STAMP=$(date '+%Y%m%d-%H%M%S')
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wsbackup.XXXXXX")
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cleanup() { rm -rf "$WORK"; [ "${LOCK_OWNED:-0}" = "1" ] && rm -rf "$LOCK"; }
trap 'cleanup' EXIT

# ---- 1. 収集（staging） ----
copy() {  # copy <src> <stage内の相対配置先>  （存在しなければWARNのみ）
  local src="$1" dst="$STAGE/$2"
  [ -e "$src" ] || { echo "[WARN] 対象なし: $src"; return 0; }
  mkdir -p "$(dirname "$dst")"
  rsync -a --exclude 'node_modules' --exclude '.DS_Store' --exclude '__pycache__' \
        --exclude '.venv' "$src" "$dst"
}
copy_req() {  # 必須対象: 存在しなければバックアップ全体を失敗させる
  [ -e "$1" ] || fail "必須のバックアップ対象がありません: $1"
  copy "$1" "$2"
}

# ワークスペース直下のコンテキストファイル
# 「無くなったら気づきたい」対象は copy_req に変える（例: copy_req "$WS/CLAUDE.md" ...）
copy "$WS/CLAUDE.md"                       "workspace/CLAUDE.md"
copy "$WS/AGENTS.md"                       "workspace/AGENTS.md"

# ワークスペース内のローカル専用フォルダ（LOCAL_DIRS で定義。ユーザー設定分は任意扱い）
for d in ${LOCAL_DIRS[@]+"${LOCAL_DIRS[@]}"}; do
  copy "$WS/$d" "workspace/$d"
done

# CLI認証情報（gwsを使う以上は必須）。cache/ のみ除外（この除外はgws専用。copy()には入れない）
[ -d "$HOME/.config/gws" ] || fail "必須のバックアップ対象がありません: ~/.config/gws"
mkdir -p "$STAGE/config/gws"
rsync -a --exclude 'cache/' "$HOME/.config/gws/" "$STAGE/config/gws/"

# AIエージェントの設定・スキル・エージェント定義
copy "$HOME/.claude/settings.json"         "claude/settings.json"
copy "$HOME/.claude/settings.local.json"   "claude/settings.local.json"
copy "$HOME/.claude/CLAUDE.md"             "claude/CLAUDE.md"
copy "$HOME/.claude/keybindings.json"      "claude/keybindings.json"
copy "$HOME/.claude/agents/"               "claude/agents/"
copy "$HOME/.claude/skills/"               "claude/skills/"

# ~/.claude/projects/*/memory（永続メモリのみ。transcript等は含めない）
find "$HOME/.claude/projects" -maxdepth 2 -type d -name memory 2>/dev/null | while read -r m; do
  rel=$(echo "$m" | sed "s|$HOME/.claude/projects/||")
  copy "$m/" "claude/projects/$rel/"
done

# 全リポジトリ配下の .env* を横断収集（深さ制限なし。将来増えても自動で対象になる）
find "$WS" \( -name node_modules -o -name .git -o -name .venv -o -name __pycache__ \) -prune -o \
     -type f -name '.env*' -print 2>/dev/null | while read -r f; do
  rel=$(echo "$f" | sed "s|$WS/||")
  copy "$f" "env-files/$rel"
done
# 収集ロジックが壊れたことを検知したい場合は、絶対に存在するはずの.envを1つ指定する
# 例: [ -f "$STAGE/env-files/repo_example/.env.local" ] || fail ".env自動収集が壊れています"

# launchd設定（PLIST_PREFIXES に合致する自作ジョブのみ）
mkdir -p "$STAGE/launchd"
plist_count=0
for prefix in $PLIST_PREFIXES; do
  for p in "$HOME/Library/LaunchAgents/$prefix"*.plist; do
    [ -e "$p" ] && cp "$p" "$STAGE/launchd/" && plist_count=$((plist_count+1))
  done
done
# 接頭辞を設定しているのに1つも取れないのは設定ミス（未設定なら収集自体をしない）
if [ -n "$PLIST_PREFIXES" ] && [ "$plist_count" -lt 1 ]; then
  fail "launchd plistが1つも収集できませんでした（PLIST_PREFIXES を確認）"
fi

# マニフェスト（何が入っているか＋launchd稼働状況のスナップショット）
JOB_PATTERN=$(echo "$PLIST_PREFIXES" | tr -s ' ' '|' | sed 's/^|//; s/|$//')
{
  echo "backup: $STAMP  host: $(hostname)"
  echo "--- files ---"
  (cd "$STAGE" && find . -type f -exec ls -la {} \; | awk '{print $5, $NF}')
  echo "--- launchctl list ---"
  if [ -n "$JOB_PATTERN" ] && command -v launchctl >/dev/null; then
    launchctl list | grep -Ei "$JOB_PATTERN" || true
  fi
} > "$STAGE/MANIFEST.txt"

# ---- 2. アーカイブ＋暗号化 ----
TAR="$WORK/backup-$STAMP.tar.gz"
ENC="$WORK/backup-$STAMP.tar.gz.age"
tar -czf "$TAR" -C "$STAGE" .
age -R "$AGE_PUB" -o "$ENC" "$TAR"

# ---- 3. ローカル復号検証（復元可能であることの証明） ----
SUM_ORIG=$(shasum -a 256 "$TAR" | awk '{print $1}')
age -d -i "$AGE_KEY" "$ENC" > "$WORK/verify.tar.gz"
SUM_DEC=$(shasum -a 256 "$WORK/verify.tar.gz" | awk '{print $1}')
[ "$SUM_ORIG" = "$SUM_DEC" ] || fail "ローカル復号検証に失敗（checksum不一致）"
rm -f "$WORK/verify.tar.gz"
echo "ローカル復号検証 OK ($SUM_ORIG)"

# ---- 4. アップロード ----
# gws の --upload / -o はカレントディレクトリ配下しか指定できないため WORK に cd して実行
NAME="backup-$STAMP.tar.gz.age"
UP_JSON=$(cd "$WORK" && gws drive files create \
  --json "{\"name\":\"$NAME\",\"parents\":[\"$FOLDER_ID\"]}" \
  --upload "$NAME" --upload-content-type application/octet-stream)
FILE_ID=$(echo "$UP_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
echo "アップロード OK: $NAME ($FILE_ID)"

# ---- 5. リモート再検証（ダウンロードして暗号化ファイルのchecksum比較） ----
SUM_ENC=$(shasum -a 256 "$ENC" | awk '{print $1}')
(cd "$WORK" && gws drive files get --params "{\"fileId\":\"$FILE_ID\",\"alt\":\"media\"}" -o "remote.age")
SUM_REMOTE=$(shasum -a 256 "$WORK/remote.age" | awk '{print $1}')
[ "$SUM_ENC" = "$SUM_REMOTE" ] || fail "リモート検証に失敗（checksum不一致）"
echo "リモート検証 OK"

# ---- 6. 世代管理（backup-*.tar.gz.age のみ対象。新しい順に RETENTION 件残して削除） ----
# バックアップ以外のファイルが同フォルダにあっても巻き込まない。今回分($FILE_ID)は必ず保護
PRUNE_IDS=$(gws drive files list --params "{\"q\":\"'$FOLDER_ID' in parents and trashed = false and name contains 'backup-'\",\"orderBy\":\"name desc\",\"pageSize\":100,\"fields\":\"files(id,name)\"}" \
  | python3 -c "
import sys, json, re
files = [f for f in json.load(sys.stdin)['files']
         if re.fullmatch(r'backup-\d{8}-\d{6}\.tar\.gz\.age', f['name'])]
for f in files[$RETENTION:]:
    if f['id'] != '$FILE_ID':
        print(f['id'] + '\t' + f['name'])
")
PRUNE_FAILED=0
while IFS=$'\t' read -r fid fname; do
  [ -n "$fid" ] || continue
  if gws drive files delete --params "{\"fileId\":\"$fid\"}" >/dev/null; then
    echo "旧世代削除: $fname"
  else
    echo "[ERROR] 旧世代削除に失敗: $fname"
    PRUNE_FAILED=1
  fi
done <<< "$PRUNE_IDS"
[ "$PRUNE_FAILED" = "0" ] || fail "世代管理（旧世代削除）に失敗"

# ---- 7. 成功マーカー ----
date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/last-success"
echo "===== backup done: $(date '+%Y-%m-%d %H:%M:%S') ====="
