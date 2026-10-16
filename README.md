# Tidytalk

Tidytalk 是一款 macOS 上的段落式语音输入工具。按住 Option + Command 说一段话，松开后自动识别，去掉"嗯、那个、就是说"这类口语化表达，把整理好的文字粘贴到当前光标位置。

> 项目状态：首个版本已实现，待真机完整验证。

## 它是什么，不是什么

它是**段落式**的：说完一整段，松开按键，一次性输出整理好的文字。适合写消息、写文档、记想法这类"想清楚再说"的场景。

它**不是**实时逐字输入法，不会边说边往输入框里打字，也不替代系统输入法。说话时指示器下方会实时显示识别到的文字，方便确认自己说了什么，但这只是预览，最终结果在松开后整段识别、整理再粘贴。

## 使用方式

1. 在任意输入框里放好光标。
2. 同时按住 Option 和 Command，开始说话。屏幕底部会出现一个玻璃质感的指示器，显示音量。
3. 说完松开按键。
4. 稍等片刻，整理后的文字会自动出现在光标位置。

一些细节：

- 按住超过约 0.4 秒才开始录音，日常按快捷键（例如 Option + Command + 某个键）不会误触发。
- 按住期间按下其他键、其他修饰键，或者点击鼠标，会取消本次录音。
- 已经按着 Shift、Control 或 Fn 时再按，不会触发。
- 单次录音最长约 2 分钟；不足 0.5 秒的录音会被忽略。
- 触发键可以在"设置 › 录音 › 快捷键"里换成 Control、Option、Command、Fn（🌐）、右侧 Option 或右侧 Command，以免和其他软件冲突。选 Fn 时，需要在"系统设置 › 键盘"里把"按下 🌐 键时"设为"无操作"。
- 麦克风默认跟随系统，也可以指定外接耳机、会议麦克风等；指定的设备未连接时自动使用系统默认麦克风。
- 开始、结束录音时会轻响一声提示音，可以在设置里关闭。
- 当前没有可以输入的地方时（例如焦点在桌面、网页正文、列表上），不会模拟粘贴，而是把结果放进剪贴板，并提示"没有输入框，已复制到剪贴板"，之后可以自己粘贴到想要的地方。无法判断焦点的应用会照常粘贴。
- 按住期间按 Esc 也会取消录音。
- 说话时，胶囊下方会用较小的灰色文字实时显示识别到的内容：放得下时居中显示，说得多了最新的文字在右边，前面的文字向左流出并淡出。预览在本机完成，每 0.6 秒刷新一次；可以在设置里关闭。

### 免按住录音

快速双击触发键，开始录音后可以松开手，适合说较长的内容；再按一次触发键结束，按 Esc 取消。录音期间打字、点击鼠标不会打断录音。可以在设置里关闭。

### 语音改写选中的文字

先选中一段已有的文字，按住改写键（默认右侧 Option，可在设置里更换或关闭）说出修改要求，例如"改得正式一点""缩短到一句话""翻译成英文"，松开后选中的文字会被替换成改写结果。改写时指示器上显示"改写"，胶囊周围有彩色光点环绕飘散。

- 需要配置 AI 接口；选中的文字和修改要求会发送给 AI。
- 优先通过辅助功能直接读取选中的文字；读不到时（例如部分网页和 Electron 应用）会模拟一次 Cmd+C，读完立即恢复剪贴板。
- 没有选中文字时提示"请先选中要改写的文字"；改写失败时原文不会改动。

### 快捷短语

在"设置 › 词库"里添加快捷短语，例如"我的邮箱" → 完整的邮箱地址。整句话只说这个短语时，直接输出设置好的内容，不经过 AI 整理；句子中间提到这个短语不会被替换。

### 开机自动启动

在"设置 › 通用 › 启动与更新"里打开，使用系统的登录项。系统要求确认时，按提示到"系统设置 › 通用 › 登录项"里允许。

### 最近记录

最近 20 次的结果会记在内存里，可以在菜单栏图标的"最近记录"里重新粘贴、拷贝，或者拷贝未经整理的识别原文，适合误粘贴或想再用一次的时候。说完发现模式选错了，可以用"重新整理"换成其他整理模式或翻译成其他语言，结果直接粘贴到当前的输入框，不用再说一遍（需要配置 AI 接口）。识别错的词可以直接用"加入词库…"加进替换表和常用词。记录不写入磁盘，退出应用即清空；也可以在设置里关闭或随时清空。

