#!/usr/bin/env python3
"""Rebuild thumbnail.webp with the official Noctalia thumbnail generator.

    python3 tests/make-thumbnail.py

The community checklist asks for the generator, not for a hand-drawn card, so this
drives it: the page is loaded in headless Chrome with the plugin's own copy, the
generator renders its card at 960x540, and its export canvas is written straight
to thumbnail.webp (the store lays cards out on a fixed 960x540 grid, so the export
is taken at pixelRatio 1).

Requires google-chrome or chromium on PATH. The page pulls html-to-image from a
CDN, so it needs network access.
"""

import base64
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.parse

GENERATOR = "https://assets.noctalia.dev/plugins/thumbnail-generator.html"
OUT = pathlib.Path(__file__).resolve().parent.parent / "thumbnail.webp"
CHROME = ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser")

# The card's copy. `shot=none` renders without the screenshot panel; point it at a
# captured panel image once one exists.
PARAMS = {
    "title": "Network Control",
    "tag": "System · Network · Panel",
    "desc": "Wi-Fi picker and NetworkManager addressing, with rollback.",
    "accent": "iris",
    "shot": "none",
}

EXPORT_HOOK = """
<script>
(async function () {
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  for (var i = 0; i < 60 && !window.htmlToImage; i++) { await wait(200); }
  try {
    if (document.fonts && document.fonts.ready) await document.fonts.ready;
    await wait(500);
    var canvas = await window.htmlToImage.toCanvas(document.getElementById('thumb'),
      {pixelRatio: 1, width: 960, height: 540, cacheBust: true,
       style: {margin: '0', boxShadow: 'none'}});
    var pre = document.createElement('pre');
    pre.id = 'export';
    pre.textContent = canvas.toDataURL('image/webp', 0.98);
    document.body.appendChild(pre);
    document.title = 'EXPORT_READY';
  } catch (e) { document.title = 'EXPORT_FAILED: ' + (e && e.message); }
})();
</script>
</body>"""


def find_chrome():
    for name in CHROME:
        path = shutil.which(name)
        if path:
            return path
    sys.exit("no chrome/chromium on PATH: cannot drive the thumbnail generator")


def main():
    chrome = find_chrome()
    page = subprocess.run(
        ["curl", "-sL", "--max-time", "60", GENERATOR], capture_output=True, text=True, check=True
    ).stdout
    if "URLSearchParams" not in page:
        sys.exit("the generator page did not look like the generator; aborting")

    local = pathlib.Path("/tmp/noctalia-thumbnail-generator.html")
    local.write_text(page.replace("</body>", EXPORT_HOOK))

    url = "file://" + str(local) + "?" + urllib.parse.urlencode(PARAMS)
    dom = subprocess.run(
        [chrome, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
         "--window-size=1200,900", "--virtual-time-budget=25000", "--dump-dom", url],
        capture_output=True, text=True, timeout=240,
    ).stdout

    title = (re.search(r"<title>(.*?)</title>", dom, re.S) or [None, ""])[1]
    if title.startswith("EXPORT_FAILED"):
        sys.exit("the generator refused to export: " + title)
    match = re.search(r'<pre id="export">data:image/webp;base64,([^<]+)</pre>', dom)
    if not match:
        sys.exit("no export in the page output: " + title)

    data = base64.b64decode(match.group(1))
    OUT.write_bytes(data)
    print("wrote %s (%d bytes)" % (OUT, len(data)))

    try:
        from PIL import Image
    except ImportError:
        return
    with Image.open(OUT) as image:
        print("size:", image.size)
        if image.size != (960, 540):
            sys.exit("the store requires 960x540, got %s" % (image.size,))
    if len(data) > 512 * 1024:
        sys.exit("the store rejects thumbnails over 512 KiB")


if __name__ == "__main__":
    main()
