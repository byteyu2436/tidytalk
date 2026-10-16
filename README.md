# Tidytalk

**按住说话，松开就是整理好的文字。** 一款 macOS 上的段落式语音输入工具。

简体中文 | [English](README.en.md) | [官网](https://tidytalk.zayen.dev/zh/)

<p align="center">
  <img src="docs/images/onboarding.png" width="640" alt="Tidytalk 首次启动引导">
</p>

按住快捷键说一段话，松开后 Tidytalk 在本机识别语音，用 AI 去掉"嗯、那个、就是说"这类口头禅、修正口误和标点，再把文字粘贴到光标处。在任何能打字的地方都能用：微信、邮件、备忘录、代码编辑器。

| 你说的 | 输出 |
| --- | --- |
| 嗯那个我想问一下就是这个 API 的那个 rate limit 呃是多少 | 我想问一下这个 API 的 rate limit 是多少？ |
| 项目要延期到下周三，不对，是下周四 | 项目要延期到下周四。 |

## 特点

- **声音不出这台 Mac**：语音识别用 [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) 在本机完成，支持中文（可夹英文）、英文、日文、韩文和粤语，自动判断语言。
- **只整理，不改写**：删掉口头禅和口误，补全标点，不总结、不补充。听起来像指令的话也只会被整理成文字。
- **AI 服务随你选**：DeepSeek、OpenAI 等 OpenAI 兼容接口都能用；也可以接 Ollama、LM Studio 等本机模型，完全离线。不想用 AI，关掉整理就直接输出识别结果。
- **说中文，出英文**：可以设置输出语言，整理时顺便翻译。
- **不弄乱剪贴板**：粘贴后把剪贴板恢复成原来的内容，包括图片和文件。
- **更多**：个人词库、固定替换、快捷短语、自定义规则、免按住录音、语音改写选中的文字、中英文排版规范。

## 安装

需要 macOS 26 或更高版本、Apple 芯片的 Mac。

1. 在 [Releases](https://github.com/byteyu2436/tidytalk/releases) 下载最新的 `Tidytalk-x.y.z.dmg`，把 Tidytalk 拖进"应用程序"文件夹。
2. 安装包目前没有经过苹果公证，第一次打开会被系统拦下。打开"系统设置 › 隐私与安全性"，在页面底部点"仍要打开"；或者在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/Tidytalk.app
   ```

3. 按引导授权麦克风和辅助功能、填写 AI 接口（可以跳过）、下载语音识别模型（约 230 MB，只需一次）。

也可以[从源码编译](docs/development.md)。

## 使用

1. 把光标放在任意输入框里。
2. 按住 **Option + Command** 说话，屏幕底部会出现指示器。
3. 松开按键，文字出现在光标处。

按 Esc 取消。快速双击快捷键可以免按住录音，再按一次结束。选中一段文字后按住**右侧 Option** 说出修改要求（例如"改得正式一点"），可以直接改写选中的文字。快捷键都可以在设置里更换。

详细说明见[使用指南](docs/usage.md)。

## 隐私

- 录音和语音识别都在本机完成，声音不会上传。
- 开启整理文字时，识别出的**文字**会发送给你配置的 AI 服务。改用本机模型或关闭整理，文字也不会离开电脑。
- API Key 等设置保存在 `~/.tidytalk.json`，只有你自己能读写。
- 最近记录只保存在内存中，退出即清空。

## 文档

- [使用指南](docs/usage.md)：所有功能、整理强度与模式、输出语言、出错时的处理、卸载
- [配置文件](docs/configuration.md)：`~/.tidytalk.json` 的全部字段
- [开发](docs/development.md)：编译、打包发布、工作原理、国际化、代码结构

## 致谢

- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice)（通义实验室 FunAudioLLM）：语音识别模型 SenseVoice-Small
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)：在本机运行模型

第三方组件的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

[MIT](LICENSE)
