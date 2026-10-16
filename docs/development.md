# 开发

## 工作原理

```
按住快捷键
   ↓
录音（本机）
   ↓
松开按键
   ↓
SenseVoice 语音识别（本机，sherpa-onnx）
   ↓
固定替换、快捷短语（本机）
   ↓
AI 文本整理（OpenAI 兼容接口，可关闭；带上词库、整理模式、自定义规则和输出语言）
   ↓
中英文排版规范（本机，可关闭）
   ↓
写入剪贴板 → 模拟 Cmd+V 粘贴 → 恢复原剪贴板内容
```

几个关键设计：

- **指示器不抢焦点。** 指示器是不激活的浮动面板，不会成为焦点窗口，保证文字粘贴到原来的输入框里。它只显示状态，不能点击或拖动。
- **按键监听只听不拦。** 全局按键用 listen-only 的 CGEventTap 监听，系统不会等它处理完才把按键交给其他应用；辅助功能权限被收回时自动停止监听。
- **不破坏剪贴板。** 粘贴完成后把剪贴板恢复成原来的内容，文字、图片、文件、富文本都会完整恢复（单次超过 64 MB 时只恢复文字）。
- **整理结果有兜底校验。** 整理只会删减，如果结果长度异常，说明模型可能在"回答"而不是整理，此时改用原文。
- **不上架 Mac App Store。** App Store 要求应用运行在沙盒中，而沙盒里无法实现全局按键监听和模拟粘贴。

## 技术栈

| 部分 | 选型 |
| --- | --- |
| 界面 | Swift 6 + SwiftUI，Liquid Glass（`NSGlassEffectView`） |
| 语音识别 | SenseVoice-Small int8，通过 sherpa-onnx C API 在本机运行 |
| 文本整理 | OpenAI 兼容的 Chat Completions 接口，默认 DeepSeek（`deepseek-chat`） |
| 全局按键 | CGEventTap（需要辅助功能权限） |
| 文字输入 | 剪贴板 + 模拟 Cmd+V |
| 配置 | `~/.tidytalk.json`，见[配置文件](configuration.md) |

## 编译

需要 macOS 26 和 Swift 6.2 以上（macOS 26 SDK）。只装 Command Line Tools 就能编译，也可以用 Xcode 打开 `Package.swift`。

```bash
scripts/fetch-deps.sh   # 下载 sherpa-onnx 预编译动态库和头文件到 Vendor/
swift test              # 运行单元测试
scripts/install.sh      # 编译、安装到 /Applications 并启动
```

`scripts/build-app.sh` 只编译并组装 `build/Tidytalk.app`，不安装。`scripts/make-icon.sh` 重新生成应用图标。

构建脚本的环境变量：

| 变量 | 说明 |
| --- | --- |
| `VERSION` | 版本号，默认 `0.1.0` |
| `BUILD_NUMBER` | 构建号，默认当前时间 |
| `UPDATE_URL` | 检查更新地址，默认读取本仓库 GitHub Releases 的最新版本；设为空字符串则隐藏检查更新 |
| `DEV_TOOLS` | 设为 `1` 时编入下文的开发命令；发给用户的版本不要设置 |
| `SIGN_IDENTITY` | 签名身份，例如 `Developer ID Application: 名字 (TEAMID)`；不设置时使用本地临时签名 |
| `NOTARY_PROFILE` | 仅 `make-dmg.sh`：`xcrun notarytool store-credentials` 保存的钥匙串配置名 |

本地临时签名会把签名身份固定为 bundle id（`app.tidytalk.Tidytalk`），重新编译后辅助功能权限仍然有效。

应用平时只在菜单栏显示图标；打开引导或设置窗口时会临时出现在 Dock 中，关闭窗口后隐藏。应用运行时再次从启动台或 Spotlight 打开它，会弹出设置窗口。

## 发布

```bash
# 未公证的试用版（DMG 里会附上首次打开的说明）
VERSION=0.2.0 scripts/make-dmg.sh

# Developer ID 签名并公证
xcrun notarytool store-credentials tidytalk-notary   # 只需执行一次
SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
NOTARY_PROFILE=tidytalk-notary VERSION=0.2.0 scripts/make-dmg.sh
```

