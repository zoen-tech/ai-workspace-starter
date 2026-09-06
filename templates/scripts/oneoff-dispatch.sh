#!/bin/bash
# 担当: {{OWNER}}
# 変更ポリシー: 自由
# 全ジョブ台帳: <共通リポジトリ>/docs/jobs-registry.md
#
# oneoff-dispatch.sh — 一発ジョブ（期日リマインド等）の受け皿
#
# なぜ要るか:
#   macOSはlaunchdジョブを新しく登録するたびに「バックグラウンド項目が追加されました」を通知し、
#   システム設定の「ログイン項目」にも1行増える。リマインド1件ごとに plist を作っていたため、
#   作るたびに通知が出て、一覧も「zsh」「bash」だらけになる。
#   この1本だけを launchd に登録し、以後の一発ジョブは queue/ にファイルを置くだけにする。
#   → 新しい一発ジョブを足しても launchd 登録は増えず、通知も出ない。
#
# 仕組み:
#   ~/jobs/oneoff/queue/YYYY-MM-DDTHHMM__<slug>.sh   期日をファイル名に持つ実行スクリプト
#   5分ごとに起動し、期日 <= 現在 のものを古い順に1つずつ実行する（同時には1本だけ）。
#     exit 0  → done/   へ移す（ファイル名に実行時刻を付けて保管。90日で自動削除）
#     exit 75 → 翌日の同時刻に持ち越す（EX_TEMPFAIL。「送信に失敗したので明日また試す」用）
#     その他  → failed/ へ移し、ONEOFF_NOTIFY_CMD（設定していれば）で通知
#   期日を過ぎていても次の起動で拾う（母艦のスリープ・再起動で時刻を跨いでも取りこぼさない）。
#   ジョブは独立したプロセスグループで動かし、60分の上限を超えたら孫プロセスごと強制終了する。
#   多重起動は mkdir ロックで防ぐ（持ち主が死んでいれば、リネームに成功した1プロセスだけが回収する）。
#
# 通知: 環境変数 ONEOFF_NOTIFY_CMD に「メッセージを第1引数に取るコマンド」を設定すると失敗時に呼ぶ（未設定ならログのみ）
# 登録の仕方: oneoff-enqueue.sh を使う（手順書: tutorial/09-oneoff-jobs.md）
# 状態の確認: oneoff-dispatch.sh status
# テスト:     scripts/tests/oneoff-dispatch-test.sh（本番の queue/ には触らない）
#
# install:   mkdir -p ~/.local/state/oneoff-dispatch   # launchd はログの親フォルダを作らない
#            cp scripts/com.{{ORG}}.workspace-oneoff-dispatch.plist ~/Library/LaunchAgents/
#            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.{{ORG}}.workspace-oneoff-dispatch.plist
# uninstall: launchctl bootout gui/$(id -u)/com.{{ORG}}.workspace-oneoff-dispatch
set -u

export HOME="${HOME:?}"
export LANG="${LANG:-ja_JP.UTF-8}"
# launchd の環境は最小限なので、ジョブが使う道具（gws/claude=nvm配下、gcloud、homebrew）に自前で通す
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -n 1)"
export PATH="${NODE_BIN:+$NODE_BIN:}/opt/homebrew/share/google-cloud-sdk/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="${ONEOFF_ROOT:-$HOME/jobs/oneoff}"
QUEUE="$ROOT/queue"; RUNNING="$ROOT/running"; DONE="$ROOT/done"; FAILED="$ROOT/failed"; LOGS="$ROOT/logs"
LOCK="$ROOT/.dispatch.lock"
DLOG="$LOGS/dispatch.log"
JOB_TIMEOUT_SEC="${ONEOFF_JOB_TIMEOUT_SEC:-3600}"
LOCK_NOPID_STALE_SEC=120      # pid 未記入のロックをこの秒数を超えて放置していたら死んだとみなす
DONE_KEEP_DAYS=90
LOG_MAX_BYTES=2097152
LAUNCHD_LOG="$HOME/.local/state/oneoff-dispatch/launchd.log"

mkdir -p "$QUEUE" "$RUNNING" "$DONE" "$FAILED" "$LOGS"

log() { echo "[$(date '+%F %T')] $*" >> "$DLOG"; }
ts()  { date +%Y%m%d-%H%M%S; }

notify() {
  # 失敗通知。ONEOFF_NOTIFY_CMD（例: "python3 ~/jobs/notify_chat.py"）を呼ぶ。テスト時は ONEOFF_NO_NOTIFY=1 で止める
  [ "${ONEOFF_NO_NOTIFY:-0}" = "1" ] && { log "notify(抑止): $1"; return 0; }
  [ -n "${ONEOFF_NOTIFY_CMD:-}" ] || { log "notify(未設定): $1"; return 0; }
  $ONEOFF_NOTIFY_CMD "$1" >> "$DLOG" 2>&1 || log "notify: 通知コマンドが失敗（$1）"
}

# ログ肥大の抑止（上限超で末尾1000行に切る）
rotate() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ] || return 0
  tail -n 1000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

