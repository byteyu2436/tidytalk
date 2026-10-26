#!/usr/bin/env python3
"""检查界面文字的翻译是否齐全。

源代码里的中文就是翻译的键（开发语言为简体中文，中文界面直接显示原文）：
- SwiftUI 控件的字符串字面量：Text("…")、Button("…")、Toggle("…")、Picker("…")、Section("…")、
  Label("…")、LabeledContent("…")、TextField("…")、SecureField("…")、Link("…")；
- 其余地方用 String(localized: "…")。

插值会按系统的规则转成格式符：整数为 %lld，其余为 %@，字面的 % 写成 %%。

用法：
    scripts/localization.py           # 列出缺少英文翻译和已不再使用的条目
    scripts/localization.py --keys    # 列出源代码里所有需要翻译的键
"""
import json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "Sources/Tidytalk", ROOT / "Sources/TidytalkApp", ROOT / "Sources/TidytalkCore"]
SKIP = {"DebugCommands.swift"}  # 开发用命令行，不面向用户
STRINGS = ROOT / "Resources/en.lproj/Localizable.strings"

# 汉字，以及全角标点（例如只含"："的"Tidytalk：%@"）
CJK = re.compile(r"[\u4e00-\u9fff\uff00-\uffef]")
LITERAL = r'"((?:[^"\\\n]|\\.)*)"'
PATTERNS = [
    re.compile(r"String\(localized:\s*" + LITERAL),
    re.compile(r"\b(?:Text|Button|Toggle|Picker|Section|Label|LabeledContent|TextField|SecureField|Link|Menu"
               r"|ContentUnavailableView)\(\s*" + LITERAL),
    # 其他接受 LocalizedStringKey 的地方：.help("…")、默认参数（readyTitle: LocalizedStringKey = "…"）、
    # 会议空状态里的 feature("图标", "标题", "说明")
    re.compile(r"\.help\(\s*" + LITERAL),
    re.compile(r"LocalizedStringKey\s*=\s*" + LITERAL),
    # 中间可以有一个颜色参数：feature("图标", Theme.Tint.meeting, "标题", "说明")
    re.compile(r"\bfeature\(\s*\"[^\"]*\",\s*(?:[^\",]+,\s*)?" + LITERAL),
    re.compile(r"\bfeature\(\s*\"[^\"]*\",\s*(?:[^\",]+,\s*)?\"[^\"]*\",\s*" + LITERAL),
    # 自己写的控件里 LocalizedStringKey 类型的参数：IconButton(help:)、SearchField(prompt:)
    re.compile(r"\bhelp:\s*" + LITERAL),
    re.compile(r"\bprompt:\s*" + LITERAL),
]
# 插值表达式按结尾判断是不是整数
INTEGER = re.compile(r"(\.count|limit|^code|^Int\(.*\))$", re.IGNORECASE)


def to_key(literal: str) -> str:
    parts, i, has_interpolation = [], 0, False
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(literal[j], 0)
                j += 1
            expr = literal[i + 2 : j - 1].strip()
            parts.append(("fmt", "%lld" if INTEGER.search(expr) else "%@"))
            has_interpolation = True
            i = j
        elif literal[i] == "\\":
            parts.append(("lit", literal[i : i + 2]))
            i += 2
        else:
            parts.append(("lit", literal[i]))
            i += 1
    out = []
    for kind, text in parts:
        out.append(text.replace("%", "%%") if kind == "lit" and has_interpolation else text)
    return "".join(out)


def source_keys() -> dict:
    keys = {}
    for base in SOURCES:
        for path in sorted(base.rglob("*.swift")):
            if path.name in SKIP:
                continue
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.strip().startswith("//"):
                    continue
                for pattern in PATTERNS:
                    for m in pattern.finditer(line):
                        if CJK.search(m.group(1)):
                            keys.setdefault(to_key(m.group(1)), f"{path.relative_to(ROOT)}:{lineno}")
    return keys


def translated_keys() -> dict:
    data = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(STRINGS)],
                          check=True, capture_output=True).stdout
    return json.loads(data)


def unescape(key: str) -> str:
    # .strings 解析后的键已去掉转义，源代码里的键还带着 \" 和 \n
    return key.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


if __name__ == "__main__":
    keys = source_keys()
    if "--keys" in sys.argv:
        for key, where in keys.items():
            print(f"{where}\t{key}")
        sys.exit(0)
    translations = translated_keys()
    wanted = {unescape(k): where for k, where in keys.items()}
    missing = [(w, k) for k, w in wanted.items() if k not in translations]
    unused = [k for k in translations if k not in wanted]
    for where, key in missing:
        print(f"缺少翻译\t{where}\t{key}")
    for key in unused:
        print(f"未使用\t{key}")
    print(f"共 {len(wanted)} 条，缺少 {len(missing)} 条，未使用 {len(unused)} 条")
    sys.exit(1 if missing else 0)
