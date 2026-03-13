import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw


ROOT_DIR = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT_DIR / "python" / "select_slides.py"
SPEC = importlib.util.spec_from_file_location("select_slides", SCRIPT_PATH)
SELECT_SLIDES = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SELECT_SLIDES)

SIZE = (1280, 720)


def slide_a():
    img = Image.new("RGB", SIZE, "#f9f9f9")
    draw = ImageDraw.Draw(img)
    draw.rectangle((80, 80, 1200, 640), outline="navy", width=12)
    draw.rectangle((120, 130, 560, 540), fill="navy")
    draw.text((650, 200), "Slide A", fill="black")
    return img


def slide_b():
    img = Image.new("RGB", SIZE, "#111111")
    draw = ImageDraw.Draw(img)
    draw.ellipse((120, 120, 620, 620), outline="yellow", width=16)
    draw.rectangle((700, 140, 1140, 580), outline="white", width=12)
    draw.text((760, 240), "Slide B", fill="white")
    return img


def save_sequence(indir, images):
    for index, image in enumerate(images, start=1):
        image.save(indir / f"shot-{index:04d}.jpg", quality=95)


def run_selector(indir, outdir, threshold, settle_threshold):
    cmd = [
        sys.executable,
        str(SCRIPT_PATH),
        "--in",
        str(indir),
        "--outdir",
        str(outdir),
        "--method",
        "ssim",
        "--threshold",
        str(threshold),
        "--min-words",
        "0",
        "--blur-thresh",
        "-1",
        "--settle-threshold",
        str(settle_threshold),
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    return sorted(path.name for path in outdir.glob("*.jpg"))


def ssim_repr(image_path):
    bgr = SELECT_SLIDES._load_bgr(image_path)
    _, ref = SELECT_SLIDES.ssim_diff(image_path, None, bgr=bgr)
    return ref


def ssim_diff(image_path, ref):
    bgr = SELECT_SLIDES._load_bgr(image_path)
    diff, new_ref = SELECT_SLIDES.ssim_diff(image_path, ref, bgr=bgr)
    return diff, new_ref


class SelectSlidesTests(unittest.TestCase):
    def test_ssim_uses_last_kept_slide_reference(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            indir = Path(tmpdir) / "shots"
            outdir = Path(tmpdir) / "slides"
            indir.mkdir()

            first = slide_a()
            last = slide_b()
            images = [first] + [Image.blend(first, last, step / 20.0) for step in range(1, 21)]
            save_sequence(indir, images)

            adjacent_diffs = []
            prev_ref = None
            for image_path in sorted(indir.glob("*.jpg")):
                diff, prev_ref = ssim_diff(image_path, prev_ref)
                adjacent_diffs.append(diff)

            first_ref = ssim_repr(indir / "shot-0001.jpg")
            final_diff, _ = ssim_diff(indir / "shot-0021.jpg", first_ref)
            threshold = (max(adjacent_diffs[1:]) + final_diff) / 2.0

            kept = run_selector(indir, outdir, threshold=threshold, settle_threshold=2.0)

            self.assertLess(max(adjacent_diffs[1:]), threshold)
            self.assertGreater(final_diff, threshold)
            self.assertIn("shot-0021.jpg", kept)
            self.assertGreater(len(kept), 1)

    def test_ssim_skips_transition_until_frame_settles(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            indir = Path(tmpdir) / "shots"
            outdir = Path(tmpdir) / "slides"
            indir.mkdir()

            first = slide_a()
            transition = Image.blend(first, slide_b(), 0.75)
            final = slide_b()
            save_sequence(indir, [first, first, transition, final, final])

            first_ref = ssim_repr(indir / "shot-0001.jpg")
            transition_diff, transition_ref = ssim_diff(indir / "shot-0003.jpg", first_ref)
            final_diff, final_ref = ssim_diff(indir / "shot-0004.jpg", first_ref)
            transition_to_final, _ = ssim_diff(indir / "shot-0004.jpg", transition_ref)
            stable_next, _ = ssim_diff(indir / "shot-0005.jpg", final_ref)

            threshold = transition_diff / 2.0
            settle_threshold = (transition_to_final + stable_next) / 2.0
            kept = run_selector(indir, outdir, threshold=threshold, settle_threshold=settle_threshold)

            self.assertGreater(transition_diff, threshold)
            self.assertGreater(final_diff, threshold)
            self.assertGreater(transition_to_final, settle_threshold)
            self.assertLess(stable_next, settle_threshold)
            self.assertEqual(kept, ["shot-0001.jpg", "shot-0004.jpg"])


if __name__ == "__main__":
    unittest.main()