生成的安装包在 `build/Tidytalk-<版本号>.dmg`。在 GitHub 上新建 Release，标签写 `v0.2.0`，上传 DMG，发布说明会显示在应用的更新提示里。

应用启动时（每天最多一次）和菜单"检查更新…"会读取 `UPDATE_URL`。默认是 GitHub 的 `releases/latest` 接口，取标签里的版本号，发现新版本时打开 Release 页面；还没有发布任何版本时视为已是最新。也可以指向自建的 JSON：

```json
{ "version": "0.2.0", "url": "https://example.com/Tidytalk-0.2.0.dmg", "notes": "更新内容" }
```

## 开发命令

调试构建（`swift build`）或用 `DEV_TOOLS=1` 打包的应用里有一组不启动界面的命令，正式版里没有：

```bash
.build/debug/Tidytalk --transcribe 录音.wav            # 用已下载的模型识别音频文件
.build/debug/Tidytalk --transcribe 录音.wav --cleanup  # 再按 ~/.tidytalk.json 的配置调用 AI 整理
.build/debug/Tidytalk --cleanup-text "要整理的文字" --style casual --vocab Claude,demo --lang en
.build/debug/Tidytalk --rewrite-text "选中的文字" --instruction "改得正式一点"
.build/debug/Tidytalk --snapshot 输出目录               # 把引导、设置、指示器渲染成 PNG
.build/debug/Tidytalk --list-mics                      # 列出麦克风及其 UID
.build/debug/Tidytalk --clipboard-test                 # 在测试剪贴板上验证保存与恢复
.build/debug/Tidytalk --update-feed https://api.github.com/repos/byteyu2436/tidytalk/releases/latest --current 0.1.0
```

和权限有关的命令要通过 `open` 运行已安装的应用。直接在终端里执行二进制时，系统会把权限算在终端头上，结果不准：

```bash
DEV_TOOLS=1 scripts/install.sh
open -n /Applications/Tidytalk.app --args --check-permissions /tmp/permissions.txt
open -n /Applications/Tidytalk.app --args --settings-capture /tmp/settings     # 截取设置窗口每一页
open -n /Applications/Tidytalk.app --args --onboarding-capture /tmp/onboarding # 截取引导的每一步
```

## 国际化

- 源代码里的简体中文就是翻译的键。SwiftUI 控件（`Text("…")`、`Button("…")` 等）会自动查找翻译，其他地方（菜单、提示、错误信息）用 `String(localized: "…")`。不需要翻译的技术名词用 `Text(verbatim:)`。
- 英文翻译在 `Resources/en.lproj/Localizable.strings`；`Resources/zh-Hans.lproj/` 只用来声明支持简体中文，不需要逐条填写。
- 新增或修改界面文字后运行 `scripts/localization.py`，它会列出缺少英文翻译和已经不用的条目。
- 在英文界面下检查未翻译的文字（未翻译的会显示成全大写）：

  ```bash
  open -n /Applications/Tidytalk.app --args --settings-capture /tmp/settings-en -AppleLanguages "(en)" -NSShowNonLocalizedStrings YES
  ```

## 代码结构

| 目录 | 内容 |
| --- | --- |
| `Sources/TidytalkCore` | 与系统无关的纯逻辑：按键状态机、整理提示词与结果校验、词库与替换、整理模式、中英文排版、长音频切分、配置与模型清单 |
| `Sources/Tidytalk/Services` | 本地识别（sherpa-onnx）、录音、全局按键监听、粘贴、AI 接口、配置文件、模型下载、检查更新 |
| `Sources/Tidytalk/App` | 应用入口、全局状态、录音到粘贴的主流程、开发命令 |
| `Sources/Tidytalk/UI` | 指示器、菜单栏图标、首次启动引导、设置窗口 |
| `Sources/CSherpaOnnx` | sherpa-onnx C API 的模块映射 |
| `Tests/TidytalkCoreTests` | `TidytalkCore` 的单元测试 |

模型依次尝试从 Hugging Face 和 hf-mirror.com 下载，失败自动切换，支持断点续传，下载完成后校验 SHA-256，保存在 `~/Library/Application Support/Tidytalk/Models/`。
