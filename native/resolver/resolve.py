"""Find a public YouTube upload's original, directly streamable six-channel track."""

import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
from urllib.request import Request, urlopen
from urllib.parse import urlsplit


def fail(code, message):
    print(json.dumps({"code": code, "error": message}, separators=(",", ":")))
    raise SystemExit(2)


class QuietLog:
    # Stream URLs are temporary bearer URLs. Keep extractor output out of app logs.
    def debug(self, message):
        pass

    def warning(self, message):
        pass

    def error(self, message):
        pass


class TransferError(Exception):
    pass


def select_audio(formats):
    candidates = []
    for track in formats:
        if track.get("audio_channels") != 6 or track.get("vcodec") != "none":
            continue
        if track.get("has_drm") or track.get("protocol") != "https":
            continue
        codec = track.get("acodec") or ""
        codec_rank = 3 if codec == "ac-3" else 2 if codec in ("ec-3", "eac3") else 1 if codec.startswith("mp4a") else 0
        if not codec_rank:
            continue
        url = urlsplit(track.get("url") or "")
        if url.scheme != "https" or not (url.hostname or "").endswith(".googlevideo.com") or url.username or url.password:
            continue
        # yt-dlp marks the creator's original language on multi-audio uploads.
        rank = (track.get("language_preference") or 0, codec_rank, track.get("abr") or 0)
        candidates.append((rank, track))
    return max(candidates, key=lambda candidate: candidate[0])[1] if candidates else None


def save_original(track, target):
    # Some DASH MP4s work as regular files even when the macOS network player
    # cannot identify the original YouTube delivery URL. Copy the encoded bytes.
    limit = 512 * 1024 * 1024
    reserve = 128 * 1024 * 1024
    chunk = 4 * 1024 * 1024
    size = track.get("filesize")
    if not isinstance(size, int) or not 0 < size <= limit:
        fail("size", "This surround track is too large or its size could not be verified.")
    if shutil.disk_usage(target.parent).free < size + reserve:
        fail("storage", "There is not enough free space to buffer this surround track.")
    headers = {"User-Agent": (track.get("http_headers") or {}).get("User-Agent") or "Mozilla/5.0"}
    created = False
    try:
        with target.open("xb") as output:
            created = True
            os.chmod(target, 0o600)
            while output.tell() < size:
                start = output.tell()
                end = min(start + chunk, size) - 1
                # A freshly issued CDN URL can briefly return 403 before it begins
                # serving media. Retain the same URL long enough for that transition.
                waits = (0, 0.7, 1.5, 3, 5, 8, 12)
                for attempt, delay in enumerate(waits):
                    if delay:
                        time.sleep(delay)
                    try:
                        span = f"{start}-{end}"
                        query_range = attempt % 2 == 0
                        if query_range:
                            request = Request(track["url"] + "&range=" + span, headers=headers)
                        else:
                            request = Request(track["url"], headers={**headers, "Range": "bytes=" + span})
                        with urlopen(request, timeout=12) as response:
                            origin = urlsplit(response.geturl())
                            if origin.scheme != "https" or not (origin.hostname or "").endswith(".googlevideo.com"):
                                raise ValueError("Unexpected media origin")
                            if response.status == 206 and response.headers.get("Content-Range") == f"bytes {start}-{end}/{size}":
                                expected = end - start + 1
                            elif query_range and response.status == 200 and response.headers.get("Content-Length") == str(end - start + 1):
                                expected = end - start + 1
                            elif response.status == 200 and start == 0 and response.headers.get("Content-Length") == str(size):
                                expected = size
                            else:
                                raise ValueError("Unexpected media range")
                            left = expected
                            while left > 0:
                                block = response.read(min(262144, left))
                                if not block:
                                    raise OSError("Incomplete media response")
                                output.write(block)
                                left -= len(block)
                        break
                    except (OSError, ValueError):
                        output.seek(start)
                        output.truncate()
                        if attempt == len(waits) - 1:
                            raise
        print(json.dumps({"saved": True, "bytes": size}))
    except Exception:
        if created:
            target.unlink(missing_ok=True)
        raise TransferError() from None


def main():
    if len(sys.argv) not in (2, 3) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", sys.argv[1]):
        fail("invalid", "Open a YouTube watch page to use 5.1.")
    if len(sys.argv) == 3 and not sys.stdin.isatty():
        text = sys.stdin.buffer.read(32769)
        if text:
            if len(text) > 32768:
                fail("invalid", "Invalid surround track.")
            source = json.loads(text)
            url = urlsplit(source.get("url") or "")
            if (source.get("videoId") != sys.argv[1] or source.get("channels") != 6 or
                    url.scheme != "https" or not (url.hostname or "").endswith(".googlevideo.com") or
                    url.username or url.password or url.port not in (None, 443)):
                fail("invalid", "Invalid surround track.")
            try:
                save_original({"url": source["url"], "filesize": source.get("filesize"),
                               "http_headers": {"User-Agent": source.get("userAgent")}}, Path(sys.argv[2]))
                return
            except TransferError:
                # Refresh once if the CDN has already invalidated the first signed URL.
                pass
    sys.path.insert(0, str(Path(__file__).with_name("yt-dlp.pyz")))
    from yt_dlp import YoutubeDL
    from yt_dlp.utils import DownloadError

    options = {
        "quiet": True, "no_warnings": True, "logger": QuietLog(),
        "cachedir": False, "noplaylist": True,
        "socket_timeout": 10, "retries": 1, "extractor_retries": 1,
        "skip_download": True,
    }
    for candidate in (Path.home() / ".local/bin/node", Path("/opt/homebrew/bin/node"),
                      Path("/usr/local/bin/node"), shutil.which("node")):
        if candidate and Path(candidate).is_file():
            options["js_runtimes"] = {"node": {"path": str(candidate)}}
            break
    try:
        with YoutubeDL(options) as reader:
            video = reader.extract_info("https://www.youtube.com/watch?v=" + sys.argv[1], download=False)
    except DownloadError:
        fail("lookup", "YouTube did not return a playable public stream. The tab can continue in its normal audio mode.")
    if not video or video.get("id") != sys.argv[1] or video.get("is_live"):
        fail("unsupported", "5.1 is available here for recorded public videos.")
    track = select_audio(video.get("formats") or [])
    if not track:
        fail("stereo", "YouTube did not offer an original 5.1 track for this video.")
    if len(sys.argv) == 3:
        save_original(track, Path(sys.argv[2]))
        return
    result = {
        "videoId": video["id"], "url": track["url"], "codec": track["acodec"],
        "channels": 6, "formatId": str(track["format_id"]),
        "filesize": track.get("filesize"),
        "userAgent": (track.get("http_headers") or {}).get("User-Agent") or "",
        "duration": video.get("duration"),
    }
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except TransferError:
        fail("transfer", "YouTube could not deliver the complete surround track.")
    except Exception:
        fail("reader", "The local YouTube reader could not open this video.")
