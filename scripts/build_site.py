#!/usr/bin/env python3
"""生成官网 site/ 下的页面。

正文写在 site-src/<语言>/*.html 里，文件开头用 HTML 注释写页面信息：

    <!--
    path: /docs/              输出地址（以 / 开头和结尾）
    alternate: /zh/docs/      另一种语言的同一页，没有就不写
    title: 页面标题
    description: 搜索结果里显示的描述
    type: home | article | changelog
    breadcrumb: 面包屑里显示的名字（首页不写）
    -->

这个脚本给每页套上统一的页头、导航、页脚和 SEO 标签（规范链接、中英文互链、
Open Graph、结构化数据），并重新生成 sitemap.xml。更新日志页的内容来自
GitHub Releases，取不到时使用 site-src/releases.json 里的缓存。正文里的 {{version}} 换成
最新版本号。

还会生成给 AI 读的 llms.txt（来自 site-src/llms.txt）和 llms-full.txt（英文页面的纯文本合集）。

用法：python3 scripts/build_site.py
"""

import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "site-src")
OUT = os.path.join(ROOT, "site")
DOMAIN = "https://tidytalk.zayen.dev"
REPO = "byteyu2436/tidytalk"
GITHUB = f"https://github.com/{REPO}"


def asset_url(name):
    """带内容哈希的静态文件地址：文件改了地址就变，访客不会继续用浏览器缓存里的旧样式和脚本。"""
    with open(os.path.join(OUT, "assets", name), "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()[:10]
    return f"/assets/{name}?v={digest}"


ANALYTICS_TOKEN = "88c5b4942b344ed7a3a8023fb3a384a4"
# 必应网站管理员工具的网站验证（tidytalk.zayen.dev），放在首页
BING_VERIFICATION = "5141999B3D274F89A3147B442359C0A5"

# 各语言的界面文字
UI = {
    "en": {
        "html_lang": "en",
        "og_locale": "en_US",
        "og_image": "/assets/og-en.jpg",
        "og_alt": "The Tidytalk icon with the tagline: Hold to talk. Let go, and you get clean text.",
        "home": "/",
        "skip": "Skip to content",
        "download": "Download",
        "nav_label": "Main",
        "brand_label": "Tidytalk home",
        "nav": [("Docs", "/docs/"), ("Compare", "/compare/"), ("Changelog", "/changelog/")],
        "other_lang": ("简体中文", "zh-CN"),
        "breadcrumb_home": "Home",
        "footer_product": "Product",
        "footer_use_cases": "Use cases",
        "footer_project": "Project",
        "footer_compare": "Compare",
        "footer_guides": "Guides",
        "footer_links_product": [("Download", f"{GITHUB}/releases/latest"), ("User guide", "/docs/"),
                                 ("Changelog", "/changelog/")],
        "footer_links_compare": [("All dictation apps", "/compare/"),
                                 ("Wispr Flow alternative", "/alternatives/wispr-flow/"),
                                 ("Superwhisper alternative", "/alternatives/superwhisper/"),
                                 ("Typeless alternative", "/alternatives/typeless/")],
        "footer_links_guides": [("Mixed Chinese and English", "/guides/mixed-chinese-english-dictation/"),
                                ("Live translated captions", "/guides/live-translated-captions/"),
                                ("Names and terms", "/guides/custom-vocabulary/")],
        "footer_links_use_cases": [("For developers", "/use-cases/developers/"),
                                   ("Dictate and translate", "/use-cases/translation/"),
                                   ("Private and offline", "/use-cases/offline/"),
                                   ("Transcribe recordings", "/use-cases/transcribe/")],
        "footer_links_project": [("GitHub", GITHUB), ("Report an issue", f"{GITHUB}/issues"),
                                 ("Privacy", "/privacy/"), ("MIT License", f"{GITHUB}/blob/main/LICENSE")],
        "footer_note": 'Tidytalk is open source under the MIT License. Speech recognition uses '
                       '<a href="https://github.com/FunAudioLLM/SenseVoice">SenseVoice</a> and '
                       '<a href="https://github.com/k2-fsa/sherpa-onnx">sherpa-onnx</a>.',
        "updated": "Updated",
    },
    "zh": {
        "html_lang": "zh-CN",
        "og_locale": "zh_CN",
        "og_image": "/assets/og-zh.jpg",
        "og_alt": "Tidytalk 图标和标语：按住说话，松开就是整理好的文字",
        "home": "/zh/",
        "skip": "跳到正文",
        "download": "下载",
        "nav_label": "主导航",
        "brand_label": "Tidytalk 首页",
        "nav": [("使用指南", "/zh/docs/"), ("对比", "/zh/compare/"), ("更新日志", "/zh/changelog/")],
        "other_lang": ("English", "en"),
        "breadcrumb_home": "首页",
        "footer_product": "产品",
        "footer_use_cases": "使用场景",
        "footer_project": "项目",
        "footer_compare": "对比",
        "footer_guides": "教程",
        "footer_links_product": [("下载", f"{GITHUB}/releases/latest"), ("使用指南", "/zh/docs/"),
                                 ("更新日志", "/zh/changelog/")],
        "footer_links_compare": [("语音输入工具对比", "/zh/compare/"),
                                 ("Mac 语音输入法推荐", "/zh/guides/mac-voice-input-apps/"),
                                 ("Wispr Flow 替代", "/zh/alternatives/wispr-flow/"),
                                 ("Superwhisper 替代", "/zh/alternatives/superwhisper/"),
                                 ("Typeless 替代", "/zh/alternatives/typeless/")],
        "footer_links_guides": [("中英文混说", "/zh/guides/mixed-chinese-english-dictation/"),
                                ("实时翻译字幕", "/zh/guides/live-translated-captions/"),
                                ("认对人名和术语", "/zh/guides/custom-vocabulary/")],
        "footer_links_use_cases": [("程序员", "/zh/use-cases/developers/"),
                                   ("说中文出英文", "/zh/use-cases/translation/"),
                                   ("完全离线", "/zh/use-cases/offline/"),
                                   ("转写录音和视频", "/zh/use-cases/transcribe/")],
        "footer_links_project": [("GitHub", GITHUB), ("反馈问题", f"{GITHUB}/issues"),
                                 ("隐私说明", "/zh/privacy/"), ("MIT 许可证", f"{GITHUB}/blob/main/LICENSE")],
        "footer_note": 'Tidytalk 以 MIT 许可证开源。语音识别使用 '
                       '<a href="https://github.com/FunAudioLLM/SenseVoice">SenseVoice</a> 和 '
                       '<a href="https://github.com/k2-fsa/sherpa-onnx">sherpa-onnx</a>。',
        "updated": "更新于",
    },
}

GITHUB_ICON = ('<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 '
               '3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-'
               '.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-'
               '1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 '
               '2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 '
               '3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-'
               '3.58-8-8-8z"/></svg>')


def read_page(path):
    text = open(path, encoding="utf-8").read()
    match = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    if not match:
        raise SystemExit(f"{path} 缺少页面信息注释")
    meta = {}
    for line in match.group(1).strip().splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    meta["body"] = text[match.end():]
    meta["source"] = path
    return meta


def last_modified(path):
    """页面源文件最后一次提交的日期；还没提交的用今天。"""
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", path], cwd=ROOT,
                             capture_output=True, text=True).stdout.strip()
    except OSError:
        out = ""
    return out or datetime.date.today().isoformat()


