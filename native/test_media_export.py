#!/usr/bin/env python3
"""Integration checks using only a generated test video, never user media."""
import hashlib
import json
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
BACKEND = HERE / "media-export"
FIXTURE = HERE / "media-fixture"


def run(*args, ok=True):
    process = subprocess.run([str(arg) for arg in args], text=True, capture_output=True, timeout=60)
    if ok:
        assert process.returncode == 0, process.stderr
        return json.loads(process.stdout)
    assert process.returncode != 0, "Expected command rejection"
    return json.loads(process.stderr)


def main():
    evidence = {"fixture": "Generated 3 s red/green/blue 30 fps portrait video with 440 Hz audio"}
    with tempfile.TemporaryDirectory(prefix="jianying-media-test-") as directory:
        root = pathlib.Path(directory)
        source = root / "fixture.mp4"
        output = root / "cut.mp4"
        subprocess.run([str(FIXTURE), "create", str(source)], check=True, capture_output=True, text=True, timeout=60)
        original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        evidence["source"] = run(BACKEND, "probe", source)
        assert evidence["source"]["duration_us"] == 3_000_000
        assert evidence["source"]["has_audio"]
        result = run(BACKEND, "cut", source, output, 500_000, 1_000_000)
        assert abs(result["duration_us"] - 1_000_000) <= 66_667
        assert (result["width"], result["height"]) == (360, 640)
        assert result["has_audio"]
        evidence["cut_0.5_to_1.5"] = {key: value for key, value in result.items() if key != "output"}
        colors = run(FIXTURE, "inspect", output)
        # ColorSync / encoder conversions vary across macOS hosts. Verify the
        # expected dominant channel rather than an exact secondary-channel value.
        red, green = colors[0]["rgba"], colors[1]["rgba"]
        assert red[0] > 180 and red[0] - max(red[1], red[2]) > 120, colors
        assert green[1] > 180 and green[1] - max(green[0], green[2]) > 120, colors
        assert all((frame["width"], frame["height"]) == (360, 640) for frame in colors)
        evidence["decoded_frame_samples"] = colors
        prior_hash = hashlib.sha256(output.read_bytes()).hexdigest()
        assert run(BACKEND, "cut", source, output, 0, 500_000, ok=False)["error"] == "output_exists"
        assert hashlib.sha256(output.read_bytes()).hexdigest() == prior_hash
        evidence["existing_output_unchanged"] = True
        bad_output = root / "invalid.mp4"
        assert run(BACKEND, "cut", source, bad_output, 2_500_000, 1_000_000, ok=False)["error"] == "range_outside_video"
        assert not bad_output.exists()
        assert run(BACKEND, "cut", source, bad_output, -1, 500_000, ok=False)["error"] == "invalid_range"
        assert run(BACKEND, "cut", source, root / "missing" / "cut.mp4", 0, 500_000, ok=False)["error"] == "output_directory_missing"
        evidence["invalid_ranges_and_missing_directory_rejected"] = True
        fine = run(BACKEND, "cut", source, root / "non-frame-boundaries.mp4", 333_333, 777_777)
        assert abs(fine["duration_us"] - 777_777) <= 66_667
        evidence["non_frame_boundary_cut"] = {key: value for key, value in fine.items() if key != "output"}
        assert hashlib.sha256(source.read_bytes()).hexdigest() == original_hash
        evidence["source_unchanged"] = True
        assert not list(root.glob(".media-export-*"))
        evidence["no_temporary_files_left"] = True
    (HERE / "media-test-results.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(evidence, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
