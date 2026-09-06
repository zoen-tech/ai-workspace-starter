# 09. 一発ジョブ（期日リマインド・予約実行）を launchd に増やさず回す

母艦（常時ONのMac）で「○月○日○時に1回だけ動かす」ジョブを登録する手順。launchd の plist は**作らない**。

## なぜ plist を作らないか
macOS はユーザーの launchd ジョブを新規登録するたびに「バックグラウンド項目が追加されました」を通知し、システム設定の「ログイン項目と機能拡張」にも1行増える。一発ジョブごとに plist を作っていた頃は、リマインドを作るたびに通知が出て、一覧が「zsh」「bash」だらけになっていた。

そこで受け皿ジョブ `com.<org>.workspace-oneoff-dispatch`（5分ごと）だけを launchd に登録し、一発ジョブは待ち行列フォルダにファイルを置くだけにした。新しい一発ジョブを足しても launchd 登録は増えず、通知も出ない。

## 構成
```
~/jobs/oneoff/
├── queue/     YYYY-MM-DDTHHMM__<slug>.sh  ← 期日をファイル名に持つ実行スクリプト（ここに置く）
├── running/   実行中（通常は空）
├── done/      完了したもの（実行時刻付きで保管。90日で自動削除）
├── failed/    失敗したもの（Chat通知済み。戻せば再実行できる。自動削除しないので、確認したら消す）
├── logs/      dispatch.log（受け皿のログ）＋ <slug>.log（ジョブごとの出力）
└── archive-plists/  旧方式の plist の退避先
```
- 受け皿本体: `templates/scripts/oneoff-dispatch.sh`（launchd 登録は `scripts/com.<org>.workspace-oneoff-dispatch.plist`）
- 登録ヘルパー: `templates/scripts/oneoff-enqueue.sh`
- テスト: `bash templates/scripts/tests/oneoff-dispatch-test.sh`（一時フォルダで動く。本番の queue/ には触らない）
- `~/jobs/` 配下は日次バックアップ（`local-backup.sh`）の対象なので、待ち行列も自動で退避される

## 登録する
```bash
scripts/oneoff-enqueue.sh "2026-10-15 10:00" <slug> \
  -d "何のためのジョブか1行" -- \
  /bin/bash ~/.claude/scheduled-tasks/run-summary.sh <slug>
```
- 日時は JST の `YYYY-MM-DD HH:MM`。slug は英数字と `._-` のみ（ログ名・通知に使う）
- `--` の後ろがそのまま実行される。Claude に手順を実行させるなら `run-summary.sh <skill名>`（`~/.claude/scheduled-tasks/<skill名>/SKILL.md` に手順を書く）。シェルスクリプトなら `/bin/bash <パス>`
- 登録後 `oneoff-dispatch.sh status` で待ち行列に載ったことを確認する。台帳 共通リポジトリの `docs/jobs-registry.md` の変更履歴にも1行残す（一発ものは個別行を立てない）

## ジョブ側の約束（終了コード）
| exit | 扱い |
|---|---|
| 0 | 完了。`done/` へ |
| 75 | 翌日の同時刻に持ち越し（送信に失敗したので明日また試す、など）。`queue/` に戻る |
| その他 | 失敗。`failed/` へ移し、`ONEOFF_NOTIFY_CMD` で通知（未設定ならログのみ） |

- 期日を過ぎていても次の起動で拾う（受け皿が空いていれば5分以内。先行ジョブが動いていればその終了後）。母艦 のスリープ・再起動で時刻を跨いでも取りこぼさない
- 1ジョブ60分で強制終了（exit 124 扱い。ジョブは独立したプロセスグループで動くので、`claude -p` や node の孫プロセスも一緒に止まる）。同時には1本しか走らない（順番待ち）
- launchd の環境は最小限なので、`gws`・`claude`（nvm 配下）・`gcloud`・homebrew には受け皿が PATH を通す。それ以外はジョブ側で用意する
- `.zshrc` は読まれない。`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` も載らないので、母艦の gws はそのまま動く

## 「毎日○時、△日まで」のような繰り返し
ジョブの末尾で自分の翌日分を登録する。終了条件を満たしたら登録しないだけで止まる。
```bash
# ジョブ本体の末尾
if [ "$(date +%F)" \< "2026-09-12" ] && [ ! -f "$HOME/.local/state/<name>/done" ]; then
  scripts/oneoff-enqueue.sh "$(date -v+1d '+%Y-%m-%d') 09:00" <slug> -- /bin/bash "$0"
fi
```
Claude 実行（SKILL.md）の場合も同じで、SKILL.md の手順の最後に「翌日分の登録コマンド」を書き、決着したら登録しない。

## 状態を見る・直す
```bash
scripts/oneoff-dispatch.sh status   # 待ち行列と件数
tail -50 ~/jobs/oneoff/logs/dispatch.log                                        # 受け皿のログ
tail -50 ~/jobs/oneoff/logs/<slug>.log                                          # ジョブの出力
```
- 取り消す: `queue/` のファイルを消す
- 失敗を再実行する: `failed/` のファイルを `queue/YYYY-MM-DDTHHMM__<slug>.sh` の名前に戻す（期日を過去にすれば即実行）
- 受け皿が動いていない: `launchctl print gui/$(id -u)/com.<org>.workspace-oneoff-dispatch`。無ければ登録し直す（launchd はログの親フォルダを作らないので先に作る）:
  ```bash
  mkdir -p ~/.local/state/oneoff-dispatch
  cp scripts/com.<org>.workspace-oneoff-dispatch.plist ~/Library/LaunchAgents/
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.workspace-oneoff-dispatch.plist
  ```


## 導入
```bash
cp templates/scripts/oneoff-dispatch.sh templates/scripts/oneoff-enqueue.sh <仕組みリポ>/scripts/
sed -e "s|{{HOME}}|$HOME|g" -e "s|{{WORKSPACE}}|$HOME/<ワークスペース>|g" -e "s|{{ORG}}|<org>|g" \
  templates/scripts/com.ORG.workspace-oneoff-dispatch.plist > ~/Library/LaunchAgents/com.<org>.workspace-oneoff-dispatch.plist
mkdir -p ~/.local/state/oneoff-dispatch
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<org>.workspace-oneoff-dispatch.plist
bash templates/scripts/tests/oneoff-dispatch-test.sh   # 一時フォルダで28項目を検証
```
失敗通知を出したい場合は plist の `EnvironmentVariables` に `ONEOFF_NOTIFY_CMD`（メッセージを第1引数に取るコマンド。例: `python3 /path/notify_chat.py`）を設定する。