def first_published(path):
    """页面源文件第一次提交的日期；还没提交的为空。"""
    try:
        out = subprocess.run(["git", "log", "--diff-filter=A", "--follow", "--format=%cs", "--", path], cwd=ROOT,
                             capture_output=True, text=True).stdout.split()
    except OSError:
        out = []
    return out[-1] if out else ""


def esc(text):
    return html.escape(text, quote=True)


def json_ld(data):
    return ('<script type="application/ld+json">\n'
            + json.dumps(data, ensure_ascii=False, indent=2) + "\n</script>")


def plain_text(fragment):
    text = html.unescape(re.sub(r"<[^>]+>", "", fragment)).replace("\u00a0", " ")
    return re.sub(r"\s+", " ", text).strip()


def faq_ld(body):
    """首页的 FAQPage 结构化数据，直接取页面上的常见问题，保证两者一致。"""
    section = re.search(r'<section[^>]*id="faq".*?</section>', body, re.S)
    if not section:
        return None
    questions = [{"@type": "Question", "name": plain_text(q),
                  "acceptedAnswer": {"@type": "Answer", "text": plain_text(a)}}
                 for q, a in re.findall(r"<summary>(.*?)</summary>(.*?)</details>", section.group(0), re.S)]
    return {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": questions}


def render(page, lang):
    ui = UI[lang]
    url = DOMAIN + page["path"]
    alternate = page.get("alternate")
    en_path, zh_path = (page["path"], alternate) if lang == "en" else (alternate, page["path"])

    head = [
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f"<title>{esc(page['title'])}</title>",
        f'<meta name="description" content="{esc(page["description"])}">',
        f'<link rel="canonical" href="{url}">',
    ]
    if alternate:
        head += [f'<link rel="alternate" hreflang="en" href="{DOMAIN + en_path}">',
                 f'<link rel="alternate" hreflang="zh-CN" href="{DOMAIN + zh_path}">',
                 f'<link rel="alternate" hreflang="x-default" href="{DOMAIN + en_path}">']
    head += [
        '<meta name="robots" content="index, follow">',
        '<meta name="theme-color" content="#fbfbfd" media="(prefers-color-scheme: light)">',
        '<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">',
        f'<meta property="og:type" content="{"website" if page["type"] == "home" else "article"}">',
        '<meta property="og:site_name" content="Tidytalk">',
        f'<meta property="og:title" content="{esc(page["title"])}">',
        f'<meta property="og:description" content="{esc(page["description"])}">',
        f'<meta property="og:url" content="{url}">',
        f'<meta property="og:image" content="{DOMAIN + ui["og_image"]}">',
        '<meta property="og:image:width" content="1200">',
        '<meta property="og:image:height" content="630">',
        f'<meta property="og:image:alt" content="{esc(ui["og_alt"])}">',
        f'<meta property="og:locale" content="{ui["og_locale"]}">',
        f'<meta property="og:locale:alternate" content="{UI["zh" if lang == "en" else "en"]["og_locale"]}">',
        '<meta name="twitter:card" content="summary_large_image">',
        f'<meta name="twitter:title" content="{esc(page["title"])}">',
        f'<meta name="twitter:description" content="{esc(page["description"])}">',
        f'<meta name="twitter:image" content="{DOMAIN + ui["og_image"]}">',
        '<link rel="icon" href="/favicon.ico" sizes="any">',
        '<link rel="icon" type="image/png" sizes="32x32" href="/assets/icon-32.png">',
        '<link rel="apple-touch-icon" href="/assets/icon-180.png">',
        f'<link rel="stylesheet" href="{asset_url("style.css")}">',
    ]

    if page["path"] == "/":
        head.append(f'<meta name="msvalidate.01" content="{BING_VERIFICATION}">')

    # 结构化数据：文章页加文章信息和面包屑；首页的软件信息写在正文里，常见问题从正文生成
    if page["type"] == "home" and (faq := faq_ld(page["body"])):
        head.append(json_ld(faq))
    if page["type"] != "home":
        modified = page["modified"]
        if page["type"] == "article":
            head.append(json_ld({
                "@context": "https://schema.org",
                "@type": "TechArticle",
                "headline": page.get("headline", page["title"]),
                "description": page["description"],
                "inLanguage": ui["html_lang"],
                "url": url,
                "mainEntityOfPage": url,
                "image": DOMAIN + ui["og_image"],
                "datePublished": page.get("published", modified),
                "dateModified": modified,
                "author": {"@type": "Person", "name": "zayen", "url": "https://github.com/byteyu2436"},
                "about": {"@type": "SoftwareApplication", "name": "Tidytalk",
                          "operatingSystem": "macOS", "url": DOMAIN + ui["home"]},
            }))
        head.append(json_ld({
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": ui["breadcrumb_home"], "item": DOMAIN + ui["home"]},
                {"@type": "ListItem", "position": 2, "name": page["breadcrumb"], "item": url},
            ],
        }))

    other_label, other_hreflang = ui["other_lang"]
    other_href = (zh_path if lang == "en" else en_path) or UI["zh" if lang == "en" else "en"]["home"]
    current = ' aria-current="page"'
    # 第一项（使用指南）在手机上也显示，其余只在宽屏显示
    nav_items = "".join(
        f'<li class="nav-section{" nav-keep" if index == 0 else ""}">'
        f'<a href="{href}"{current if href == page["path"] else ""}>{label}</a></li>'
        for index, (label, href) in enumerate(ui["nav"]))
    header = f"""<a class="skip-link" href="#main">{ui["skip"]}</a>
  <header class="site-header">
    <nav class="container nav" aria-label="{ui["nav_label"]}">
      <a class="brand" href="{ui["home"]}" aria-label="{ui["brand_label"]}">
        <img src="/assets/icon-180.png" alt="" width="28" height="28">
        Tidytalk
      </a>
      <ul class="nav-links">
        {nav_items}
        <li class="nav-github"><a href="{GITHUB}" aria-label="GitHub">{GITHUB_ICON}<span class="nav-github-label">GitHub</span></a></li>
        <li><a href="{other_href}" hreflang="{other_hreflang}" lang="{other_hreflang}">{other_label}</a></li>
        <li><a class="button button-primary button-small" href="{GITHUB}/releases/latest">{ui["download"]}</a></li>
      </ul>
    </nav>
  </header>"""

    crumbs = ""
    if page["type"] != "home":
        crumbs = (f'<nav class="breadcrumbs container" aria-label="Breadcrumb">'
                  f'<a href="{ui["home"]}">{ui["breadcrumb_home"]}</a> <span aria-hidden="true">›</span> '
                  f'<span aria-current="page">{esc(page["breadcrumb"])}</span></nav>')

    def links(items):
        return "".join(f'<li><a href="{href}">{label}</a></li>' for label, href in items)

    footer = f"""<footer class="site-footer">
    <div class="container footer-grid">
      <div>
        <a class="brand" href="{ui["home"]}"><img src="/assets/icon-180.png" alt="" width="28" height="28">Tidytalk</a>
        <p>{ui["footer_note"]}</p>
      </div>
      <div><h2>{ui["footer_product"]}</h2><ul>{links(ui["footer_links_product"])}</ul></div>
      <div><h2>{ui["footer_compare"]}</h2><ul>{links(ui["footer_links_compare"])}</ul></div>
      <div><h2>{ui["footer_use_cases"]}</h2><ul>{links(ui["footer_links_use_cases"])}</ul></div>
      <div><h2>{ui["footer_guides"]}</h2><ul>{links(ui["footer_links_guides"])}</ul></div>
      <div><h2>{ui["footer_project"]}</h2><ul>{links(ui["footer_links_project"])}
        <li><a href="{other_href}" hreflang="{other_hreflang}" lang="{other_hreflang}">{other_label}</a></li></ul></div>
    </div>
  </footer>"""

    body = page["body"].replace("{{updated}}", f'{ui["updated"]} {page["modified"]}')
    body = body.replace('src="/assets/demo.js"', f'src="{asset_url("demo.js")}"')
    beacon = json.dumps({"token": ANALYTICS_TOKEN})
    analytics = ('<script type="module" src="https://static.cloudflareinsights.com/beacon.min.js" '
                 f"data-cf-beacon='{beacon}'></script>")
    head_html = "\n  ".join(head)
    return f"""<!doctype html>
<!-- 由 scripts/build_site.py 从 {os.path.relpath(page["source"], ROOT)} 生成，请修改源文件 -->
<html lang="{ui["html_lang"]}">
<head>
  {head_html}
</head>
<body>
  {header}
  {crumbs}
{body.rstrip()}
  {footer}
  {analytics}
</body>
</html>
"""


