# kooky

[![License](https://img.shields.io/github/license/iAmCorey/kooky?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-007AFF?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/iAmCorey/kooky/total?style=flat-square)](https://github.com/iAmCorey/kooky/releases)
[![Stars](https://img.shields.io/github/stars/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/stargazers)

> *AI コーディングのためのミニマルでモダンな macOS ターミナル。*

🇯🇵 日本語  ·  🇬🇧 [English](README.md)  ·  🇨🇳 [中文](README_CN.md)

![kooky](img/screenshot-1.png)

AI コーディングのために作られた、ミニマルでモダンな macOS ターミナルです。サイドバーで workspace を管理、水平 / 垂直の split pane、ワンクリックで agent を起動、agent のステータスをリアルタイム表示、pane 下部で Git・Node・Python など作業環境の状態が一目で確認できます。オープンソース、MIT ライセンス。アカウント不要、テレメトリなし、アプリの状態は端末内にのみ保存。GPU レンダリングは [libghostty](https://github.com/ghostty-org/ghostty) ベース。

**[最新版をダウンロード](https://github.com/iAmCorey/kooky/releases/latest)**  ·  [変更履歴](CHANGELOG.md)

---

## 機能

**垂直 tab、split pane、複数ウィンドウ。** サイドバーで全ての workspace を管理、3 段階の幅切り替え (`⌘⌃S`)。サイドバーの右端をドラッグして広げることもでき、幅はウィンドウごとに記憶されます。各 pane が独自の tab バーとアクティブ tab を持ち、tab バー右側の 2 つのボタンや ⌘D / ⌘⇧D で右 / 下に分割できます。tab は ⌘R、workspace は ⌘⇧R で名前を変更できます。`⌘⇧N` で新しいウィンドウを開きます。tab はドラッグで並び替え、pane 間の移動、別ウィンドウへの移動が可能 —— セッションが scrollback と実行中のプロセスごとまるごと移動します。アプリ再起動後も状態は復元され、開いていた全ウィンドウが復元されます。任意のフォルダを新しい workspace として開く方法：Finder からサイドバーにドロップするか、⌘O。`⌘⇧E` でアクティブな pane を最大化、もう一度押すと元に戻ります —— 他の pane は画面外にスライドしますが、プロセスは走り続けています。

![左側に垂直 tab、1 つの pane を 4 分割](img/screenshot-2.png)

**workspace を一目で見分ける。** workspace を右クリックして色を付けられます —— 7 つのプリセット、または **Custom Tag…** で好きな色と名前を。行の左端に縦線として表示され、サイドバーの広い / 狭いどちらでも出ます。同じ色をもう一度クリックすれば解除されます。タグは agent パネルにも引き継がれるので、「誰があなたを必要としているか」順に並ぶあの一覧の中で、同じプロジェクトの agent が自然に一つのまとまりとして読めます (Settings → Appearance でオフにできます)。workspace にホバーすると、タイトル・`#タグ`・動いている agent・場所が表示されます。

**ワンクリックで AI agent セッション。** `+` メニューから選ぶだけで、最初の prompt を打つ前に agent が起動します。15 個すべてが各 CLI 固有の session ID を使って kooky の再起動を跨いで会話を resume するので、tab を閉じて再度開いても直前の続きから再開できます。

| Agent | コマンド | ユーザー待ち | ツール pill | セッション履歴 |
| --- | --- | :---: | :---: | :---: |
| Claude Code | `claude` | ✓ | ✓ | ✓ |
| Codex | `codex` | ✓ | ✗ | ✓ |
| Gemini CLI | `gemini` | ✓ | ✗ | ✓ |
| OpenCode | `opencode` | ✓ | ✗ | ✓ |
| Amp | `amp` | ✓ | ✗ | ✗ |
| Cursor CLI | `cursor-agent` | ✓ | ✗ | ✓ |
| Copilot CLI | `copilot` | ✓ | ✗ | ✓ |
| Grok Build | `grok` | ✗ | ✗ | ✓ |
| Antigravity CLI | `agy` | ✓ | ✗ | ✗ |
| Kimi Code | `kimi` | ✓ | ✗ | ✓ |
| Pi | `pi` | ✓ | ✓ | ✓ |
| Oh My Pi (new) | `omp` | ✓ | ✓ | ✓ |
| Reasonix (new) | `reasonix` | ✓ | ✓ | ✓ |
| Kiro CLI | `kiro-cli` | ✗ | ✗ | ✓ |
| Droid | `droid` | ✓ | ✗ | ✓ |

**ユーザー待ち**: agent が停止して応答を必要としている時 (ツールの承認待ちを含む) にドットが琥珀色になります。Grok Build と Kiro CLI はこの信号を出さないため、ドットは実行中と終了のみを表します。**ツール pill**: 現在実行中のツールを pane 下部のステータスバーに表示します。**セッション履歴**: 過去の会話を agent パネルの履歴ページで閲覧・再開できる agent を示します —— 下記参照。使わない agent は Settings → Agents で非表示にできます。

![対応する全 agent、それぞれ Settings で切り替え可能](img/screenshot-4.png)

**自分の agent を追加。** 一覧にないものは Settings → Agents から追加できます —— 名前とコマンドを入れれば `+` メニューに並び、他の tab と同じように起動します。さらに内蔵 agent をベースに選ぶと、その agent の起動バイナリ・アイコン・アクティビティ追跡まで引き継ぎます —— サイドバーのドットは内蔵 agent の wrapper が報告しているので、コマンドだけの場合は起動はしてもドットは点きません。どちらの場合も独自のロゴ (PNG / JPEG / SVG、64×64 推奨) をアップロードでき、tab・サイドバー・agent パネル・Quick Open のすべてに反映されます。Claude ベースのものは独自の環境変数も持てるので、ミラーや proxy のエンドポイントを shell alias ではなく本物の agent として登録できます。

**Git worktree。** 任意の git workspace を右クリック → "Create Worktree…" で新しい branch (または既存 branch の checkout) に対する worktree を作成します。worktree はサイドバーで元のリポジトリの下にネストして表示され、独自の tab + agent を持ちます —— main で何かが走っている最中でも、Claude を feature branch で並行して動かせます。コマンドラインで `git worktree add` した worktree は、同じシートの adopt モードでいつでもサイドバーに取り込めます。ディレクトリが消えたエントリは起動時に自動でクリーンアップされます。

**SSH workspace。** File → New SSH Workspace… (または ⌘P) で、リモートマシン上に「住む」workspace を作成します。以降の新しい tab・分割ペイン・再起動時に復元される tab は、すべて同じホストへ自動で再接続します。agent tab を開くと agent はリモート側で起動 —— リモート自身のシェル設定を読み込んでから始まるので、nvm などで入れたツールもきちんと見つかります。ローカルのファイルやスクリーンショットを貼り付けると、kooky が先にアップロードしてからリモートパスを貼り付けるため、向こうの agent が実際に開けます。同一ホストへの接続は共有され、追加の tab は即座に接続。パスワード認証のホストでも貼り付けを含めて全部使えます。

**Keep-awake(スリープ防止)。** agent が作業中に Mac が寝てしまうことはありません。トップバーの呼吸するインジケーターライトをクリックすると 3 段階を循環します:Off;Auto —— agent の作業中や SSH 接続中はスリープせず(蓋を閉じても継続、初回のみ管理者認証が必要)、作業が終わった瞬間に通常のスリープへ戻ります;Always —— 目に見える caffeinate として、切り替えるまでずっと起きたままです。kooky の外でスリープ設定を変えても(`sudo pmset` や他のツール)、数秒でダイヤルが双方向に追従します。

**最近使ったプロジェクト。** kooky は workspace を開いたフォルダを自動で記憶します —— 設定も手動追加も不要。File → Open Recent から選ぶか、⌘P でプロジェクト名を入力して Enter で再オープン:閉じたプロジェクトは「recent」エントリとして表示されます。削除済みフォルダは自動的に隠れ、worktree / SSH ディレクトリがリストに混ざることもありません。

**選択範囲を右クリック → "Ask <agent>"。** ターミナル内でエラー / ログ / ファイルパスを選択して右クリック、好きな agent を選ぶと、新しい tab が開いた時点で選択範囲が最初の prompt として送信済みの状態になります。⌘C / ⌘V の往復なしで "これは何？" から答えに直行。

**クイックオープン (⌘P)。** 全ウィンドウの workspaces、tabs、agents、Terminal preset、最近使ったプロジェクトを 1 つのフローティングパネルから fuzzy 検索。文字を打って絞り込み、↑↓ で選択、Enter でジャンプまたは起動。⌘P または上部 chrome の検索 pill から呼び出せます。

**サイドバーのファイルツリー。** サイドバー下部のトグルで workspace リストをアクティブな workspace フォルダのファイルツリーに切り替えられます。ディレクトリの展開、ダブルクリックでファイルを開く、右クリックで「Finder で表示 / パスをコピー / ターミナルにパスを挿入」(ファイル行には「開く」も)——ファイルやフォルダをそのままターミナルにドラッグすれば、エスケープ済みのパスが挿入されます (Finder からのドラッグと同じ)。変更のあるファイルには `+X −Y` の行数が表示され (ステータスバーの git diff と同じ数字)、折りたたんだフォルダはサブツリーの変更を合算表示します。ツリーはアクティブな tab のディレクトリに追従し (worktree workspace はその worktree フォルダに固定)、ディスク上の変更を自動で反映します。

**ストレスのない入力。** テキストを選択すると、マウスを離した瞬間にクリップボードへコピーされます — ⌘C は不要で、Ghostty の設定に関わらずどのマシンでも有効です (Settings → General → Clipboard でオフにできます)。⌘ を押しながら `/path/file.swift:42` のようなローカルファイルパスをクリックすると、指定したエディタで開けます。Web リンクに使うブラウザも選択できます (Settings → General → Open With)。zsh の prompt 上のどこをクリックしても shell カーソルがそこに移動します (modifier 不要、ghostty.app と同じ操作感)。Finder からファイル / フォルダを pane にドラッグすると、エスケープ済みの絶対パスがカーソル位置に挿入されます。 ⌘ を押しながら URL(または OSC 8 ハイパーリンク)にホバーすると、クリック前にバッジが実際のリンク先を表示します。中クリックでペーストできます。Option を Alt/Meta として使いたい場合(zellij、Emacs キーバインド)は settings.json で `macos-option-as-alt`(`true` / `"left"` / `"right"`)を設定してください — 未設定なら macOS ネイティブの特殊文字入力のままです。分割表示中は `focus-follows-mouse` でポインタの下の pane にキーボードフォーカスが移り、`mouse-hide-while-typing` で入力中はカーソルが自動的に隠れます。

**クリップボードと入力の安全。** 貼り付けた瞬間に実行されかねないテキスト(bracketed-paste 保護外の複数行)は、内容プレビュー付きの確認を先に表示します — Web からコピーした罠付き `curl … | sh` が ⌘V で即実行されることはありません。リモートプログラムによる OSC 52 でのクリップボード読み取り(tmux、SSH 上の nvim)は承認が必要で、`clipboard-write = ask` は書き込みも同様に守ります。sudo / ssh のパスワード入力中は kooky が macOS のセキュア キーボード入力を保持し、他プロセスはキー入力を監視できません。

**Prompt composer (⌘L)。** pane 下部からチャット風の入力ボックスがせり上がり、長い複数行の prompt を落ち着いて書けます —— うっかり Return で途中送信されることはありません。Return で現在の agent (または shell) に送信、Shift+Return で改行、Esc でキャンセル (下書きは保持)。⌘L か pane 下部ステータスバーの compose ボタンで開きます。

**Agent ステータスをリアルタイム表示。** サイドバーのドットが各 agent の状態を示します —— 実行中 (青)、ユーザー待ち (琥珀)、アイドル (なし)。直前のコマンドが非ゼロ終了したときは tab と workspace のドットが赤くなり、ホバーで `exit N · 12.4s` が確認できます。上の表でツール pill が付いている agent は、pane 下部のステータスバーに今走らせているツール (Bash / Edit / Read など) と経過時間も表示されます —— pill をクリックすればセッション全体の履歴を確認でき、失敗したツール呼び出しはすぐに赤くなります。pill は Settings → Status Bar で agent ごとに表示/非表示を切り替えられます。

**zsh・bash・fish に対応。** 手入力した agent の検出、cwd 追跡、ステータスバーの各スロット、ワンクリック agent 起動が 3 つの shell すべてで同じように動作します —— Fig / Amazon Q / kiro のような shell 補完ツールを併用していても動き続けます。

**通知。** 見ていない tab で agent がユーザー待ちになったり、そこでコマンドが失敗したりすると、kooky が macOS 通知を出します —— 種類ごとに Settings → Notifications でオン / オフできます。上部 chrome のベル (⇧⌘I) は、それらの通知を全ウィンドウ横断で 1 つの受信箱にまとめます —— 誰が待っているか、何が失敗したか、何が完了したか —— 未読があれば赤いドットが点きます。エントリをクリックすればその tab に直接ジャンプ、tab に切り替えればその通知は自動でクリアされます。 ターミナル内のプログラム自身も通知を出せます(OSC 9/777、`printf '\e]9;done\a'`):tab が見えていなければバナーが出て、どちらにしても受信箱に残ります。ベル(`\a`)はデフォルトで Dock のアテンションを要求し、`bell-features` でシステム音やカスタム音声も設定できます。

![全ウィンドウ横断で集約される通知センター](img/screenshot-3.png)

**Agent パネル。** 上部のトグル (左サイドバーと同じ 3 段階の折りたたみ) で右サイドバーを開くと、全ウィンドウの agent を一覧でき、あなたを必要とする順に並びます —— ユーザー待ち、失敗、実行中、アイドル。任意の行をクリックすればその tab に直接ジャンプ、コンパクトモードではステータス色のドット付きアイコンの細い列に縮みます。

**セッション履歴。** Agent パネルを 2 ページ目 (下部の時計アイコン) に切り替えると、ほとんどの内蔵 agent (上の表参照) の過去の会話を新しい順に一覧できます —— kooky の外で始めた会話も含まれます。タイトルやプロジェクトで検索、agent で絞り込み、行をクリックすればその会話を再開: 会話の元のフォルダに新しい tab が開き、agent 自身のセッション ID でコンテキストが完全に復元されます。

![過去の Claude Code / Codex の会話を検索して再開](img/screenshot-5.webp)

**セッション情報。** Agent パネルの 3 ページ目 (下部の ⓘ アイコン) はアクティブな tab のインスペクタです: workspace・ディレクトリ・リモートホスト・git branch / リポジトリ / diff・Python venv・Node バージョン・proxy に加え、CPU・メモリ・listen 中のポートを示すライブなプロセスツリー、直前に完了したコマンドとその終了コード・所要時間 (zsh/fish)、ターミナルタイトルまで確認できます。見るだけではありません: フィールドにホバーして完全な値をワンクリックでコピー、ポートをクリックしてブラウザで開く、プロセスを右クリックして PID のコピーや終了ができ、ローカルセッションで失敗したコマンドには **Ask AI** ボタンが現れて、コマンド・終了コード・ディレクトリをそのまま agent の新しい tab に渡します。折りたたみ状態は再起動後も保持され、作業に合わせてリアルタイムに更新されます。コマンドラインはメモリ内にのみ保持され、ディスクには書き込まれません。

**メニューバーの Agent 一覧。** macOS のメニューバーに任意で Kooky アイテムを表示でき、agent が存在するときだけリアルタイムの件数が付きます。開くと、すべてのアクティブな agent tab のタイトルとプロジェクトパスを確認して直接ジャンプできるほか、Open Kooky、Settings、Keep Awake の 3 段階切り替え、Quit も利用できます。Settings → General → `show-in-menu-bar` で表示を切り替えられます。

**エディタやターミナルで開く。** 上部 chrome の分割ボタンが、現在の tab のディレクトリを別のアプリに渡します。アイコンをクリックすると直前に使ったアプリで再度開き、シェブロンをクリックすると Mac にインストール済みの対応アプリから選べます: VS Code · Cursor · Windsurf · Zed · Sublime Text · Antigravity · Trae · Kiro · Xcode · IntelliJ IDEA · PyCharm · WebStorm · Terminal · iTerm · Ghostty · Warp · Finder。Settings → Open in で並べ替えや非表示ができます。

**作業環境の状態が一目で見える。** pane 下部のステータスバーに Git リポジトリ + branch + diff (`N files +X −Y`)、Python venv、Node バージョン、有効中の proxy (`https_proxy` / `http_proxy` / `all_proxy`)、そしてリモートに SSH したときのログイン先 `user@host` (Settings → General で有効化) を表示。agent の Bash ツールや別ターミナルで branch を切り替えても自動で更新されます。Node バージョンや Git branch の pill をクリックすればコマンドを打たずに切り替え可能、リポジトリの pill をクリックすると GitHub (GitLab / Bitbucket も対応) で開く・URL のコピー・Finder で表示ができ、proxy pill をクリックすると完全な `name=value` を表示してコピーできます。

**SwiftUI ネイティブ、ミニマルな chrome。** Onest + JetBrains Mono。カスタム About パネル、ショートカットヒント付きのネイティブメニュー、日本語 IME を完全サポート。

**Light + Dark のペアテーマ。** Light 用と Dark 用の terminal 配色をそれぞれ選び、System / Light / Dark の外観モードは別に設定できます。System は macOS の変更にリアルタイムで追従し、terminal とウィンドウ全体を同時に切り替えます。40 種類以上の組み込み配色には **Ghostty Dark**、Ayu、Catppuccin、Everforest、GitHub、Gruvbox、Material、Night Owl、Nord、Rosé Pine のほか、Codex Desktop でも使われているオープンソーステーマが含まれます。`~/.config/ghostty/themes` のカスタムテーマは背景色に応じて Light または Dark の picker に自動表示されます。組み込みテーマの設定値には `kooky:` 名前空間を使うため、同名の Ghostty カスタムテーマもアップグレード後にそのまま維持されます。以前の Default の挙動も維持され、テーマを選んだことがない場合は Appearance を変更するまで Ghostty の設定を引き継ぎます。 ターミナル内のプログラムが「背景は暗い?」と問い合わせると(nvim の background 自動検出、delta)、現在の kooky テーマに基づく答えが返ります。引き継いだ Ghostty 設定の `theme = light:X,dark:Y` 条件テーマも正しく解決されます。

**設定可能。** Settings (`⌘,`) ではフォント、カーソル、背景の不透明度(liquid-glass または数値の `background-blur` と組み合わせると、どの macOS でも伝統的なすりガラス表現になります)、デフォルトの新規 tab 挙動、Terminal preset、agents、Open in、pane ステータスバーも調整できます。`confirm-close-surface` をオンにすると、プロセスが動作中の tab を閉じる前に確認が入ります。外観の変更は開いているすべてのウィンドウに即時反映されます。

**ディープリンク。** 他のアプリから kooky で agent の会話を再開できます。`kooky://resume?agent=<agent>&id=<会話id>[&cwd=<パス>]` は、会話がすでに開いていればその tab へジャンプし、なければ会話のプロジェクトディレクトリで新しい tab として再開します（`agent` は History パネルと同じ id を受け付けます: `claude-code`、`codex`、`copilot`、`cursor`、`opencode`、`kiro`、`gemini` など）。オプションの `cwd` を付けると、セッションスキャンの保持範囲より古い会話も再開できます。会話 id は厳密に検証され、リンクからプロンプトやコマンドは渡せません。拒否されたリンクは理由をシートで表示します。`cwd` のスペースは `%20` でエンコードしてください（`+` はデコードされません）。

**ローカルファースト。** アカウント不要、テレメトリなし、クラウド同期なし。kooky の状態はすべて端末内に保存されます。

**libghostty 駆動。** ghostty と同じ GPU 加速セルレンダリングエンジン。画面のリフレッシュレートに同期して描画するので、120Hz / ProMotion ディスプレイでもスクロールが滑らかでティアリングしません。

## インストール

[Releases](https://github.com/iAmCorey/kooky/releases) から最新の `.dmg` をダウンロード、開いて `Kooky.app` を `Applications` フォルダにドラッグしてください。

**初回起動は Gatekeeper にブロックされます**。現在のビルドは adhoc 署名 (Apple Developer ID 未取得 —— 公開配布署名と公証は実際のユーザーが増えてから対応予定) なので、*"Kooky cannot be opened because Apple cannot check it for malicious software"* または *"is damaged and cannot be opened"* というエラーが出ます。下記の 3 通りからどれか一つを実行してください：

<details>
<summary><b>方法 A —— システム設定から <i>(推奨)</i></b></summary>

1. まず `Kooky.app` をダブルクリック。macOS が警告を出すのでダイアログを閉じます。
2. **システム設定 → プライバシーとセキュリティ** を開き、**セキュリティ** セクションまでスクロール。
3. *"Kooky was blocked to protect your Mac"* の隣に表示される **Open Anyway** をクリックし、パスワードを入力。
4. もう一度 `Kooky.app` をダブルクリック、今度は **Open** ボタンが表示されるのでクリックして完了。
</details>

<details>
<summary><b>方法 B —— ターミナル 1 行</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```
</details>

<details>
<summary><b>方法 C —— "Open Anyway" ボタンすら表示されない場合</b></summary>

Sequoia 以降では adhoc 署名アプリに対して "Open Anyway" ボタンが完全に隠れることがあります。その場合は旧版の "Anywhere" オプションを一旦有効化してから方法 A をやり直します：

```sh
sudo spctl --global-disable      # macOS 15+；古いシステムは --master-disable
# システム設定 → プライバシーとセキュリティ → "Allow applications from" で Anywhere を選択
# Kooky.app をダブルクリック → 起動できるはず
sudo spctl --global-enable       # Kooky が一度起動したら、すぐに Gatekeeper を戻す
```

注意：これは **システム全体の設定** です。無効の間はあらゆる未署名アプリの起動を許可してしまいます。Kooky が一度起動したら必ず元に戻してください。Kooky 自体は個別に信頼済みとして記憶されるので、以後ブロックされません。
</details>

macOS は **初回起動のみブロック** します。それ以降は Spotlight / Dock / Finder から通常のアプリと同じように起動できます。

## ソースからビルド

Xcode 26+ と macOS 14+ (Sonoma —— `@Observable` の最低システム要件) が必要です。

```sh
./scripts/setup-libghostty.sh        # 初回のみ：プリビルドの libghostty xcframework を Vendor/ にダウンロード
swift build
swift run                            # 開発モードで直接起動
swift test                           # 850+ 個のユニットテスト
./scripts/bench.sh                   # パフォーマンスベンチマーク (release ビルド、結果は bench-history.jsonl に記録)

./scripts/build-app.sh               # dist/Kooky.app を出力
./scripts/build-dmg.sh --build       # dist/Kooky-vX.Y.Z.dmg を出力
```

`Vendor/` と `dist/` は `.gitignore` 済みです。libghostty の setup スクリプトは冪等で、SHA に変更がなければスキップされます。

## スター履歴

[![Star History Chart](https://api.star-history.com/chart?repos=iAmCorey/kooky&type=date&legend=top-left&sealed_token=ZX5h8laOXIE38b__FRNpP7ae52yRupThIRrcgidF7RI0OOzVcsKIo1iJ_iDp6UcMoxzNCL99N3RY__N7TFUszIgxzljBSBRRiAPYPt9QC9lKf7X3ShAQJg)](https://www.star-history.com/?type=date&repos=iAmCorey%2Fkooky)

## ライセンス

MIT —— [LICENSE](LICENSE) を参照。同梱されているサードパーティ製アセットはそれぞれのライセンスに従います。詳細は [NOTICE.md](NOTICE.md) を参照。
