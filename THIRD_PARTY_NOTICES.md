# Third-Party Notices

Tidytalk's own source code is released under the [MIT License](LICENSE). It relies on the third-party components below, which keep their own licenses.

## Bundled with the app

These libraries are not stored in this repository. `scripts/fetch-deps.sh` downloads them at build time, and they are copied into `Tidytalk.app/Contents/Frameworks/`.

### sherpa-onnx

- Project: https://github.com/k2-fsa/sherpa-onnx
- File: `libsherpa-onnx-c-api.dylib` (prebuilt C API, version 1.13.8)
- License: Apache License 2.0, https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE

### ONNX Runtime

- Project: https://github.com/microsoft/onnxruntime
- File: `libonnxruntime.dylib`, shipped inside the sherpa-onnx prebuilt package
- License: MIT License, Copyright (c) Microsoft Corporation, https://github.com/microsoft/onnxruntime/blob/main/LICENSE

### Silero VAD

- Project: https://github.com/snakers4/silero-vad
- File: `silero_vad.onnx`, from the sherpa-onnx model releases (https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models), stored in `Resources/` and copied into `Tidytalk.app/Contents/Resources/`
- License: MIT License, Copyright (c) 2020-present Silero Team, https://github.com/snakers4/silero-vad/blob/master/LICENSE

Used by live captions to find where speech starts and stops in the computer's audio.

## Downloaded on first launch

### SenseVoice-Small speech recognition model

- Model: SenseVoiceSmall by FunAudioLLM (Alibaba Tongyi Lab), https://github.com/FunAudioLLM/SenseVoice
- Converted to ONNX (int8) by the sherpa-onnx project: https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
- License: FunASR Model Open Source License Agreement v1.1, https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE

The model is not part of this repository or the app bundle. Tidytalk downloads it from Hugging Face (or the hf-mirror.com mirror) to `~/Library/Application Support/Tidytalk/Models/` the first time you run it. Your use of the model is governed by the model license above.

## Downloaded only if you choose them

These are downloaded from Hugging Face or GitHub to `~/Library/Application Support/Tidytalk/` only when you pick them in Settings › Speech Model or transcribe a link.

### Qwen3-ASR 0.6B

- Model: Qwen3-ASR by the Qwen team (Alibaba Cloud), https://huggingface.co/Qwen/Qwen3-ASR-0.6B
- Converted to ONNX (int8) by the sherpa-onnx project: https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25
- License: Apache License 2.0

### Fun-ASR-Nano

- Model: Fun-ASR-Nano-2512 by FunAudioLLM (Alibaba Tongyi Lab), https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512
- Converted to ONNX (int8) by Wasser1462 and packaged by the sherpa-onnx project: https://huggingface.co/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30
- License: Apache License 2.0

### Whisper large-v3-turbo

- Model: Whisper by OpenAI, https://github.com/openai/whisper
- Converted to ONNX (int8) by the sherpa-onnx project: https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo
- License: MIT License

### yt-dlp

- Project: https://github.com/yt-dlp/yt-dlp
- File: `yt-dlp_macos` from the project's latest GitHub release, verified against the release's SHA2-256SUMS. Used only to download the audio of a link you ask Tidytalk to transcribe.
- License: The Unlicense

## Trademarks

Ollama and LM Studio are trademarks of their respective owners. Their logos appear in Tidytalk's settings and on its website only to identify the local AI tools Tidytalk can connect to; Tidytalk is not affiliated with or endorsed by either project. The logo images come from https://ollama.com and https://lmstudio.ai and are stored, resized onto icon tiles by `scripts/make-provider-icons.swift`, in `Resources/ProviderIcons/` and `site/assets/providers/`.
