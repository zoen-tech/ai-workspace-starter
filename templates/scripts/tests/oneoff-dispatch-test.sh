#!/bin/bash
# oneoff-dispatch.sh / oneoff-enqueue.sh のテスト。一時フォルダで動かし、本番の ~/jobs/oneoff には触らない。
# 実行: bash repo_workspace-setup/scripts/tests/oneoff-dispatch-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
D="$HERE/oneoff-dispatch.sh"; E="$HERE/oneoff-enqueue.sh"
T=$(mktemp -d /tmp/oneoff-test.XXXXXX)
export ONEOFF_ROOT="$T" ONEOFF_NO_NOTIFY=1 ONEOFF_JOB_TIMEOUT_SEC=8
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
ng()  { fail=$((fail+1)); echo "  NG   $1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
past="$(date -v-1H '+%Y-%m-%d %H:%M')"; future="$(date -v+1d '+%Y-%m-%d %H:%M')"
past_due="$(date -v-1H '+%Y-%m-%dT%H%M')"

echo "# 1. enqueue の検証"
"$E" "$future" ok-future -d "将来" -- /bin/echo hi >/dev/null && ok "将来ジョブを登録" || ng "将来ジョブを登録"
check "ファイル名に期日とslugが入る" "ls '$T/queue' | grep -q '^$(date -v+1d +%Y-%m-%dT%H%M)__ok-future.sh$'"
"$E" "2026-02-30 10:00" bad -- /usr/bin/true 2>/dev/null && ng "存在しない日付を弾く" || ok "存在しない日付を弾く"
"$E" "$future" 'bad slug' -- /usr/bin/true 2>/dev/null && ng "不正なslugを弾く" || ok "不正なslugを弾く"
"$E" "$future" ok-future -- /usr/bin/true 2>/dev/null && ng "同名の二重登録を弾く" || ok "同名の二重登録を弾く"
"$E" "$past" quoted -- /bin/sh -c 'echo "a b" > "$ONEOFF_ROOT/quoted.out"' >/dev/null 2>&1
check "空白入り引数がそのまま渡る（ファイル生成）" "grep -q 'echo' '$T/queue/${past_due}__quoted.sh'"

echo "# 2. dispatch の検証"
"$E" "$past" exit0 -- /usr/bin/true >/dev/null 2>&1
"$E" "$past" exit75 -- /bin/sh -c 'exit 75' >/dev/null 2>&1
"$E" "$past" exit1 -- /bin/sh -c 'exit 1' >/dev/null 2>&1
"$E" "$past" hang -- /bin/sleep 60 >/dev/null 2>&1
echo 'exit 0' > "$T/queue/notadate__x.sh"
"$D"
check "将来ジョブは実行されずqueueに残る" "ls '$T/queue' | grep -q '__ok-future.sh$'"
check "exit 0 は done/ へ" "ls '$T/done' | grep -q '__exit0.sh.done-'"
check "exit 75 は翌日以降の期日でqueueに戻る" "ls '$T/queue' | grep -q '__exit75.sh$' && [ \"\$(ls '$T/queue' | grep __exit75 | cut -c1-15)\" \\> \"$past_due\" ]"
check "exit 1 は failed/ へ" "ls '$T/failed' | grep -q '__exit1.sh.exit1-'"
check "上限超過は強制終了して failed/（exit124）" "ls '$T/failed' | grep -q '__hang.sh.exit124-'"
check "期日が読めない名前は failed/ へ" "[ ! -e '$T/queue/notadate__x.sh' ] && ls '$T/failed' | grep -q '^badname-'"
check "空白入り引数の実行結果が正しい" "[ \"\$(cat '$T/quoted.out' 2>/dev/null)\" = 'a b' ]"
check "ジョブごとのログができる" "grep -q 'exit=1' '$T/logs/exit1.log'"
check "running/ は空に戻る" "[ -z \"\$(ls '$T/running')\" ]"
check "ロックが解放される" "[ ! -d '$T/.dispatch.lock' ]"

echo "# 3. ロックと中断回復"
mkdir -p "$T/.dispatch.lock"; echo 99999999 > "$T/.dispatch.lock/pid"
"$E" "$past" after-stale-lock -- /usr/bin/true >/dev/null 2>&1
"$D"
check "持ち主が死んだロックは回収して実行する" "ls '$T/done' | grep -q '__after-stale-lock.sh.done-'"
mkdir -p "$T/.dispatch.lock"; echo $$ > "$T/.dispatch.lock/pid"
"$E" "$past" during-live-lock -- /usr/bin/true >/dev/null 2>&1
"$D"
check "生きているロック中は何もしない" "ls '$T/queue' | grep -q '__during-live-lock.sh$'"
rm -rf "$T/.dispatch.lock"
cp "$T/queue/${past_due}__during-live-lock.sh" "$T/running/${past_due}__interrupted.sh"
"$D"
check "running/ に残った中断ジョブは failed/ へ" "ls '$T/failed' | grep -q '__interrupted.sh.interrupted-'"
check "status が動く" "'$D' status | grep -q 'queue'"

echo "# 4. 競合・残存プロセス・衝突の検証"
"$E" "$past" grandchild -- /bin/sh -c '/bin/sleep 300 & /bin/sleep 300' >/dev/null 2>&1
"$D"
check "上限超過で孫プロセス（sleep 300）も残らない" "! pgrep -f '/bin/sleep 300' >/dev/null"
tmr="$(date -j -v+1d -f '%Y-%m-%dT%H%M' "$past_due" '+%Y-%m-%dT%H%M')"   # 持ち越し先＝期日の翌日同時刻
"$E" "$past" carry -- /bin/sh -c 'exit 75' >/dev/null 2>&1
"$E" "$(date -j -f '%Y-%m-%dT%H%M' "$tmr" '+%Y-%m-%d %H:%M')" carry -- /usr/bin/true >/dev/null 2>&1
before=$(cat "$T/queue/${tmr}__carry.sh")
"$D"
check "exit 75 の持ち越し先に同名があれば上書きせず failed/ へ" "ls '$T/failed' | grep -q '__carry.sh.carryover-blocked-' && [ \"\$(cat '$T/queue/${tmr}__carry.sh')\" = \"\$before\" ]"
( "$E" "$future" race -- /bin/echo A >/dev/null 2>&1 & "$E" "$future" race -- /bin/echo B >/dev/null 2>&1 & wait )
check "同時登録は1件だけ成功し、本文は片方のコマンドで完結する" "[ \$(grep -c '^exec' '$T/queue/'*__race.sh) -eq 1 ]"
"$E" "$future" nl -d $'一行目\nexit 1' -- /usr/bin/true >/dev/null 2>&1
check "説明の改行がコマンドとして混入しない" "! grep -q '^exit 1' '$T/queue/'*__nl.sh"
echo 'exit 0' > "$T/queue/2026-01-01T0000__a b.sh"
"$D"
check "空白入りのファイル名は failed/ へ隔離される" "[ ! -e '$T/queue/2026-01-01T0000__a b.sh' ] && ls '$T/failed' | grep -q '^badname-'"
"$E" "$past" sigterm -- /bin/sleep 300 >/dev/null 2>&1
"$D" & dpid=$!; sleep 4; kill -TERM $dpid; wait $dpid 2>/dev/null
check "ディスパッチャ停止時は実行中ジョブを止めて failed/ へ" "ls '$T/failed' | grep -q '__sigterm.sh.interrupted-' && ! pgrep -f '/bin/sleep 300' >/dev/null"
check "ディスパッチャ停止後にロックが残らない" "[ ! -d '$T/.dispatch.lock' ]"
/usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' -- /bin/sleep 20 & opg=$!
cp "$T/queue/${past_due}__during-live-lock.sh" "$T/running/${past_due}__orphan.sh" 2>/dev/null || echo 'exit 0' > "$T/running/${past_due}__orphan.sh"
echo "$opg" > "$T/running/${past_due}__orphan.sh.pg"
"$D"
check "監視役なしで生きているジョブは触らず見送る" "[ -e '$T/running/${past_due}__orphan.sh' ]"
kill -KILL -- -$opg 2>/dev/null; wait $opg 2>/dev/null

echo; echo "結果: 合格 $pass / 不合格 ${fail}（作業フォルダ: ${T}）"
[ "$fail" -eq 0 ] && rm -rf "$T"
[ "$fail" -eq 0 ]
