# 08. ローカル専用ファイルのバックアップ — Gitに入れられないものを守る

> **要旨：** リポジトリの中身はGitで守られるが、`.env` や認証情報、AIエージェントの設定など「Gitに入れてはいけないファイル」はそのPCにしか存在しない。これらを毎日1回、暗号化してクラウドへ自動バックアップする。鍵はアーカイブに含めず、毎回「本当に復元できるか」を検証させるのが要点。

> **Note:** この章は応用編です。実装例としてage（暗号化）＋Google Drive＋launchdの組み合わせを使いますが、考え方はツールに依存しません。

---

## なぜ必要か

このワークスペースは「業務データはすべてリポジトリに入れる」という設計です。リポジトリはGitHubにpushされるので、PCが壊れてもcloneし直せば戻ります。**守られていないのは、Gitに入れないと決めたファイルだけ**です。

- `.env` などの秘匿ファイル（APIキー・トークン）— `.gitignore` 対象
- CLIツールの認証情報（`~/.config/` 配下など）
- ローカル専用フォルダ（ローカルで動かしているスクリプト・小さなサーバー等）
- 自動実行ジョブの設定ファイル（launchd の plist など）
- AIエージェントの設定・スキル・永続メモリ（`~/.claude/` 配下）
- ワークスペース直下のコンテキストファイル（個人設定を含み共有していない場合）

数は多くありませんが、**失うと復旧に数日かかる種類のファイル**です。しかもGit管理外なので、「消えたこと」に気づくのは必要になった瞬間です。自動化ジョブを常時動かすマシン（母艦）を持っている場合はなおさら、ここが単一障害点になります。

やることは単純です。**対象を1箇所に集めて、暗号化して、クラウドに置く**。これを毎日自動で回します。

## 設計原則4つ

バックアップの仕組みは「作った日は動くが、いつの間にか壊れている」ことが最大の失敗パターンです。それを防ぐために4つの原則を置きます。

### 1. 鍵ペア方式で、秘密鍵はアーカイブに含めない

暗号化には公開鍵暗号（age）を使い、**暗号化は公開鍵・復号は秘密鍵**に分けます。バックアップを作る側のマシンには公開鍵だけあればよく、秘密鍵は復元時にしか使いません。

そして**秘密鍵はバックアップの中に入れません**。入れてしまうと、クラウド側のアカウントが乗っ取られたときに「暗号化ファイル」と「その鍵」が同じ場所で手に入り、暗号化した意味が消えます。

秘密鍵のコピーはパスワードマネージャーなど、**バックアップ先とは別の場所**に保管してください。この鍵を失うとバックアップは永久に復元できません。ここが仕組み全体で最も重要な一点です。

### 2. 世代管理する（上書きしない）

同じファイルを上書きし続けると、「壊れたデータで上書きされたことに気づかず、正常な世代も残っていない」という事故が起きます。ファイル名に日時を入れて毎回新規に置き、保持数（例：14世代）を超えた古いものだけを自動削除します。

### 3. 毎回、復号して検証する

「バックアップは取れていたが、開いたら壊れていた」を防ぐため、スクリプトの中で毎回2段階の検証をします。

- **ローカル復号検証** — 暗号化した直後に自分で復号し、元のアーカイブとチェックサムが一致するか確認する（＝復元可能であることの証明）
- **リモート再検証** — アップロード後にダウンロードし直し、チェックサムが一致するか確認する（＝転送が壊れていないことの証明）

どちらかが合わなければ、その回は失敗として扱います。

### 4. 失敗通知と成功マーカーを両方置く

失敗したらメールで通知します。ただし通知だけでは不十分です。**ジョブがそもそも起動しなくなった場合、失敗通知も飛びません**（何も実行されないので当然です）。

そこで、全検証を通過したときだけタイムスタンプを書き込む「成功マーカー」ファイルを置きます。確認するのはこの1ファイルだけです。

```bash
cat ~/.local/state/workspace-backup/last-success
```

日付が2日以上前なら異常、という単純な判定になります。これが最終防衛線です。

## セットアップ手順

### 1. ツールを入れて鍵を作る

**ターミナルで実行：**

```bash
brew install age                       # 暗号化ツール（Linuxはパッケージマネージャで）
mkdir -p ~/.config/backup && chmod 700 ~/.config/backup
age-keygen -o ~/.config/backup/age.key            # 秘密鍵（復元用）
chmod 600 ~/.config/backup/age.key
age-keygen -y ~/.config/backup/age.key > ~/.config/backup/age.pub   # 公開鍵（暗号化用）
```

**この時点で `~/.config/backup/age.key` の中身をパスワードマネージャーにコピーしておきます。** 後回しにすると、たいてい忘れます。

### 2. 設定ファイルを作る

`~/.config/backup/backup.conf` を作成します（スクリプト本体には環境固有の値を書きません）。