due_epoch() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}$ ]] && date -j -f "%Y-%m-%dT%H%M" "$1" +%s 2>/dev/null; }
next_day()  { date -j -v+1d -f "%Y-%m-%dT%H%M" "$1" +"%Y-%m-%dT%H%M" 2>/dev/null; }
pg_alive()  { [ -n "${1:-}" ] && kill -0 -- "-$1" 2>/dev/null; }
pg_kill()   { kill -TERM -- "-$1" 2>/dev/null; sleep 5; kill -KILL -- "-$1" 2>/dev/null; }

status() {
  local now; now=$(date +%s)
  echo "queue（期日順）:"
  local any=0 f base due slug ep mark
  for f in "$QUEUE"/*.sh; do
    [ -e "$f" ] || continue; any=1
    base=$(basename "$f" .sh); due="${base%%__*}"; slug="${base#*__}"
    ep=$(due_epoch "$due")
    mark="待機"; [ -n "$ep" ] && [ "$ep" -le "$now" ] && mark="期日到来（次回起動で実行）"
    [ -z "$ep" ] && mark="⚠ ファイル名の期日が読めない"
    printf '  %s  %-40s %s\n' "$due" "$slug" "$mark"
  done
  [ "$any" = 0 ] && echo "  （なし）"
  echo "running: $(ls "$RUNNING"/*.sh 2>/dev/null | wc -l | tr -d ' ')件 / done: $(ls "$DONE" 2>/dev/null | wc -l | tr -d ' ')件 / failed: $(ls "$FAILED" 2>/dev/null | wc -l | tr -d ' ')件"
  [ -d "$LOCK" ] && echo "lock: あり（pid=$(cat "$LOCK/pid" 2>/dev/null)）"
  echo "ログ: $DLOG"
}

if [ "${1:-}" = "status" ]; then status; exit 0; fi
if [ -n "${1:-}" ]; then echo "usage: $0 [status]" >&2; exit 2; fi

# ---- ロック（多重起動防止）
# 持ち主が死んでいるロックは、一意な名前へのリネーム（原子的）に成功した1プロセスだけが片付ける。
# 「pid が未記入」は mkdir 直後の一瞬でもあり得るので、一定時間より古いものだけ死んだとみなす。
acquire_lock() {
  mkdir "$LOCK" 2>/dev/null && { echo $$ > "$LOCK/pid"; return 0; }
  local oldpid stale=0
  oldpid=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$oldpid" ]; then
    kill -0 "$oldpid" 2>/dev/null || stale=1
  else
    local age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
    [ "$age" -gt "$LOCK_NOPID_STALE_SEC" ] && stale=1
  fi
  [ "$stale" = 1 ] || return 1
  local grave="$LOCK.stale.$$.$(ts)"
  mv "$LOCK" "$grave" 2>/dev/null || return 1     # 他プロセスが先に回収した
  rm -rf "$grave"
  log "古いロックを回収（pid=${oldpid:-未記入}）"
  mkdir "$LOCK" 2>/dev/null && { echo $$ > "$LOCK/pid"; return 0; }
  return 1
}
acquire_lock || exit 0

# ---- 終了時の後始末（自分が止められたら、動かしている子のプロセスグループごと止めて記録する）
CUR_NAME=""; CUR_PG=""
cleanup() {
  if [ -n "$CUR_PG" ] && pg_alive "$CUR_PG"; then
    pg_kill "$CUR_PG"
    [ -e "$RUNNING/$CUR_NAME" ] && mv "$RUNNING/$CUR_NAME" "$FAILED/$CUR_NAME.interrupted-$(ts)"
    rm -f "$RUNNING/$CUR_NAME.pg"
    log "ディスパッチャが停止されたため実行中のジョブを止めた: $CUR_NAME → failed/"
  fi
  rm -rf "$LOCK"
}
trap 'cleanup; exit 143' TERM INT HUP
trap 'cleanup' EXIT

rotate "$DLOG"; rotate "$LAUNCHD_LOG"
find "$DONE" -type f -mtime +"$DONE_KEEP_DAYS" -delete 2>/dev/null

# ---- 前回の異常終了で running/ に残ったもの。プロセスグループがまだ生きていれば触らず、死んでいれば failed 扱い
for f in "$RUNNING"/*.sh; do
  [ -e "$f" ] || continue
  n=$(basename "$f"); pg=$(cat "$f.pg" 2>/dev/null)
  if pg_alive "$pg"; then
    log "running/ の ${n} はまだ動いている（pgid=${pg}）。前回のディスパッチャが先に死んだ可能性。今回は見送る"
    notify "⚠️ 一発ジョブ ${n%.sh} が監視役なしで動き続けています（母艦・pgid=${pg}）。確認: ps -g $pg" "oneoff_orphan_${n}"
    exit 0
  fi
  mv "$f" "$FAILED/$n.interrupted-$(ts)"; rm -f "$f.pg"
  log "running/ に残っていたジョブを failed へ: ${n}（前回のディスパッチャが途中で落ちた可能性）"
  notify "⚠️ 一発ジョブ ${n%.sh} が前回の実行で中断していました（Mac mini）。failed/ に移動。確認: ~/jobs/oneoff/failed/" "oneoff_interrupted"
done

# ---- 期日が来たものを古い順に実行（glob は名前順＝期日順。ls の出力は使わない）
now=$(date +%s)
for f in "$QUEUE"/*.sh; do
  [ -e "$f" ] || continue
  name=$(basename "$f"); base="${name%.sh}"; due="${base%%__*}"; slug="${base#*__}"
  ep=$(due_epoch "$due")
  if [ "$due" = "$base" ] || [ -z "$ep" ] || [ -z "$slug" ] || ! [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    mv "$f" "$FAILED/badname-$(ts)-$$" 2>/dev/null
    log "ファイル名が規則外のため failed へ: ${name}（正: YYYY-MM-DDTHHMM__slug.sh、slugは英数字と._-）"
    notify "⚠️ 一発ジョブのファイル名が不正で実行できません: ${name}（正: YYYY-MM-DDTHHMM__slug.sh）。failed/ に移動しました" "oneoff_badname"
    continue
  fi
  [ "$ep" -le "$now" ] || continue

  mv "$f" "$RUNNING/$name" || continue
  CUR_NAME="$name"
  jlog="$LOGS/$slug.log"; rotate "$jlog"
  log "開始: $name"
  echo "================ Start: $(date '+%F %T %Z') ($name) ================" >> "$jlog"
  # 独立したプロセスグループで起動する（macOS に setsid は無いので perl の setpgrp を使う）。
  # 上限超過時は kill をグループへ送り、claude -p や node の孫プロセスも一緒に止める。
  exec 3>&2 2>/dev/null   # 強制終了時に bash が出す "Terminated" 通知を launchd ログに残さない
  /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV or exit 127' -- /bin/bash "$RUNNING/$name" >> "$jlog" 2>&1 &
  jpid=$!; CUR_PG="$jpid"; echo "$jpid" > "$RUNNING/$name.pg"
  waited=0; timed_out=0
  while kill -0 "$jpid" 2>/dev/null; do
    sleep 2; waited=$((waited+2))
    if [ "$waited" -ge "$JOB_TIMEOUT_SEC" ]; then timed_out=1; pg_kill "$jpid"; break; fi
  done
  wait "$jpid" 2>/dev/null; rc=$?
  exec 2>&3 3>&-
  [ "$timed_out" = 1 ] && rc=124
  # 正常終了後もグループに孫が残っていれば片付ける（ジョブが背景で何かを起動しっぱなしにした場合）
  pg_alive "$jpid" && { pg_kill "$jpid"; log "注意: ${name} の終了後に残っていた子プロセスを停止した"; }
  echo "================ End: $(date '+%F %T %Z') exit=$rc ================" >> "$jlog"
  rm -f "$RUNNING/$name.pg"; CUR_PG=""

  if [ "$rc" -eq 0 ]; then
    mv "$RUNNING/$name" "$DONE/$name.done-$(ts)"
    log "完了: $name"
  elif [ "$rc" -eq 75 ]; then
    nd="$due"; i=0; ok=1
    while :; do
      nd=$(next_day "$nd"); i=$((i+1))
      [ -n "$nd" ] && [ -n "$(due_epoch "$nd")" ] || { ok=0; break; }
      [ "$(due_epoch "$nd")" -gt "$now" ] && break
      [ "$i" -ge 400 ] && { ok=0; break; }
    done
    if [ "$ok" = 1 ] && [ ! -e "$QUEUE/${nd}__${slug}.sh" ]; then
      mv "$RUNNING/$name" "$QUEUE/${nd}__${slug}.sh"
      log "持ち越し(exit 75): $name → ${nd}__${slug}.sh"
    else
      mv "$RUNNING/$name" "$FAILED/$name.carryover-blocked-$(ts)"
      reason="翌日の同名ジョブが既に登録済み"; [ "$ok" = 1 ] || reason="翌日の日付が計算できない"
      log "持ち越し(exit 75)できず failed へ: ${name}（${reason}）"
      notify "🚨 一発ジョブ ${slug} を翌日に持ち越せませんでした（母艦・${reason}）。failed/ に移動。確認: ~/jobs/oneoff/failed/" "oneoff_${slug}"
    fi
  else
    mv "$RUNNING/$name" "$FAILED/$name.exit$rc-$(ts)"
    reason="exit=$rc"; [ "$rc" -eq 124 ] && reason="${JOB_TIMEOUT_SEC}秒の上限で強制終了"
    log "失敗: ${name}（${reason}）"
    notify "🚨 一発ジョブ ${slug} が失敗しました（母艦・${reason}）
確認: tail -50 ~/jobs/oneoff/logs/${slug}.log
再実行: ファイルを ~/jobs/oneoff/failed/ から queue/ へ戻す（名前は YYYY-MM-DDTHHMM__${slug}.sh に）" "oneoff_${slug}"
  fi
  CUR_NAME=""
done
exit 0