## 整理效果

整理只做删减和修正，不改变你说的内容：

- 删除没有实际含义的填充词，例如：嗯、呃、那个、就是说、um、uh、like。
- 删除重复的词句和口误；中途改口时，只保留改口后的说法。
- 补全标点，必要时断句。
- 不总结、不补充，保持原文的语气；句中的英文单词和术语原样保留。默认不翻译，保持原文的语言；需要时可以设置输出语言（见下文）。
- 即使你说的话听起来像指令（比如"帮我写一封邮件"），也只会被整理成文字，不会被执行。

示例：

| 你说的 | 输出 |
| --- | --- |
| 嗯那个我想问一下就是这个 API 的那个 rate limit 呃是多少 | 我想问一下这个 API 的 rate limit 是多少？ |
| 项目要延期到下周三，不对，是下周四 | 项目要延期到下周四。 |

整理功能可以在设置里关闭，关闭后直接输出识别原文。

### 个人词库

在"设置 › 词库"里添加常用的人名、产品名、专业术语，这些词最容易识别错。SenseVoice 本身不支持热词，所以分两步纠正：

- **常用词**：放进 AI 整理的提示里，让模型把读音相近的错误识别改成正确写法，例如"森斯沃伊斯"改为"SenseVoice"。读音不像或拿不准的地方保持原文。需要开启 AI 整理。
- **固定替换**：识别结果里出现某个词时总是替换成指定写法，例如"克劳德"总是替换成"Claude"。英文不区分大小写、只匹配完整单词。在本机处理，关闭 AI 整理时也生效。

### 自定义规则

在"设置 › 词库 › 自定义规则"里每行写一条自己的写法要求，例如"金额一律用阿拉伯数字""称呼对方统一用'您'""产品名写作 Tidytalk"。AI 整理和语音改写时都会遵守；规则只影响写法，不会让 AI 补充原文没有的内容。最多 20 条。

### 本机大模型（完全离线）

AI 整理使用 OpenAI 兼容协议，也可以接本机运行的模型服务，文字不会离开电脑：