```bash
WORKSPACE_DIR="$HOME/your-workspace"          # バックアップ対象のワークスペース
FOLDER_ID="xxxxxxxxxxxxxxxxxxxxxxxxxxx"       # 保存先クラウドフォルダのID
NOTIFY_EMAIL="you@example.com"                # 失敗通知の宛先
RETENTION=14                                  # 保持する世代数
PLIST_PREFIXES="com.example com.yourname"     # 収集する自動実行ジョブのラベル接頭辞
```

保存先フォルダIDは、クラウドストレージ側でバックアップ用フォルダを作り、そのURLから取得します。

スクリプトは `templates/scripts/local-backup.sh` をワークスペースのスクリプト置き場にコピーして使います。バックアップしたいローカル専用フォルダがある場合は、スクリプト冒頭の `LOCAL_DIRS` に追記してください。

実装例ではアップロードと通知にGoogle Workspace CLI（`gws`）を使うため、事前に認証を済ませておきます（別のクラウドを使う場合は、アップロード・ダウンロード・一覧・削除の4箇所をそのCLIに置き換えます）。スクリプトは実行の冒頭で設定ファイル・鍵・コマンドの存在を確認し、足りなければその場で失敗して通知します。「気づかないうちに中身が空のバックアップが取れ続ける」ことを防ぐためです。

まずは手動で1回実行し、ログを確認します。

```bash
bash scripts/local-backup.sh
tail -20 ~/.local/state/workspace-backup/backup.log
```

「ローカル復号検証 OK」「リモート検証 OK」の2行が出れば成功です。

### 3. 毎日自動実行させる

macOSならlaunchdに登録します。`~/Library/LaunchAgents/com.example.workspace-local-backup.plist` を作成します（`com.example` と各パスは自分の環境に置き換え）。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.workspace-local-backup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOUR_NAME/your-workspace/repo_workspace-setup/scripts/local-backup.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/YOUR_NAME/.local/state/workspace-backup/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOUR_NAME/.local/state/workspace-backup/launchd.log</string>
</dict>
</plist>
```

**ターミナルで実行：**

```bash
launchctl load ~/Library/LaunchAgents/com.example.workspace-local-backup.plist
launchctl list | grep workspace-local-backup
```

Linuxならcronやsystemd timerで同じことをします。実行時刻はPCが起動している時間帯にしてください（ノートPCなど電源が落ちている時間がある場合は、起動時に実行する設定を併用します）。

## 復元手順の概要

新しいマシンでの復元は、次の流れになります。

1. クラウドストレージをブラウザで開き、最新の `backup-*.tar.gz.age` をダウンロードする（CLIの認証情報自体がバックアップの中にあるため、**復元の入口はブラウザだけで完結する**必要があります）
2. age を入れ、パスワードマネージャーから秘密鍵を `~/.config/backup/age.key` に戻す
3. 復号して展開する

   ```bash
   mkdir -p ~/restore
   age -d -i ~/.config/backup/age.key backup-XXXXXXXX.tar.gz.age | tar -xzf - -C ~/restore
   ```
4. `~/restore/MANIFEST.txt` で中身を確認し、各ファイルを元の場所へ戻す（`.env` は各リポジトリの同じ相対パスへ、`claude/` は `~/.claude/` へ、plistは `~/Library/LaunchAgents/` へ置いて再登録）
5. リポジトリ本体は同期スクリプトで再clone、`node_modules` は再インストール

アーカイブに `MANIFEST.txt`（ファイル一覧＋自動実行ジョブの稼働状況スナップショット）を含めておくと、この作業が「一覧を見ながら戻すだけ」になります。

**この手順書自体は、復元手順を書いたリポジトリごと失われても読めるように**、印刷するか、パスワードマネージャーのメモに要点（鍵の場所・保存先フォルダ・展開コマンド）を残しておいてください。

## 残るリスクを自覚しておく

この構成でも消えない弱点が2つあります。仕組みを作った時点で認識しておき、必要になったら対策します。

- **クラウドアカウントが単一障害点** — 保存先がクラウドストレージなので、そのアカウントが停止・乗っ取られると本番とバックアップを同時に失います。気になる段階になったら、外付けディスクへのバックアップや別系統のクラウドを追加します
- **ジョブの静かな停止** — 前述のとおり、起動しなくなった場合は通知が飛びません。成功マーカーの定期確認だけは習慣にしてください

## この章のまとめ

| 守る対象 | 手段 |
|----------|------|
| リポジトリの中身 | Git / リモートリポジトリ（既に守られている） |
| Git管理外のファイル | このバックアップ（暗号化＋世代管理＋毎回の検証） |
| 復号のための秘密鍵 | パスワードマネージャー（バックアップ先とは別の場所） |
| 仕組みが動いているか | 成功マーカーの日付確認 |

「壊れたら困るものが、いまどこにあるか」を一度書き出してみると、この章の対象は驚くほど少ないことがわかります。少ないからこそ、自動化して忘れられる状態にする価値があります。
