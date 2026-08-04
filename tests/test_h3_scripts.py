from __future__ import annotations

import argparse
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_script(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, PROJECT_ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {relative_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fl2va = load_script("h3_fl2va", "scripts/remote/run-h3-smoke.py")
ref2va = load_script("h3_ref2va", "scripts/remote/run-h3-ref2va-smoke.py")
service_check = load_script("h3_service_check", "scripts/remote/check-h3-service.py")
media_check = load_script("h3_media_check", "scripts/remote/check-h3-media.py")


def generation_args(**overrides):
    values = {
        "width": 608,
        "height": 352,
        "length": 56,
        "steps": 5,
        "poll_seconds": 5.0,
        "timeout_seconds": 60,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def object_info_fixture():
    nodes = {name: {"input": {"required": {}}} for name in service_check.REQUIRED_NODES}
    nodes["UNETLoader"]["input"]["required"]["unet_name"] = [
        sorted(service_check.REQUIRED_MODELS["UNETLoader"]["unet_name"])
    ]
    nodes["CLIPLoader"]["input"]["required"]["clip_name"] = [
        sorted(service_check.REQUIRED_MODELS["CLIPLoader"]["clip_name"])
    ]
    nodes["VAELoader"]["input"]["required"]["vae_name"] = [
        sorted(service_check.REQUIRED_MODELS["VAELoader"]["vae_name"])
    ]
    return nodes


class GenerationValidationTests(unittest.TestCase):
    def test_valid_generation_parameters(self):
        fl2va.validate_generation_args(generation_args())
        ref2va.validate_generation_args(generation_args())

    def test_invalid_dimensions_are_rejected(self):
        for module in (fl2va, ref2va):
            with self.subTest(module=module.__name__):
                with self.assertRaisesRegex(ValueError, "positive multiples of 32"):
                    module.validate_generation_args(generation_args(width=600))

    def test_invalid_frame_alignment_is_rejected(self):
        for module in (fl2va, ref2va):
            with self.subTest(module=module.__name__):
                with self.assertRaisesRegex(ValueError, r"17n\+5"):
                    module.validate_generation_args(generation_args(length=120))

    def test_fl2va_frame_paths_are_normalized_and_wired(self):
        args = generation_args()
        args.prompt = "test"
        args.seed = 7
        args.filename_prefix = "tests/h3"
        args.first_frame = fl2va.normalize_input_image("frames/first.png")
        args.last_frame = fl2va.normalize_input_image("frames/last.webp")
        graph = fl2va.build_prompt(args)
        self.assertEqual(graph["5"]["inputs"]["first_frame"], ["20", 0])
        self.assertEqual(graph["5"]["inputs"]["last_frame"], ["21", 0])
        self.assertEqual(graph["20"]["inputs"]["image"], "frames/first.png")
        with self.assertRaises(ValueError):
            fl2va.normalize_input_image("../secret.png")

    def test_ref2va_reference_limits_and_modalities(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "references.json"
            path.write_text(
                json.dumps(
                    {
                        "reference_images": ["refs/person.png"],
                        "reference_videos": [
                            {"path": "refs/action.mp4", "include_audio": True}
                        ],
                        "reference_audios": ["refs/music.wav"],
                        "ref_image_size": "max",
                    }
                ),
                encoding="utf-8",
            )
            references = ref2va.load_references(path)
        self.assertEqual(references["images"], ["refs/person.png"])
        self.assertTrue(references["videos"][0]["include_audio"])
        self.assertEqual(references["audios"], ["refs/music.wav"])
        self.assertEqual(references["ref_image_size"], "max")


class ServiceValidationTests(unittest.TestCase):
    def setUp(self):
        self.stats = {
            "system": {
                "comfyui_version": "0.30.0",
                "pytorch_version": "2.13.0+cu130",
            },
            "devices": [{"name": "cuda:0 NVIDIA GeForce RTX 5090 : cudaMallocAsync"}],
        }
        self.queue = {"queue_running": [], "queue_pending": []}
        self.object_info = object_info_fixture()

    def validate(self):
        return service_check.validate_service(
            self.stats,
            self.queue,
            self.object_info,
            expected_comfyui="0.30.0",
            expected_pytorch="2.13.0+cu130",
            expected_device="NVIDIA GeForce RTX 5090",
        )

    def test_valid_service(self):
        summary = self.validate()
        self.assertEqual(summary["queue_running"], 0)
        self.assertEqual(summary["required_model_count"], 5)

    def test_busy_queue_is_rejected(self):
        self.queue["queue_running"] = [[1, "prompt"]]
        with self.assertRaisesRegex(ValueError, "queue is not empty"):
            self.validate()

    def test_missing_node_is_rejected(self):
        del self.object_info["MiniMaxH3ReferenceToVideo"]
        with self.assertRaisesRegex(ValueError, "Missing required ComfyUI nodes"):
            self.validate()

    def test_missing_model_is_rejected(self):
        choices = self.object_info["UNETLoader"]["input"]["required"]["unet_name"][0]
        choices.remove("minimax_h3_ref2va_pruned_int8_convrot.safetensors")
        with self.assertRaisesRegex(ValueError, "Models not visible to ComfyUI"):
            self.validate()


class MediaValidationTests(unittest.TestCase):
    def setUp(self):
        self.probe = {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": "h264",
                    "width": 608,
                    "height": 352,
                },
                {
                    "codec_type": "audio",
                    "codec_name": "aac",
                    "sample_rate": "32000",
                    "channels": 2,
                },
            ],
            "format": {"size": "123456", "duration": "2.333"},
        }

    def test_valid_media_contract(self):
        summary = media_check.validate_probe(self.probe)
        self.assertEqual(summary["video_codec"], "h264")
        self.assertEqual(summary["sample_rate"], 32_000)

    def test_missing_audio_is_rejected(self):
        self.probe["streams"] = self.probe["streams"][:1]
        with self.assertRaisesRegex(ValueError, "one video and one audio"):
            media_check.validate_probe(self.probe)

    def test_wrong_sample_rate_is_rejected(self):
        self.probe["streams"][1]["sample_rate"] = "44100"
        with self.assertRaisesRegex(ValueError, "sample-rate mismatch"):
            media_check.validate_probe(self.probe)

if __name__ == "__main__":
    unittest.main()
