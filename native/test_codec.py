"""Synthetic codec checks. User draft contents are never included in fixtures."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ENGINE = Path(sys.argv[1] if len(sys.argv) > 1 else
              "/Applications/VideoFusion-macOS.app/Contents/Frameworks/libvideoeditor.dylib")


def invoke(*args):
    return subprocess.run([str(HERE / "draft_decode"), *map(str, args)],
                          capture_output=True, timeout=30)


with tempfile.TemporaryDirectory(prefix="codec-test-", dir=HERE) as scratch:
    root = Path(scratch)
    plain, encrypted, decoded = [root / n for n in ("plain.json", "encrypted.json", "decoded.json")]
    plain.write_text(json.dumps({"name": "只读解码往返测试", "tracks": [],
                                "materials": {"texts": []}, "duration": 1000000},
                               ensure_ascii=False), encoding="utf-8")
    before = hashlib.sha256(plain.read_bytes()).hexdigest()
    encode = invoke("--encode", ENGINE, plain, encrypted)
    assert encode.returncode == 0, encode.stderr.decode(errors="replace")
    decode = invoke(ENGINE, encrypted, decoded)
    assert decode.returncode == 0, decode.stderr.decode(errors="replace")
    assert decoded.read_bytes() == plain.read_bytes()
    overwrite = invoke("--encode", ENGINE, plain, plain)
    assert overwrite.returncode == 7
    assert before == hashlib.sha256(plain.read_bytes()).hexdigest()
    malformed = root / "invalid.json"
    malformed.write_text("not JSON", encoding="utf-8")
    invalid_out = root / "should-not-exist"
    invalid = invoke("--encode", ENGINE, malformed, invalid_out)
    assert invalid.returncode == 6 and not invalid_out.exists()
print("PASS: exact roundtrip, input unchanged, overwrite refused, invalid JSON refused")
