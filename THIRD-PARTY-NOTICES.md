# Third-party notices

FOI YouTube Surround bundles the upstream yt-dlp Python zip application in `native/resolver/yt-dlp.pyz`. The same file is included in the Mac app. The table identifies the upstream components used in this release.

| Component | Version | License | Upstream source |
| --- | --- | --- | --- |
| yt-dlp | 2026.10.26 | Unlicense | [yt-dlp release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26) |
| yt-dlp-ejs | 0.8.0 | Unlicense | [yt-dlp/ejs](https://github.com/yt-dlp/ejs) |
| Meriyah | 6.1.4 | ISC | [meriyah/meriyah](https://github.com/meriyah/meriyah) |
| Astring | 1.9.0 | MIT | [davidbonnet/astring](https://github.com/davidbonnet/astring) |

The SHA-256 digest of the bundled yt-dlp file is `e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3`. The yt-dlp license is also shipped as [YT-DLP-LICENSE.txt](native/resolver/YT-DLP-LICENSE.txt). Meriyah and Astring are bundled inside yt-dlp-ejs. Their original notices also appear in `yt_dlp_ejs/yt/solver/lib.min.js` inside the zip application.

## Meriyah

```text
Copyright (c) 2019 and later, KFlash and others.

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## Astring

```text
Copyright (c) 2015, David Bonnet <david@bonnet.cc>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Python, Node.js, BlackHole, FFmpeg and FOI Surround Monitor are installed separately.