1. 安装 [Ollama](https://ollama.com) 并下载一个模型，例如 `ollama pull qwen2.5:7b`；或者在 LM Studio 里下载并加载一个模型，打开本地服务。
2. 在"设置 › 配置 AI"里点"预设"，选"Ollama（本机）"或"LM Studio（本机）"，确认模型名后保存。本机模型不需要 API Key，超时默认放宽到 60 秒。
3. 点"测试连接"确认可用。

本机模型的整理效果取决于模型大小，小模型对"只整理、不回答"和自定义规则的遵守可能不如云端模型稳定，建议用 7B 左右或更大的模型。

### 整理强度

| 强度 | 效果 |
| --- | --- |
| 轻度 | 只补全标点、删除"嗯、呃"这类语气词，其余原话保留 |
| 标准 | 删除填充词和口误，补全标点（默认） |
| 深度 | 在标准基础上进一步精简啰嗦、重复的表达，但不改变原意 |

### 整理模式

在"设置 › 配置 AI › 整理方式"里切换整理模式，对之后所有的整理生效：

| 模式 | 效果 |
| --- | --- |
| 标准 | 删除填充词、修正口误、补全标点，保持原意（默认） |
| 聊天（口语） | 保持口语化的语气，句末语气词保留 |
| 邮件（书面） | 使用书面表达，句子完整 |
| 代码（保留术语） | 严格保留术语、命令、文件名和符号，不转换标点 |

模式只影响 AI 整理，需要开启整理功能。整理只做删减和修正，所以不同模式之间的差别主要体现在语气词、标点和个别用词上，不会改写内容。

### 输出语言

默认"与原文相同"。选择其他语言后，说中文或英文，整理后直接输出译文，例如说中文、粘贴出英文邮件。支持 English、简体中文、繁體中文、日本語、한국어、Français、Deutsch、Español。

- 可以在"设置 › 配置 AI › 整理方式"里修改，也可以在菜单栏图标的"输出语言"子菜单里快速切换。
- 翻译和整理在同一次请求里完成，速度和只整理差不多。个人词库和整理模式同样生效，例如用"邮件（书面）"模式翻译成英文。
- 翻译依赖 AI 整理：关闭整理、网络失败或结果异常时，粘贴识别原文并提示"翻译失败，已粘贴原文"。
- 说的内容即使是问题或指令，也只会被翻译，不会被回答。

### 中英文排版规范

在本机自动处理，不需要联网：中文与英文、数字之间加空格；中文后面的标点统一为全角；全角字母和数字转为半角；全角标点两侧不留空格。数字里的小数点、文件名、网址等不受影响。可以在设置里关闭。

## 支持的语言

说话时不需要选择语言，识别会自动判断：

- 中文普通话，包括句中夹杂英文单词和技术术语（如 demo、API、SDK）
- 英文
- 日文
- 韩文
- 粤语（识别结果用简体字，保留粤语的说法，例如"听日""带埋"）

不支持其他语言（例如法语、德语、西班牙语）和其他方言。需要输出其他语言时，可以用中文或英文说，再通过"输出语言"翻译。

## 界面语言

界面支持简体中文和英文，跟随系统设置的语言：系统首选语言是中文时显示中文，其他语言显示英文。语言名称（English、日本語……）在任何界面语言下都保持原样。

AI 整理的提示词固定为中文，对说英文、日文等的内容同样有效，不随界面语言变化。

## 隐私

- **音频不会离开你的电脑。** 语音识别完全在本地完成。
- **识别出的文字会发送给你配置的 AI 接口进行整理**（OpenAI 兼容协议，默认 DeepSeek）。改用本机模型（Ollama、LM Studio）时，文字不会离开你的电脑。如果你不希望文字上传，可以在设置里关闭整理功能，此时应用完全离线工作。
- 接口地址、API Key 和模型保存在用户目录下的隐藏文件 `~/.tidytalk.json` 中，文件权限为仅本人可读写（600）。
- 最近的结果只保存在内存中，不写入磁盘，退出应用即清空；可以在设置里关闭。

## 配置文件

设置窗口里的内容都保存在 `~/.tidytalk.json`，也可以直接用文本编辑器修改，下次整理时自动生效：

```json
{
  "cleanup_enabled": true,
  "ai": {
    "base_url": "https://api.deepseek.com/v1",
    "api_key": "sk-...",
    "model": "deepseek-chat",
    "temperature": 0,
    "timeout": 12
  },
  "typography": true,
  "vocabulary": ["Claude", "SenseVoice"],
  "replacements": { "克劳德": "Claude" },
  "style": "standard",
  "output_language": "original",
  "hotkey": "option_command",
  "microphone": "",
  "history": true,
  "hands_free": true,
  "rewrite_hotkey": "right_option",
  "sounds": true,
  "cleanup_level": "standard",
  "snippets": { "我的邮箱": "name@example.com" },
  "custom_rules": ["金额一律用阿拉伯数字"],
  "live_preview": true,
  "auto_update_check": true
}
```

| 字段 | 说明 |
| --- | --- |
| `cleanup_enabled` | 是否整理文字，关闭后直接粘贴识别原文 |
| `ai.base_url` | OpenAI 兼容接口地址，请求发往 `{base_url}/chat/completions`，例如 `https://api.openai.com/v1` |
| `ai.api_key` | API Key；接口在本机（localhost）时可以留空 |
| `ai.model` | 模型名，建议使用非推理模型，响应更快 |
| `ai.temperature` | 设为 `null` 则不发送，适用于不允许修改该参数的模型 |
| `ai.timeout` | 请求超时（秒），超时后粘贴识别原文 |
| `typography` | 中英文排版规范 |
| `vocabulary` | 个人词库的常用词 |
| `replacements` | 固定替换表，错误写法 → 正确写法 |
| `style` | 整理模式：`standard`、`casual`、`formal` 或 `code` |
| `output_language` | 输出语言：`original`（与原文相同）、`en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`fr`、`de`、`es` |
| `hotkey` | 按住说话的触发键：`option_command`（默认，同时按住 Option 和 Command）、`control`、`option`、`command`、`fn`、`right_option`、`right_command` |
| `microphone` | 麦克风的设备 UID，空字符串表示跟随系统默认 |
| `history` | 是否在内存中记住最近的结果 |
| `hands_free` | 双击触发键免按住录音 |
| `rewrite_hotkey` | 语音改写的触发键，取值同 `hotkey`，`off` 表示关闭；不能和 `hotkey` 相同 |
| `sounds` | 开始、结束录音时的提示音 |
| `cleanup_level` | 整理强度：`light`、`standard` 或 `thorough` |
| `snippets` | 快捷短语：说出的短语 → 输出的内容 |
| `custom_rules` | 自定义整理规则，每条一句 |
| `live_preview` | 说话时在指示器下方显示实时文字（只是预览） |
| `auto_update_check` | 启动时自动检查更新（构建时配置了更新地址才生效） |

## 系统要求

- macOS 26 或更高版本
- 一个 OpenAI 兼容接口的 API Key，例如 DeepSeek、OpenAI（使用整理功能时需要）
- 首次启动时需要联网下载语音识别模型（约几百 MB），之后识别无需联网

## 首次启动

首次打开应用会进入引导流程，依次完成：

1. **授权麦克风**：用于录音。
2. **授权辅助功能**：用于监听触发键（默认 Option + Command）和把文字粘贴到光标处。
3. **配置 AI**：填写接口地址、API Key 和模型（默认 DeepSeek），可以点击"测试连接"确认可用。
4. **下载语音识别模型**：显示下载进度，失败可以重试，支持断点续传。

模型下载完成前，应用会明确提示尚未就绪。

## 出错时会怎样

| 情况 | 应用的处理 |
| --- | --- |
| 网络不可用、AI 接口超时或报错 | 直接粘贴识别原文，并提示"整理失败，已粘贴原文" |
| 整理结果明显异常（比原文长很多或短很多） | 视为整理失败，粘贴识别原文 |
| 没有识别到内容 | 提示"没有听到内容"，不粘贴 |
| 缺少权限 | 提示需要授权的项目 |

## 卸载

把 Tidytalk 拖进废纸篓只会删除应用本身，语音识别模型、配置文件和授权记录都会留在电脑上，需要手动清理：

1. 如果开启了开机自动启动，先在"设置 › 通用"里关掉，然后在菜单栏图标里选"退出 Tidytalk"。
2. 把"应用程序"文件夹里的 Tidytalk 拖进废纸篓。
3. 在"终端"里执行下面几行，删除留在电脑上的数据：

   ```bash
   rm -rf ~/Library/Application\ Support/Tidytalk
   rm -f ~/.tidytalk.json
   defaults delete app.tidytalk.Tidytalk
   tccutil reset All app.tidytalk.Tidytalk
   ```

会删除的内容：

| 位置 | 内容 |
|---|---|
| `~/Library/Application Support/Tidytalk/` | 语音识别模型，约 230 MB |
| `~/.tidytalk.json` | 设置、AI 接口地址和 API Key、词库、快捷短语、自定义规则 |
| `~/Library/Preferences/app.tidytalk.Tidytalk.plist` | 系统保存的窗口位置等偏好，用 `defaults delete` 删除 |
| 系统设置里的麦克风、辅助功能授权 | 用 `tccutil reset` 清除，也可以在"系统设置 › 隐私与安全性"的"麦克风"和"辅助功能"里选中 Tidytalk，点"−"移除 |

打算以后重装、想保留设置和词库的话，可以不删 `~/.tidytalk.json`。这个文件里有 API Key，电脑给别人用之前建议删掉。它是隐藏文件，在访达里按 Command + Shift + 句号可以显示。

最近记录只保存在内存里，退出应用就清空了，不需要额外删除。

## 工作原理

```
按住 Option + Command
   ↓
录音（本地）
   ↓
松开按键
   ↓
SenseVoice 语音识别（本地）
   ↓
固定替换（本地）
   ↓
AI 文本整理（OpenAI 兼容接口，云端，可关闭；带上词库、整理模式和输出语言）
   ↓
中英文排版规范（本地，可关闭）
   ↓
写入剪贴板 → 模拟 Cmd+V 粘贴 → 恢复原剪贴板内容
```

几个关键设计：

- **指示器永远不抢焦点。** 指示器使用不激活的浮动面板实现，不会成为焦点窗口，保证文字粘贴到你原来的输入框里。它只显示状态，不能点击或拖动。
- **不破坏剪贴板。** 粘贴完成后会把剪贴板恢复成原来的内容，文字、图片、文件、富文本都会完整恢复（单次超过 64 MB 时只恢复文字）。
- **整理结果有兜底校验。** 整理只会删减，如果结果长度异常，说明模型可能在"回答"而不是整理，此时改用原文。

## 界面

- **指示器**：屏幕底部居中的 Liquid Glass 胶囊面板。录音时显示随音量跳动的电平，处理中显示流动动画，出错时显示一行提示。电平旁显示当前的处理方式：只转文字时不显示；开启 AI 整理时显示"整理"；翻译时显示"译成英文""译成日文"这类文案；语音改写时显示"改写"。
- **菜单栏图标**：录音时切换状态，即使没注意指示器也能知道正在录音。应用不在 Dock 中显示。
- **设置窗口**：顶部工具栏分为五页，切换时窗口高度随内容伸缩：通用（启动与更新、中英文排版、历史记录）、录音（快捷键、麦克风、实时文字、提示音、语音识别模型）、配置 AI（接口、整理强度与模式、输出语言）、词库（常用词、固定替换、快捷短语、自定义规则）、权限（麦克风与辅助功能授权、隐私说明）。

## 技术栈

| 部分 | 选型 |
| --- | --- |
| 界面 | Swift + SwiftUI，Liquid Glass |
| 语音识别 | SenseVoice-Small（通过 sherpa-onnx 本地运行） |
| 文本整理 | OpenAI 兼容的 Chat Completions 接口，默认 DeepSeek（`deepseek-chat`，非推理模式） |
| 全局按键监听 | 系统事件监听（需辅助功能权限） |
| 文字输入 | 剪贴板 + 模拟 Cmd+V |
| 配置存储 | `~/.tidytalk.json` |

## 分发

通过 DMG 安装包分发，使用 Apple Developer ID 签名并完成公证。

检查更新：构建时用 `UPDATE_URL` 指定一个 JSON 地址（例如 `UPDATE_URL=https://example.com/tidytalk.json scripts/make-dmg.sh`），应用会在启动时（每天最多一次）和菜单"检查更新…"里读取它，发现新版本时提示并打开下载地址。JSON 格式：

```json
{ "version": "0.2.0", "url": "https://example.com/Tidytalk-0.2.0.dmg", "notes": "更新内容" }
```

没有指定地址时，应用里不显示检查更新。

不上架 Mac App Store：App Store 要求应用运行在沙盒中，而沙盒环境下无法实现全局按键监听和模拟粘贴。

## 首个版本的范围

**包含：**

- 按住 Option + Command 录音，松开结束
- 本地 SenseVoice 识别（中文、英文、中英混合、日文、韩文、粤语，自动判断语言）
- AI 整理（OpenAI 兼容接口），可开关
- 剪贴板粘贴并恢复原内容（包括图片和文件）
- 自定义触发键
- 选择麦克风
- 最近记录（仅内存）
- 玻璃风格指示器和菜单栏图标
- 首次启动引导（权限、API Key、模型下载）
- 网络失败和整理异常时回退到原文
- 个人词库（常用词 + 固定替换）
- 整理模式切换（标准、聊天、书面、代码）
- 输出语言（说中文或英文，输出译文）
- 中英文排版规范
- 免按住录音、语音改写选中文字、快捷短语
- 整理强度分档、提示音、指示器处理方式标签
- 开机自动启动、检查更新

**暂不包含：**

- 指示器拖动

**不做：**

- Windows 版本
- 实时逐字输出到输入框（说话时只在指示器里预览）
- 系统原生输入法
- 粤语以外的其他方言

## 待定事项

- **模型下载源**：GitHub 在部分地区访问不稳定，需要决定是否同时提供 ModelScope、Hugging Face 等镜像。

## 后续可能的方向

- 实测 macOS 26 自带的本地语音识别（SpeechAnalyzer）和本地大模型（Foundation Models）对中文的效果，评估能否作为免下载、免 API Key 的备选方案。
- 在识别阶段使用热词（需要换用支持热词引导的识别模型），进一步提升人名、产品名的识别准确率。

## 开发

项目使用 Swift Package Manager 构建，只需要 Command Line Tools（Swift 6.2+，macOS 26 SDK）即可编译，也可以直接用 Xcode 打开 `Package.swift`。

```bash
scripts/fetch-deps.sh      # 下载 sherpa-onnx 预编译动态库和头文件到 Vendor/
swift test                 # 运行单元测试
scripts/install.sh         # 编译、安装到 /Applications 并启动（之后可在启动台、Spotlight 中找到）
```

`scripts/build-app.sh` 只编译并组装 `build/Tidytalk.app`，不安装。`scripts/make-icon.sh` 重新生成应用图标。

应用平时只在菜单栏显示图标；打开引导或设置窗口时会临时出现在 Dock 中，关闭窗口后隐藏。应用在运行时再次从启动台或 Spotlight 打开它，会弹出设置窗口。

发布版本（Developer ID 签名 + 公证）：

```bash
xcrun notarytool store-credentials tidytalk-notary   # 只需执行一次
SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
NOTARY_PROFILE=tidytalk-notary VERSION=0.1.0 scripts/make-dmg.sh
```

开发调试用的命令行入口（不启动界面）：

```bash
.build/debug/Tidytalk --transcribe 录音.wav            # 用已下载的模型识别音频文件
.build/debug/Tidytalk --transcribe 录音.wav --cleanup  # 再按 ~/.tidytalk.json 的配置调用 AI 整理
.build/debug/Tidytalk --cleanup-text "要整理的文字" --style casual --vocab Claude,demo --lang en  # 只测试整理，临时指定模式、词库和输出语言
.build/debug/Tidytalk --snapshot 输出目录               # 把引导、设置、指示器渲染成 PNG
.build/debug/Tidytalk --list-mics                      # 列出麦克风及其 UID
.build/debug/Tidytalk --clipboard-test                 # 在测试剪贴板上验证保存与恢复
.build/debug/Tidytalk --rewrite-text "选中的文字" --instruction "改得正式一点"  # 测试语音改写
.build/debug/Tidytalk --update-feed https://example.com/tidytalk.json --current 0.1.0  # 测试更新信息
```

界面文字的国际化：

- 源代码里的简体中文就是翻译的键。SwiftUI 控件（`Text("…")`、`Button("…")` 等）会自动查找翻译，其他地方（菜单、提示、错误信息）用 `String(localized: "…")`。不需要翻译的技术名词用 `Text(verbatim:)`。
- 英文翻译在 `Resources/en.lproj/Localizable.strings`；`Resources/zh-Hans.lproj/` 只用来声明支持简体中文，不需要逐条填写。
- 新增或修改界面文字后运行下面的命令，它会列出缺少英文翻译和已经不用的条目：

```bash
scripts/localization.py
```

- 在英文界面下检查未翻译的文字（未翻译的会显示成全大写）：

```bash
/Applications/Tidytalk.app/Contents/MacOS/Tidytalk --snapshot 输出目录 -AppleLanguages "(en)" -NSShowNonLocalizedStrings YES
/Applications/Tidytalk.app/Contents/MacOS/Tidytalk --menu-dump -AppleLanguages "(en)" -NSShowNonLocalizedStrings YES
```

代码结构：

| 目录 | 内容 |
| --- | --- |
| `Sources/TidytalkCore` | 与系统无关的纯逻辑：按键状态机、整理提示词与结果校验、词库与替换、整理模式、中英文排版、长音频切分、配置与模型清单 |
| `Sources/Tidytalk/Services` | 本地识别（sherpa-onnx）、录音、全局按键监听、粘贴、AI 接口、配置文件、模型下载 |
| `Sources/Tidytalk/App` | 应用入口、全局状态、录音到粘贴的主流程 |
| `Sources/Tidytalk/UI` | 指示器、菜单栏图标、首次启动引导、设置窗口 |
| `Sources/CSherpaOnnx` | sherpa-onnx C API 的模块映射 |

说明：

- 模型下载源目前依次尝试 Hugging Face 和 hf-mirror.com，失败自动切换，支持断点续传，下载完成后校验 SHA-256。模型保存在 `~/Library/Application Support/Tidytalk/Models/`。
- 本地临时签名的构建把签名身份固定为 bundle id（`app.tidytalk.Tidytalk`），重新编译后辅助功能权限仍然有效。如果系统设置里打开了开关、应用却仍显示未授权，说明列表里是更早签名方式的旧条目，执行 `tccutil reset Accessibility app.tidytalk.Tidytalk` 后重新授权即可。
