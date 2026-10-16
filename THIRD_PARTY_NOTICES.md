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

## Downloaded on first launch

### SenseVoice-Small speech recognition model

- Model: SenseVoiceSmall by FunAudioLLM (Alibaba Tongyi Lab), https://github.com/FunAudioLLM/SenseVoice
- Converted to ONNX (int8) by the sherpa-onnx project: https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
- License: FunASR Model Open Source License Agreement v1.1, https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE

The model is not part of this repository or the app bundle. Tidytalk downloads it from Hugging Face (or the hf-mirror.com mirror) to `~/Library/Application Support/Tidytalk/Models/` the first time you run it. Your use of the model is governed by the model license above.

## Trademarks

Ollama and LM Studio are trademarks of their respective owners. Their logos appear in Tidytalk's settings and on its website only to identify the local AI tools Tidytalk can connect to; Tidytalk is not affiliated with or endorsed by either project. The logo images come from https://ollama.com and https://lmstudio.ai and are stored, resized onto icon tiles by `scripts/make-provider-icons.swift`, in `Resources/ProviderIcons/` and `site/assets/providers/`.
