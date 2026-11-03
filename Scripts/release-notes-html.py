#!/usr/bin/env python3
"""Converts a release notes file to HTML for the Sparkle update window.

Usage: Scripts/release-notes-html.py release-notes/<tag>.md

Prints an HTML fragment for the appcast item's <description>, so the update
window shows the release notes instead of a link to them. Every Sparkle
version renders HTML, while Markdown needs Sparkle 2.9, and older copies of
Icey shipped an older Sparkle.

Only the Markdown that release notes use is handled: `##` and `###`
headings, paragraphs, `-` bullets and `1.` numbered items nested by two
or three spaces, **bold**, `code`, [links](url) and bare URLs.
"""

import html
import re
import sys

INLINE = re.compile(
    r"\[(?P<text>[^\]]+)\]\((?P<url>[^)\s]+)\)"
    r"|\*\*(?P<bold>.+?)\*\*"
    r"|`(?P<code>[^`]+)`"
    r"|(?P<bare>https?://[^\s<>()]+)"
)

STYLE = (
    "<style>"
    "h2{font-size:1.15em;margin:1em 0 .4em}"
    "h3{font-size:1em;margin:.9em 0 .3em}"
    "p{margin:.5em 0}"
    "ul,ol{margin:.3em 0;padding-left:1.4em}"
    "li{margin:.25em 0}"
    "</style>"
)


def link(url, text):
    return f'<a href="{html.escape(url)}">{text}</a>'


def inline(text):
    out = []
    pos = 0
    for match in INLINE.finditer(text):
        out.append(html.escape(text[pos:match.start()], quote=False))
        if match["text"] is not None:
            out.append(link(match["url"], inline(match["text"])))
        elif match["bold"] is not None:
            out.append(f"<strong>{inline(match['bold'])}</strong>")
        elif match["code"] is not None:
            out.append(f"<code>{html.escape(match['code'], quote=False)}</code>")
        else:
            url = match["bare"].rstrip(".,;:")
            out.append(link(url, html.escape(url, quote=False)))
            out.append(html.escape(match["bare"][len(url):], quote=False))
        pos = match.end()
    out.append(html.escape(text[pos:], quote=False))
    return "".join(out)


def convert(markdown):
    out = [STYLE]
    lists = []  # The open lists, outermost first: (tag, indent).
    paragraph = []

    def close_paragraph():
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_lists(indent=-1):
        # Closes the lists nested deeper than the given indent.
        while lists and lists[-1][1] > indent:
            out.append(f"</li></{lists.pop()[0]}>")

    for raw in markdown.splitlines():
        line = raw.rstrip()
        bullet = re.match(r"^( *)([-*]|\d+\.) (.*)$", line)
        if not line:
            close_paragraph()
            continue
        if bullet:
            close_paragraph()
            indent = len(bullet[1])
            tag = "ul" if bullet[2] in "-*" else "ol"
            close_lists(indent)
            if lists and lists[-1][1] == indent and lists[-1][0] == tag:
                out.append("</li><li>")
            else:
                if lists and lists[-1][1] == indent:
                    close_lists(indent - 1)
                out.append(f"<{tag}><li>")
                lists.append((tag, indent))
            out.append(inline(bullet[3]))
            continue
        if lists and raw.startswith("  "):
            # A wrapped continuation of the current bullet.
            out.append(" " + inline(line.strip()))
            continue
        close_lists()
        heading = re.match(r"^(#{1,6}) (.*)$", line)
        if heading:
            close_paragraph()
            level = min(max(len(heading[1]), 2), 4)
            out.append(f"<h{level}>{inline(heading[2])}</h{level}>")
            continue
        paragraph.append(line.strip())

    close_paragraph()
    close_lists()
    result = "".join(out)
    if "]]>" in result:
        sys.exit("The release notes contain ']]>', which would end the appcast's CDATA section.")
    return result


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: release-notes-html.py <release-notes.md>")
    with open(sys.argv[1], encoding="utf-8") as file:
        print(convert(file.read()))


if __name__ == "__main__":
    main()
