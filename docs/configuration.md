# 配置文件

设置窗口里的内容都保存在用户目录下的隐藏文件 `~/.tidytalk.json`，文件权限为仅本人可读写（600）。也可以在"设置 › 配置 AI"里点"打开配置文件"，用文本编辑器直接修改，下次整理时自动生效。文件格式有误时，应用暂时改用默认设置并给出提示；这时在设置窗口里改动任何选项，会用当前设置重写整个文件。

示例：

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
  "auto_update_check": true,
  "listen_source": "",
  "caption_size": "medium",
  "caption_auto_hide": true,
  "caption_translate": false,
  "caption_language": "zh-Hans",
  "caption_style": "dark",
  "speech_model": "sense_voice",
  "learn_corrections": true
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
| `ai.service` | `openai`（OpenAI 兼容接口，默认）或 `apple`（使用系统自带的 Apple 智能，这时接口地址、Key、模型不用填） |
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
| `auto_update_check` | 启动时自动检查更新，每天最多一次 |
| `listen_source` | 实时字幕收听的应用（bundle id，例如 `com.google.Chrome`），空字符串表示全部声音 |
| `caption_size` | 字幕文字大小：`small`、`medium` 或 `large` |
| `caption_auto_hide` | 没有声音 10 秒后隐藏字幕条 |
| `caption_translate` | 在字幕原文下面显示译文（使用 `ai` 里的服务） |
| `caption_language` | 字幕翻译成的语言，取值同 `output_language`，但不能是 `original`；默认跟随系统语言 |
| `caption_style` | 字幕条样式：`dark`（深色）或 `glass`（玻璃） |
| `speech_model` | 识别模型：`sense_voice`（默认）、`qwen3_asr`、`fun_asr_nano`、`whisper_turbo` 或 `apple`（系统自带）；没下载的模型要先在"设置 › 识别模型"里下载 |
| `learn_corrections` | 粘贴后发现你手动改了某个词时，提示加入词库 |