# ---------- 更新日志 ----------

def full_notes(releases):
    """GitHub 上的发布说明会显示在旧版本的更新提示里，所以写得很短；官网的更新日志用仓库里的完整版
    site-src/release-notes/<标签>.md（有这个文件时）。"""
    for release in releases:
        path = os.path.join(SRC, "release-notes", f"{release['tag']}.md")
        if os.path.exists(path):
            release["body"] = open(path, encoding="utf-8").read().strip()
    return releases


def fetch_releases():
    cache = os.path.join(SRC, "releases.json")
    request = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases?per_page=50",
                                     headers={"Accept": "application/vnd.github+json", "User-Agent": "tidytalk-site"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            releases = json.load(response)
        releases = [{"tag": r["tag_name"], "name": r["name"], "date": r["published_at"][:10],
                     "url": r["html_url"], "body": r.get("body") or ""}
                    for r in releases if not r.get("draft")]
        with open(cache, "w", encoding="utf-8") as f:
            json.dump(releases, f, ensure_ascii=False, indent=2)
            f.write("\n")
        return releases
    except Exception as error:  # 离线或接口限流时用缓存
        print(f"读取 GitHub Releases 失败（{error}），使用缓存")
        return json.load(open(cache, encoding="utf-8"))


CJK = re.compile(r"[一-鿿]")
LATIN = re.compile(r"[A-Za-z]")


def is_chinese(block):
    """按汉字和英文字母的比例判断：英文段落里提到“简体中文”这样的词，仍然算英文。"""
    return len(CJK.findall(block)) * 3 >= len(LATIN.findall(block))


def inline_markdown(text):
    text = esc(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def release_notes(body, lang):
    """发布说明里中英文写在一起：按段落挑出对应语言的部分，校验值等通用行两边都保留。"""
    blocks = [b.strip() for b in re.split(r"\n\s*\n", body.replace("\r\n", "\n")) if b.strip()]
    out = []
    for block in blocks:
        is_common = block.startswith("SHA-256")
        if not is_common and is_chinese(block) != (lang == "zh"):
            continue
        lines = block.splitlines()
        if all(line.lstrip().startswith(("- ", "* ")) for line in lines):
            items = "".join(f"<li>{inline_markdown(line.lstrip()[2:])}</li>" for line in lines)
            out.append(f"<ul>{items}</ul>")
        else:
            css = ' class="checksum"' if is_common else ""
            out.append(f"<p{css}>{inline_markdown(' '.join(lines))}</p>")
    return "\n".join(out)


def changelog_body(lang, releases):
    texts = {
        "en": ("Changelog", "New features, fixes, and downloads for every Tidytalk release.", "Download", "Latest"),
        "zh": ("更新日志", "Tidytalk 每个版本的新功能、修复和下载。", "下载", "最新"),
    }[lang]
    entries = []
    for index, release in enumerate(releases):
        version = release["tag"].lstrip("vV")
        badge = f' <span class="badge">{texts[3]}</span>' if index == 0 else ""
        entries.append(f"""      <article class="release" id="v{esc(version)}">
        <h2><a href="#v{esc(version)}">{esc(version)}</a>{badge}</h2>
        <p class="release-date"><time datetime="{release["date"]}">{release["date"]}</time> · <a href="{esc(release["url"])}">{texts[2]}</a></p>
        {release_notes(release["body"], lang)}
      </article>""")
    return f"""  <main id="main" class="page container">
    <header class="page-head">
      <h1>{texts[0]}</h1>
      <p class="lead">{texts[1]}</p>
    </header>
    <div class="prose">
{chr(10).join(entries)}
    </div>
  </main>"""


# ---------- 给 AI 读的纯文本 ----------

def html_to_text(body):
    """把正文的 HTML 转成接近 Markdown 的纯文本：保留标题、段落、列表和表格，去掉图片和脚本。"""
    text = re.sub(r"<(script|svg|picture|figure|aside|nav)\b.*?</\1>", "", body, flags=re.S)
    text = re.sub(r"<h1[^>]*>(.*?)</h1>", lambda m: f"\n# {m.group(1)}\n", text, flags=re.S)
    text = re.sub(r"<h2[^>]*>(.*?)</h2>", lambda m: f"\n## {m.group(1)}\n", text, flags=re.S)
    text = re.sub(r"<h3[^>]*>(.*?)</h3>", lambda m: f"\n### {m.group(1)}\n", text, flags=re.S)
    text = re.sub(r"<li[^>]*>", "\n- ", text)
    text = re.sub(r"<summary[^>]*>(.*?)</summary>", lambda m: f"\n**{m.group(1)}**\n", text, flags=re.S)
    text = re.sub(r"</t[dh]>\s*<t[dh][^>]*>", " | ", text)
    text = re.sub(r"<(p|tr|div|section|header|ol|ul|table|details)\b[^>]*>", "\n", text)
    text = re.sub(r"<br\s*/?>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text).replace("\u00a0", " ")
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.splitlines()]
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines))
    # 列表项里的内容另起了一行：标题去掉列表符号，其他内容接回列表符号后面
    text = re.sub(r"^-\n+(#{1,6} )", r"\1", text, flags=re.M)
    text = re.sub(r"^-\n+(?=\S)", "- ", text, flags=re.M)
    return text.strip()


