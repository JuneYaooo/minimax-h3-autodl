#!/usr/bin/env python3
"""Validate the technical audio/video contract of an H3 ffprobe record."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def positive_number(value: object, label: str, converter):
    try:
        parsed = converter(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid {label}: {value!r}") from exc
    if parsed <= 0:
        raise ValueError(f"Invalid {label}: {value!r}")
    return parsed


def validate_probe(
    probe: dict,
    *,
    expected_video_codec: str = "h264",
    expected_audio_codec: str = "aac",
    expected_sample_rate: int = 32_000,
    expected_channels: int = 2,
) -> dict:
    streams = probe.get("streams")
    container = probe.get("format")
    if not isinstance(streams, list) or not isinstance(container, dict):
        raise ValueError("Invalid ffprobe response")

    video_streams = [item for item in streams if item.get("codec_type") == "video"]
    audio_streams = [item for item in streams if item.get("codec_type") == "audio"]
    if len(video_streams) != 1 or len(audio_streams) != 1:
        raise ValueError(
            f"Expected one video and one audio stream, got video={len(video_streams)}, "
            f"audio={len(audio_streams)}"
        )

    video = video_streams[0]
    audio = audio_streams[0]
    if video.get("codec_name") != expected_video_codec:
        raise ValueError(
            f"Video codec mismatch: expected={expected_video_codec}, actual={video.get('codec_name')}"
        )
    if audio.get("codec_name") != expected_audio_codec:
        raise ValueError(
            f"Audio codec mismatch: expected={expected_audio_codec}, actual={audio.get('codec_name')}"
        )

    width = positive_number(video.get("width"), "video width", int)
    height = positive_number(video.get("height"), "video height", int)
    sample_rate = positive_number(audio.get("sample_rate"), "audio sample rate", int)
    channels = positive_number(audio.get("channels"), "audio channel count", int)
    size = positive_number(container.get("size"), "container size", int)
    duration = positive_number(container.get("duration"), "container duration", float)
    if sample_rate != expected_sample_rate:
        raise ValueError(
            f"Audio sample-rate mismatch: expected={expected_sample_rate}, actual={sample_rate}"
        )
    if channels != expected_channels:
        raise ValueError(
            f"Audio channel mismatch: expected={expected_channels}, actual={channels}"
        )
    return {
        "video_codec": video["codec_name"],
        "width": width,
        "height": height,
        "audio_codec": audio["codec_name"],
        "sample_rate": sample_rate,
        "channels": channels,
        "duration_seconds": duration,
        "size_bytes": size,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("probe_record")
    parser.add_argument("--expected-video-codec", default="h264")
    parser.add_argument("--expected-audio-codec", default="aac")
    parser.add_argument("--expected-sample-rate", type=int, default=32_000)
    parser.add_argument("--expected-channels", type=int, default=2)
    args = parser.parse_args()

    probe = json.loads(Path(args.probe_record).read_text(encoding="utf-8"))
    summary = validate_probe(
        probe,
        expected_video_codec=args.expected_video_codec,
        expected_audio_codec=args.expected_audio_codec,
        expected_sample_rate=args.expected_sample_rate,
        expected_channels=args.expected_channels,
    )
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
