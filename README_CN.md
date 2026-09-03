# kooky

[![License](https://img.shields.io/github/license/iAmCorey/kooky?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-007AFF?style=flat-square)](https://github.com/iAmCorey/kooky/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/iAmCorey/kooky/total?style=flat-square)](https://github.com/iAmCorey/kooky/releases)
[![Stars](https://img.shields.io/github/stars/iAmCorey/kooky?style=flat-square)](https://github.com/iAmCorey/kooky/stargazers)

> *专为 AI coding 优化的极简 macOS 终端。*

🇨🇳 中文  ·  🇬🇧 [English](README.md)  ·  🇯🇵 [日本語](README_JA.md)

![kooky](img/screenshot-1.png)

专为 AI coding 优化的极简 macOS 终端。支持侧边栏 workspace 管理、水平 / 垂直分屏、一键启动 agent、实时查看 agent 状态，也能在 pane 底部直接看到 Git、Node、Python 等工作区状态。开源，MIT 许可；不需要账号，不做遥测，应用状态都留在本机。GPU 渲染基于 [libghostty](https://github.com/ghostty-org/ghostty)。

**[下载最新版](https://github.com/iAmCorey/kooky/releases/latest)**  ·  [更新日志](CHANGELOG.md)

---

## 功能

**垂直 tab、分屏、多窗口。** 侧边栏管理所有 workspace，三档宽度可切换（`⌘⌃S`），还能拖右边缘加宽,宽度按窗口记忆。每个 pane 都有独立 tab 栏和当前 tab，用 tab 栏右侧两个按钮或 ⌘D / ⌘⇧D 就能向右 / 向下分屏。⌘R 重命名 tab、⌘⇧R 重命名 workspace。`⌘⇧N` 打开新窗口。tab 可以拖动排序、跨 pane 移动，也能拖进另一个窗口 —— 实时会话整体带过去，scrollback 和正在跑的进程都在。重启后状态自动恢复，每个打开的窗口都会还原，位置和大小也回到你离开时的样子。把任意文件夹打开成新 workspace:从 Finder 拖到 sidebar,或者按 ⌘O。按 `⌘⇧E` 把当前 pane 放大占满 workspace 再按一次还原 —— 其他 pane 滑出视野但进程还在跑。

![左侧竖直 tab，一个 pane 分成四块](img/screenshot-2.png)

**让 workspace 一眼可分。** 右键任意 workspace 给它一个颜色 —— 七个预设，或者 **Custom Tag…** 自己选颜色、起个名字。它会在行的左边缘画一条竖条，展开和紧凑两种宽度下都在；再点一次当前颜色就取消。标签也会带到 agent 面板里，于是同一个项目的所有 agent 在那个按「谁最需要你」排序的列表里自然聚成一组（可以在 Settings → Appearance 里关掉）。hover 一个 workspace 会显示它的标题、`#标签`、正在跑哪些 agent，以及它在哪。

**一键启动各种 agent。** `+` 菜单里选一个,agent 会在第一个 prompt 出现前启动。十五个 agent 全都能跨 kooky 重启自动 resume,用的是每个 CLI 自己的 session ID,关掉 tab 再打开能从离开的地方接上。

| Agent | 命令 | 等你处理 | 工具 pill | 会话历史 |
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
| Oh My Pi | `omp` | ✓ | ✓ | ✓ |
| Reasonix | `reasonix` | ✓ | ✓ | ✓ |
| Kiro CLI | `kiro-cli` | ✗ | ✗ | ✓ |
| Droid | `droid` | ✓ | ✗ | ✓ |

**等你处理**:agent 停下来需要你回应时圆点变琥珀色,包括在等你批准某个工具;Grok Build 和 Kiro CLI 没有这个信号,所以它们的圆点只报运行中和已结束。**工具 pill**:在 pane 底部状态栏显示当前正在跑的工具。**会话历史**:标出哪些 agent 的历史对话能在 agent 面板的历史页里翻阅和恢复——见下文。用不上的 agent 可以在 Settings → Agents 里隐藏。

![支持的所有 agent，每个都能在 Settings 里单独开关](img/screenshot-4.png)

**也可以自己加 agent。** 列表里没有的自己加：Settings → Agents 里填个名字和一条命令，它就会出现在 `+` 菜单里，像任何 tab 一样启动。再挑一个内置 agent 作为基础，它还会连那个 agent 的启动程序、图标和活动状态一起继承——侧边栏那个状态点是内置 agent 的 wrapper 报上来的，所以只填一条裸命令能跑，但点不会亮。两种配置都能传自己的 logo（PNG / JPEG / SVG，建议 64×64），tab、侧边栏、agent 面板、Quick Open 里都会用上。基于 Claude 的还能带自己的环境变量，镜像或代理端点因此可以做成一个真正的 agent，而不是一条 shell alias。

**Git worktree。** 右键任意 git workspace → "Create Worktree…",在新 branch 上(或 checkout 已有 branch)起一个 worktree。Worktree 在 sidebar 里缩进显示在源 repo 下面,有自己的 tab + agent —— 让 Claude 在 feature branch 上跑活,不打扰 main 上正在跑的进程。命令行 `git worktree add` 建的 worktree,用同一个面板里的 adopt 模式随时收进 sidebar;目录已经没了的条目会在启动时自动清理。

**SSH workspace。** File → New SSH Workspace…(或 ⌘P)创建一个"住"在远程机器上的 workspace:之后每个新 tab、分屏、重启恢复的 tab 都自动重连同一台主机。开 agent tab 时 agent 直接在远端启动 —— 远端自己的 shell 配置加载完才启动,nvm 装的工具都找得到。往里粘贴本地文件或截图时,kooky 先上传再粘贴远端路径,对面的 agent 才真的打得开。同一主机的连接是共享的:后续 tab 秒连,密码登录的主机也全程可用,包括粘贴上传。

**防睡眠(keep-awake)。** agent 干活时 Mac 不会睡过去。顶部一颗会呼吸的指示灯,点击在三档间循环:Off;Auto —— agent 干活或 SSH 连接期间保持清醒,合盖也不睡(首次需一次管理员授权),活一干完就恢复正常作息;Always —— 看得见的 caffeinate,机器一直醒着直到你调回来。在 kooky 之外改了系统禁睡(`sudo pmset`、别的工具)也没关系,几秒内档位自动跟上,双向同步。

**最近项目。** kooky 自动记住你开过 workspace 的每个文件夹 —— 不用配置、不用手动添加。File → Open Recent 里直接选,或者 ⌘P 输项目名回车重开:关掉的项目会以「recent」条目出现。删掉的文件夹自动隐藏,worktree / SSH 目录不会混进列表。

**右键选中 → "Ask <agent>"。** 在 terminal 里选中一段 error / 日志 / 文件路径,右键挑任意 agent,新 tab 一打开,selection 已经作为第一条 prompt 发出去了,直接开始回答 —— 不用 ⌘C / ⌘V 来回切。

**快速打开(⌘P)。** 一个浮动面板模糊搜索所有 window 的 workspaces、tabs、agents、Terminal presets 和最近项目。输入关键字筛选,↑↓ 选,Enter 跳过去或者新开一个。⌘P 或顶部 chrome 上的 search pill 都能触发。

**侧边栏文件树。** 侧边栏底部的切换按钮把 workspace 列表换成当前 workspace 文件夹的文件树。目录可展开、双击文件用默认程序打开,右键有在访达显示 / 拷贝路径 / 把路径插入终端(文件行还多一个「打开」)—— 也可以直接把文件或文件夹拖进终端,escape 好的路径就插到光标处,跟从 Finder 拖进来一样。改动过的文件会显示 `+X −Y` 行数(和状态栏 git diff 同一套数字),折叠的文件夹汇总其子树的改动。文件树跟随当前 tab 的目录(worktree 工作区固定在各自的 worktree 目录),磁盘上文件一变就自动刷新。

**输入顺手。** 选中即复制：在终端里选中文本，松开鼠标那一刻就已经进了系统剪贴板，不用再按 ⌘C——不管本机 Ghostty 配置怎么写，每台机器都生效（可在 Settings → General → Clipboard 里关掉）。按住 ⌘ 点击 `/path/file.swift:42` 这样的本地文件路径，就能用指定的编辑器打开；网页链接也能指定浏览器（Settings → General → Open With）。在 zsh 提示行点哪儿光标就跳哪儿(不用按 modifier,跟 ghostty.app 一致)。从 Finder 把文件或文件夹拖到任意 pane,绝对路径会自动 escape 后插到光标位置。 按住 ⌘ 悬停任意 URL(或 OSC 8 超链接),角标会先揭示真实指向再让你点。鼠标中键即粘贴。想把 Option 当 Alt/Meta 用(zellij、Emacs 快捷键)?在 settings.json 里配 `macos-option-as-alt`(`true` / `"left"` / `"right"`),不配则保留 macOS 原生特殊字符输入。分屏时开启 `focus-follows-mouse`,鼠标滑到哪个 pane 键盘焦点就跟到哪;`mouse-hide-while-typing` 让指针在打字时自动隐藏。

**剪贴板与输入安全。** 粘贴的内容如果落地就可能执行(未受括号粘贴保护的多行文本),会先弹出带内容预览的确认框——从网页复制的带陷阱 `curl … | sh` 无法借 ⌘V 直接执行。远程程序通过 OSC 52 读你的剪贴板(tmux、SSH 里的 nvim)需要你先授权,`clipboard-write = ask` 同样把守写入。输入 sudo / ssh 密码时,kooky 持有 macOS 安全键盘输入,其他进程无法监听按键。

**Prompt composer (⌘L)。** pane 底部升起一个聊天式输入框，让你安心写长的、多行的 prompt——不会手一抖回车就发出去。回车发给当前 agent（或 shell），Shift+回车换行，Esc 取消并保留草稿。⌘L 或 pane 底部状态栏的 compose 按钮打开。

**Agent 状态实时展示。** 侧边栏圆点显示每个 agent 的状态：运行中（蓝）、等待你处理（琥珀）、空闲（无色）。上一条命令非零退出时，tab 和 workspace 会同步显示红点；悬停可看到 `exit N · 12.4s`。上表标了工具 pill 的 agent 还会在 pane 底部状态栏显示当前正在跑的工具（Bash / Edit / Read 等）和已运行的时间——点击 pill 看完整历史；失败的工具调用立刻变红。可在 Settings → Status Bar 里按 agent 单独开关这个 pill。

**zsh、bash、fish 都支持。** 手输 agent 识别、cwd 跟踪、状态栏插槽、一键启动 agent，在三种 shell 下表现一致——即使开着 Fig / Amazon Q / kiro 这类 shell 自动补全工具也照常工作。

**通知。** 你没在看的某个 tab 里 agent 开始等你处理、或那里命令失败时，kooky 会发一条 macOS 系统通知——每一类都能在 Settings → Notifications 里单独开关。顶栏还有个铃铛（⇧⌘I），把这些提醒跨窗口收进一个收件箱——谁在等你、什么失败了、什么跑完了——有没读的就亮红点。点一条直接跳到对应 tab；切到那个 tab，它的提醒会自己清掉。 终端程序也能自己发通知(OSC 9/777,`printf '\e]9;done\a'`):tab 不可见时弹横幅,无论如何都会进收件箱。终端响铃(`\a`)默认请求 Dock 注意;`bell-features` 可加系统提示音或自定义音频。

![跨窗口收集的通知中心](img/screenshot-3.png)

**Agent 面板。** 顶栏有个开关（三种折叠状态，跟左边栏一样）能拉出右侧边栏，把所有窗口里的 agent 一次性列出来，按谁最需要你排序：等你处理、失败、运行中、空闲。点任意一行直接跳到对应 tab；折叠模式会收成一条带状态色圆点的窄图标栏。

**会话历史。** 把 agent 面板翻到第二页（底部的时钟图标），大部分内置 agent（见上表）的历史对话按最近排序全在这里——在 kooky 外面开的也算。按标题或项目搜索、按 agent 过滤或只看当前工作区（仅本地工作区——SSH 工作区的会话在远端），点一行就接着聊：kooky 会在那个对话原来的目录里开一个新 tab，用 agent 自己的会话 ID 把上下文完整恢复回来。

![搜索并恢复任意一条 Claude Code / Codex 历史对话](img/screenshot-5.webp)

**会话信息。** 把 agent 面板翻到第三页（底部的 ⓘ 图标），当前 tab 的一切都在这里：workspace、目录、远程主机、git 分支 / 仓库 / diff、Python venv、Node 版本、代理，一棵实时进程树带着 CPU、内存和监听端口，还有上一条完成的命令连同退出码和耗时（zsh / fish），以及终端标题。而且不只是看：悬停字段一键复制完整值，点端口直接在浏览器打开，右键进程可以复制 PID 或结束它，本地会话里失败的命令还会冒出 **Ask AI** 按钮——命令、退出码、目录原样递给你的 agent 新开一个 tab。折叠状态重启也记得，内容随操作实时更新；命令行只存在内存里，绝不写盘。

**菜单栏 Agent 概览。** macOS 菜单栏里可以显示一个 Kooky 图标，只有存在 agent 时才带上实时数量。点开即可查看所有活跃 agent 的 tab 标题和项目路径，并直接跳转；菜单还提供 Open Kooky、Settings、Keep Awake 三档切换和 Quit。可在 Settings → General → `show-in-menu-bar` 中开关。

**在编辑器或终端里打开。** 顶栏一个分体按钮，把当前 tab 所在目录交给别的 app 打开。点图标用上次的 app 重新打开，点小箭头从你 Mac 上装了的所有支持 app 里选：VS Code · Cursor · Windsurf · Zed · Sublime Text · Antigravity · Trae · Kiro · Xcode · IntelliJ IDEA · PyCharm · WebStorm · Terminal · iTerm · Ghostty · Warp · Finder。可在 Settings → Open in 里排序或隐藏。

**工作区状态和环境一眼可见。** pane 底部状态栏显示 Git 仓库 + 分支 + diff（`N files +X −Y`）、Python venv、Node 版本、当前生效的代理（`https_proxy` / `http_proxy` / `all_proxy`），以及 SSH 到远程机器时登录的 `user@host`（在 Settings → General 里开启）。Agent 用 Bash 切分支也好,你在别的终端改了 git 状态也好,这里都会自动刷新。Node 版本和 Git 分支点一下就能切,仓库点开可以跳到 GitHub(GitLab / Bitbucket 也认)、复制仓库地址、或在 Finder 里打开,代理点开能看完整 `name=value` 并复制。

**SwiftUI 原生开发，简约风格。** Onest + JetBrains Mono 字体。自定义 About 面板、带快捷键提示的原生菜单,中日韩 IME 输入完整支持。

**Light + Dark 双主题。** Light 和 Dark 可以各选一套 terminal 配色，再单独选择 System / Light / Dark 外观模式。System 会实时跟随 macOS，同时切换 terminal 和整个窗口。40 多套内置配色包括 **Ghostty Dark**、Ayu、Catppuccin、Everforest、GitHub、Gruvbox、Material、Night Owl、Nord、Rosé Pine，以及 Codex Desktop 也在使用的其他开源主题；放在 `~/.config/ghostty/themes` 的自定义主题会按背景颜色自动出现在对应的 Light 或 Dark 下拉框。内置主题设置使用 `kooky:` 命名空间，因此升级后也不会覆盖同名的 Ghostty 自定义主题。老用户升级时仍保留原本的 Default 行为：如果以前没有选过主题，kooky 会继续继承 Ghostty 配置，直到你主动修改 Appearance。 终端里的程序询问「现在是暗色吗」(nvim 的 background 自动检测、delta)会得到你当前 kooky 主题的答案;继承的 Ghostty 配置里 `theme = light:X,dark:Y` 条件主题也能正确解析。

**可配置。** Settings 面板（`⌘,`）还可以调字体、光标、背景透明度（搭配 liquid-glass 或数字 `background-blur`,任何 macOS 版本都能拥有传统毛玻璃）、默认新 tab 行为、Terminal 预设、agents、Open in 和 pane 底部状态栏。开启 `confirm-close-surface` 后,关闭有进程在跑的 tab 会先确认。外观修改会立即同步到所有已打开的窗口。

**深层链接。** 其他应用可以在 kooky 里重新打开一个 agent 会话：`kooky://resume?agent=<agent>&id=<会话id>[&cwd=<路径>]` 在会话已打开时直接跳到对应 tab，否则在会话自己的项目目录里新开一个 tab 恢复（`agent` 与 History 面板使用同一套 id：`claude-code`、`codex`、`copilot`、`cursor`、`opencode`、`kiro`、`gemini` 等）。可选的 `cwd` 让链接也能恢复超出会话扫描保留范围的更早会话。会话 id 严格校验，链接无法携带 prompt 或命令；被拒绝的链接会用弹窗说明原因。`cwd` 里的空格必须编码为 `%20`（`+` 不会被解码）。

**默认本地。** 不需要账号，不做遥测，没有云同步。kooky 的状态都留在本机。

**基于 libghostty。** 使用和 ghostty 同源的 GPU 终端渲染引擎，渲染跟随屏幕刷新率，在 120Hz / ProMotion 屏上滚动顺滑、不撕裂。

## CLI

`kooky-cli` 让脚本和其他本地应用驱动正在运行的 kooky——开 tab 跑命令、恢复 agent 会话、查询 / 聚焦 / 关闭 tab：

```sh
kooky-cli open --cwd ~/Github/vibex -e "npx @deepseek-ai/dsh web"   # 新 tab：cd 过去并执行命令
kooky-cli open --cwd ~/Github/vibex --agent claude-code             # 新 tab 里启动一个 agent 模板
kooky-cli open --agent claude-code                                  # 不给 --cwd：开在当前 workspace 所在目录
kooky-cli open --agent preset-1                                     # Terminal 预设自带目录，可以不给 --cwd
kooky-cli open -e "npm run dev" --title "dev server" --no-focus     # 命名 tab 并后台打开
kooky-cli resume --agent codex --id <会话id>                        # 与 kooky://resume 深层链接同语义
kooky-cli list --json                                               # 窗口 → workspace → tab 树，带 id
kooky-cli focus --tab <session-uuid>                                # 把某个 tab 带到最前
kooky-cli close --tab <session-uuid>                                # 遵循应用内的关闭确认规则
kooky-cli rename --tab <session-uuid> --title <标题>                # 设置 tab 标题
kooky-cli status                                                    # 版本与健康状态；未运行时退出码 1
```

除 `status` 外，每个命令都会在 kooky 未运行时先把它拉起。退出码 0 表示请求已受理；任何失败都在 stderr 打印一行原因。`--agent` 接受与 Settings → Agents 相同的模板 id（内置、自定义和 Terminal 预设）。`--cwd` 是可选的：不给时 tab 开在当前 workspace 所在目录，Terminal 预设则用它自带的固定目录——两种情况都可以传 `--cwd` 覆盖。`--title` 的优先级高于自动标题，效果与手动重命名 tab 完全一致；`--no-focus` 后台打开：kooky 不会被带到前台（包括由 CLI 拉起 kooky 的场景），你正在看的内容也不会被切走——tab 已经在后台跑起来了，想看的时候用 `focus` 把它带到前面。

二进制随 app 打包在 `Kooky.app/Contents/MacOS/kooky-cli`，kooky 每次启动还会把它刷新到稳定路径 `~/Library/Application Support/kooky/bin/kooky-cli` —— 外部工具建议指向后者：这个路径跨版本更新不变，而且 macOS Gatekeeper 会杀掉从 `/Applications` 内部 exec 的未公证辅助二进制，Application Support 的拷贝不受影响。想加进 PATH？做个 symlink：

```sh
ln -s ~/Library/Application\ Support/kooky/bin/kooky-cli /usr/local/bin/kooky-cli
```

命令只经由 kooky 本地的、仅属主可访问的 socket 传递——`kooky://` URL 仍然无法携带命令。

## 安装

从 [Releases](https://github.com/iAmCorey/kooky/releases) 下载最新的 `.dmg`，打开后把 `Kooky.app` 拖进 `Applications` 文件夹。

**第一次启动会被 Gatekeeper 拦下来**，因为当前构建是 adhoc 签名（还没有 Apple Developer ID；公开分发签名和公证会等有真实用户后再做）。你会看到 *"Kooky cannot be opened because Apple cannot check it for malicious software"* 或者 *"is damaged and cannot be opened"* 这两类报错。下面三种方法任选一个即可：

<details>
<summary><b>方法 A —— 走系统设置 <i>(推荐)</i></b></summary>

1. 先双击一次 `Kooky.app`，macOS 会弹警告，把警告窗口关掉。
2. 打开 **系统设置 → 隐私与安全性**，往下翻到 **安全性** 这一段。
3. 看到 *"Kooky was blocked to protect your Mac"* 后，点旁边的 **Open Anyway**，输入密码。
4. 再双击一次 `Kooky.app`，这次会有 **Open** 按钮，点它即可。
</details>

<details>
<summary><b>方法 B —— 终端一行命令</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Kooky.app
```
</details>

<details>
<summary><b>方法 C —— 连 "Open Anyway" 按钮都没有</b></summary>

新版 Sequoia 有时会对 adhoc 签名的 app 完全不显示 "Open Anyway" 按钮。这种情况下可以先把旧版的 "Anywhere" 选项打开，再回去走方法 A：

```sh
sudo spctl --global-disable      # macOS 15+；老系统用 --master-disable
# 系统设置 → 隐私与安全性 → "Allow applications from" 选 Anywhere
# 双击 Kooky.app，这次应该可以启动
sudo spctl --global-enable       # Kooky 跑过一次之后，立刻把 Gatekeeper 打开
```

注意：这是**系统级开关**。关着的时候，macOS 会允许任何未签名 app 启动。Kooky 跑过一次就把它重新打开；系统会单独记住已经信任过 Kooky，以后不会再拦。
</details>

macOS **只拦第一次启动**。之后从 Spotlight、Dock、Finder 启动都跟普通 app 一样。

## 从源码构建

需要 Xcode 26+ 和 macOS 14+（Sonoma，`@Observable` 的最低系统要求）。

```sh
./scripts/setup-libghostty.sh        # 一次性：把预编译的 libghostty xcframework 下到 Vendor/
swift build
swift run                            # 开发模式直接跑
swift test                           # 1000+ 个单测
./scripts/bench.sh                   # 性能基准（release 构建，结果记录在 bench-history.jsonl）

./scripts/build-app.sh               # 产出 dist/Kooky.app
./scripts/build-dmg.sh --build       # 产出 dist/Kooky-vX.Y.Z.dmg
```

`Vendor/` 和 `dist/` 都在 `.gitignore` 里。libghostty 的 setup 脚本可以反复跑；SHA 没变时会直接跳过。

## Star 趋势

[![Star History Chart](https://api.star-history.com/chart?repos=iAmCorey/kooky&type=date&legend=top-left&sealed_token=ZX5h8laOXIE38b__FRNpP7ae52yRupThIRrcgidF7RI0OOzVcsKIo1iJ_iDp6UcMoxzNCL99N3RY__N7TFUszIgxzljBSBRRiAPYPt9QC9lKf7X3ShAQJg)](https://www.star-history.com/?type=date&repos=iAmCorey%2Fkooky)

## 许可证

MIT —— 见 [LICENSE](LICENSE)。打包进来的第三方资源保留各自的许可证，详见 [NOTICE.md](NOTICE.md)。