def write_llms(pages, version):
    source = os.path.join(SRC, "llms.txt")
    with open(os.path.join(OUT, "llms.txt"), "w", encoding="utf-8") as f:
        f.write(open(source, encoding="utf-8").read().replace("{{version}}", version))
    # 英文页面的正文合集：首页、使用指南、对比、替代、使用场景
    order = ["/", "/docs/", "/compare/", "/alternatives/wispr-flow/", "/alternatives/superwhisper/",
             "/alternatives/typeless/", "/use-cases/transcribe/", "/use-cases/offline/", "/use-cases/developers/",
             "/use-cases/translation/", "/guides/mixed-chinese-english-dictation/",
             "/guides/live-translated-captions/", "/guides/custom-vocabulary/"]
    by_path = {p["path"]: p for p in pages}
    parts = [f"# Tidytalk – full text of the website\n\nVersion {version}. Source: {DOMAIN}/llms.txt"]
    for path in order:
        if path in by_path:
            page = by_path[path]
            parts.append(f"---\n\nURL: {DOMAIN + path}\n\n{html_to_text(page['body'])}")
    with open(os.path.join(OUT, "llms-full.txt"), "w", encoding="utf-8") as f:
        f.write("\n\n".join(parts) + "\n")
    print("生成 site/llms.txt 和 site/llms-full.txt")


