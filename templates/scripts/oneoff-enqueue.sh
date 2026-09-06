#!/bin/bash
# 担当: {{OWNER}}
# 変更ポリシー: 自由
# 全ジョブ台帳: <共通リポジトリ>/docs/jobs-registry.md
#
# oneoff-enqueue.sh — 一発ジョブを受け皿（oneoff-dispatch.sh）の待ち行列に登録する
#
# 使い方:
#   oneoff-enqueue.sh "<YYYY-MM-DD HH:MM>" <slug> [-d "説明"] -- <実行するコマンド...>
#   例: oneoff-enqueue.sh "2026-10-15 10:00" <slug> \
#         -d "何のためのジョブか1行" -- \
#         /bin/bash ~/.claude/scheduled-tasks/run-summary.sh cloudfunctions-nodejs-upgrade-2026-10
#
#   ジョブ側の約束: exit 0=完了 / exit 75=翌日同時刻に持ち越し（送信失敗など） / それ以外=失敗（Chat通知）
#   「毎日○時、△日まで」のような繰り返しは、ジョブの末尾で自分の次回分をこのスクリプトで登録する
#   （手順書: tutorial/09-oneoff-jobs.md）
#
# launchd の plist は作らない（作ると macOS が「バックグラウンド項目が追加されました」を毎回通知する）。
set -u
ROOT="${ONEOFF_ROOT:-$HOME/jobs/oneoff}"
QUEUE="$ROOT/queue"

usage() { sed -n '7,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 4 ] || usage
when="$1"; slug="$2"; shift 2
desc=""
if [ "${1:-}" = "-d" ]; then desc="$2"; shift 2; fi
# 説明・登録元に改行が混じると2行目以降がコマンドとして実行されてしまうので除去する
desc=$(printf "%s" "$desc" | tr -d "\r\n")
origin=$(printf "%s" "${ONEOFF_ORIGIN:-$(whoami)@$(hostname -s)}" | tr -d "\r\n")
[ "${1:-}" = "--" ] || usage
shift
[ $# -ge 1 ] || usage

[[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "slug は英数字・._- のみ: $slug" >&2; exit 2; }
due=$(date -j -f "%Y-%m-%d %H:%M" "$when" +"%Y-%m-%dT%H%M" 2>/dev/null) || { echo "日時の形式が違います（YYYY-MM-DD HH:MM）: $when" >&2; exit 2; }
# date -j は「2026-02-30」のような存在しない日付も繰り上げて通すため、往復で一致を確認する
[ "$(date -j -f "%Y-%m-%dT%H%M" "$due" +"%Y-%m-%d %H:%M")" = "$when" ] || { echo "存在しない日時です: $when" >&2; exit 2; }

mkdir -p "$QUEUE"
target="$QUEUE/${due}__${slug}.sh"
# コマンドは1語ずつクォートして書き出す（空白・記号入りの引数を壊さない）
cmd=""; for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done

# 同時登録の競合を防ぐため、noclobber（set -C）で「無ければ作って書く」を一度に行う。既にあれば失敗する
( set -C; {
  echo '#!/bin/bash'
  echo "# 一発ジョブ: $slug"
  echo "# 期日: $when / 登録: $(date '+%F %T') / 登録元: ${origin}"
  [ -n "$desc" ] && echo "# 説明: $desc"
  echo "# 担当: {{OWNER}}／台帳: <共通リポジトリ>/docs/jobs-registry.md"
  echo "# 実行の約束: exit 0=完了 / 75=翌日に持ち越し / その他=失敗（Chat通知）"
  echo 'set -u'
  echo "exec$cmd"
} > "$target" ) 2>/dev/null || { echo "同名のジョブが既にあります: $target" >&2; exit 1; }
chmod +x "$target"

if [ "$(date -j -f "%Y-%m-%dT%H%M" "$due" +%s)" -le "$(date +%s)" ]; then
  echo "注意: 期日が過去です。次回のディスパッチ（5分以内）で即実行されます" >&2
fi
echo "登録しました: $target"
echo "次回のディスパッチ以降、期日が来たら実行されます（確認: oneoff-dispatch.sh status）"
