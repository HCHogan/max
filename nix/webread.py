"""webread: a page's text, for programs and commands in a group's VM. See
"网页搜索" in docs/rust-rewrite.md.

    webread <url> [--offset N] [--max N]

Prints one line about the page, then its text from character N (0 by
default), at most --max characters (12000 by default). A web page comes
as Markdown, its main text only; a PDF as pdftotext lays it out; plain
text, JSON and the like as they are. The whole text is written to
/work/.max/web/, named by the address asked for; with --offset past 0,
that file is read instead of fetching again.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import trafilatura

# Tests write elsewhere.
WEB = os.environ.get("WEBREAD_DIR", "/work/.max/web")
REDIRECTS = 5
# For the whole download, and for the connection.
SECONDS = 20
CONNECT = 10
MOST = 10 << 20
CHUNK = 64 << 10
# Some sites turn away what doesn't look like a browser.
AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"


class Failed(Exception):
    pass


class Redirects(urllib.request.HTTPRedirectHandler):
    max_redirections = REDIRECTS


def fetch(url):
    """The final address, the content type, its charset, and the bytes."""
    opener = urllib.request.build_opener(Redirects)
    request = urllib.request.Request(url, headers={
        "User-Agent": AGENT,
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    })
    deadline = time.monotonic() + SECONDS
    try:
        with opener.open(request, timeout=CONNECT) as response:
            length = response.headers.get("Content-Length")
            if length and length.isdigit() and int(length) > MOST:
                raise Failed(f"太大了：{int(length) >> 20} MiB，最多 {MOST >> 20} MiB；要下载就用 curl")
            body = bytearray()
            while chunk := response.read(CHUNK):
                body += chunk
                if len(body) > MOST:
                    raise Failed(f"太大了：超过 {MOST >> 20} MiB；要下载就用 curl")
                if time.monotonic() > deadline:
                    raise Failed(f"{SECONDS} 秒内没下载完")
            kind = response.headers.get_content_type()
            charset = response.headers.get_content_charset()
            return response.geturl(), kind, charset, bytes(body)
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308):
            raise Failed(f"跳转超过 {REDIRECTS} 次") from None
        raise Failed(f"HTTP {error.code} {error.reason}") from None
    except urllib.error.URLError as error:
        raise Failed(f"连不上：{error.reason}") from None
    except TimeoutError:
        raise Failed(f"{CONNECT} 秒内没有回应") from None


def decoded(body, charset):
    try:
        return body.decode(charset or "utf-8")
    except (LookupError, UnicodeDecodeError):
        return body.decode("utf-8", errors="replace")


def html(body, url):
    """The page's title and its main text as Markdown."""
    text = trafilatura.extract(
        body,
        url=url,
        output_format="markdown",
        include_links=True,
        include_tables=True,
        include_formatting=True,
    )
    if not text:
        # Too little for the main text: all of it, plain.
        text = trafilatura.html2txt(body)
    if not text or not text.strip():
        raise Failed("页面上没有字：可能要跑 JavaScript 才有内容")
    metadata = trafilatura.extract_metadata(body)
    return (metadata.title if metadata else None) or "", text.strip()


def pdf(body):
    with tempfile.NamedTemporaryFile(suffix=".pdf") as file:
        file.write(body)
        file.flush()
        done = subprocess.run(
            ["pdftotext", "-layout", "-enc", "UTF-8", file.name, "-"],
            capture_output=True,
            timeout=SECONDS,
        )
    if done.returncode != 0:
        raise Failed("PDF 读不出来：" + decoded(done.stderr, None).strip()[:200])
    text = decoded(done.stdout, None).strip()
    if not text:
        raise Failed("PDF 里没有文字：可能是扫描的图片")
    return text


TEXT = re.compile(r"^(text/|application/(json|xml|javascript|.*\+(json|xml))$)")


def read(url):
    """The final address, the title, the content type and the text."""
    final, kind, charset, body = fetch(url)
    if kind in ("text/html", "application/xhtml+xml"):
        title, text = html(body, final)
    elif kind == "application/pdf" or body.startswith(b"%PDF-"):
        title, text = "", pdf(body)
    elif TEXT.match(kind):
        title, text = "", decoded(body, charset)
    else:
        raise Failed(f"不是网页、PDF 或文本，是 {kind}；要下载就用 curl")
    return final, title, kind, text


def main():
    parser = argparse.ArgumentParser(prog="webread", description="读一个网页的正文")
    parser.add_argument("url")
    parser.add_argument("--offset", type=int, default=0, help="从第几个字开始")
    parser.add_argument("--max", type=int, default=12000, help="最多打印几个字")
    args = parser.parse_args()
    if not re.match(r"^https?://", args.url):
        print("webread：地址要以 http:// 或 https:// 开头", file=sys.stderr)
        return 2
    name = hashlib.sha256(args.url.encode()).hexdigest()[:16]
    saved = os.path.join(WEB, name + ".md")
    try:
        if args.offset > 0 and os.path.exists(saved):
            with open(saved, encoding="utf-8") as file:
                header, _, text = file.read().partition("\n\n")
        else:
            final, title, kind, text = read(args.url)
            header = f"URL: {final} | {title or '（无标题）'} | {kind}"
            os.makedirs(WEB, exist_ok=True)
            with open(saved, "w", encoding="utf-8") as file:
                file.write(f"{header}\n\n{text}")
    except Failed as error:
        print(f"webread：{error}", file=sys.stderr)
        return 1
    start = max(args.offset, 0)
    shown = text[start : start + max(args.max, 0)]
    end = start + len(shown)
    print(f"{header} | 第 {start}–{end} 字，共 {len(text)} 字，全文在 {saved}")
    print(shown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