# ---------- 主流程 ----------

def main():
    releases = full_notes(fetch_releases())
    version = releases[0]["tag"].lstrip("v") if releases else ""
    pages = []
    for lang in ("en", "zh"):
        folder = os.path.join(SRC, lang)
        for name in sorted(os.listdir(folder)):
            if name.endswith(".html"):
                page = read_page(os.path.join(folder, name))
                page["lang"] = lang
                page["modified"] = last_modified(page["source"])
                page.setdefault("published", first_published(page["source"]) or page["modified"])
                page["body"] = page["body"].replace("{{version}}", version)
                pages.append(page)

    for page in pages:
        if page["type"] == "changelog":
            page["body"] = changelog_body(page["lang"], releases)
            if releases:
                page["modified"] = releases[0]["date"]
        target = os.path.join(OUT, page["path"].strip("/"), "index.html")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as f:
            f.write(render(page, page["lang"]))
        print("生成", os.path.relpath(target, ROOT))

    # 站点地图：每页列出中英文互链
    by_path = {p["path"]: p for p in pages}
    urls = []
    for page in pages:
        lines = [f"    <loc>{DOMAIN + page['path']}</loc>", f"    <lastmod>{page['modified']}</lastmod>"]
        if page.get("alternate"):
            other = by_path[page["alternate"]]
            en, zh = (page, other) if page["lang"] == "en" else (other, page)
            lines += [f'    <xhtml:link rel="alternate" hreflang="en" href="{DOMAIN + en["path"]}"/>',
                      f'    <xhtml:link rel="alternate" hreflang="zh-CN" href="{DOMAIN + zh["path"]}"/>',
                      f'    <xhtml:link rel="alternate" hreflang="x-default" href="{DOMAIN + en["path"]}"/>']
        urls.append("  <url>\n" + "\n".join(lines) + "\n  </url>")
    with open(os.path.join(OUT, "sitemap.xml"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
                'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(urls) + "\n</urlset>\n")
    print("生成 site/sitemap.xml，共", len(pages), "页")
    write_llms(pages, version)


if __name__ == "__main__":
    main()
