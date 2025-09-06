#!/usr/bin/env python3
"""
Select "key slides" from a directory of frames (e.g., shots) by removing near-duplicates.
Supports multiple methods: phash (perceptual hash), ssim, or color histogram.

Usage:
  python python/select_slides.py --in ./out/<video>/shots --outdir ./out/<video>/slides
                                 [--method phash|ssim|hist] [--threshold T] [--min-gap N]

Defaults:
  --method phash
  --threshold (phash: 12 [Hamming distance 0..64], ssim: 0.15 [keep if 1-SSIM >= 0.15], hist: 0.3 [keep if 1-corr >= 0.3])
  --min-gap 0 (frames)  # ignore first N-1 frames after a keep to avoid bursts

Notes on thresholds:
- phash: lower threshold = more strict (fewer slides kept). Range ~0..64. Typical 8..16.
- ssim: threshold is a fraction. keep if (1 - SSIM) >= threshold. Typical 0.10..0.25.
- hist: threshold is a fraction. keep if (1 - correlation) >= threshold. Typical 0.20..0.40.
"""
import argparse, os, sys, shutil, re
from pathlib import Path

# --- Added helpers for slide validation (text count & blur) ---
_ocr_unavailable_warned = False

def _count_words_ocr(img_path, lang="eng+spa"):
    """
    Return the number of words detected via Tesseract OCR.
    Falls back to 0 if pytesseract or tesseract binary are not available.
    """
    global _ocr_unavailable_warned
    try:
        import cv2, pytesseract
        img = cv2.imread(str(img_path))
        if img is None:
            return 0
        # Preprocess a bit for better OCR
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        # Scale up small images to help OCR
        h, w = gray.shape[:2]
        if max(h, w) < 720:
            import cv2 as _cv2
            scale = 720.0 / max(h, w)
            gray = _cv2.resize(gray, (int(w*scale), int(h*scale)))
        # Simple threshold to reduce background noise
        _, thr = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        text = pytesseract.image_to_string(thr, lang=lang)
        words = re.findall(r"\b\w+\b", text, flags=re.UNICODE)
        return len(words)
    except Exception as e:
        if not _ocr_unavailable_warned:
            print(f"[select_slides] Warning: OCR unavailable or failed ({e}). Skipping text-count filter.", file=sys.stderr)
            _ocr_unavailable_warned = True
        return 0

def _is_blurry(img_path, threshold=100.0):
    """
    Detect blur using the variance of Laplacian.
    Returns True if image is considered blurry (variance < threshold).
    """
    try:
        import cv2
        img = cv2.imread(str(img_path))
        if img is None:
            return True
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        # Normalize size to reduce scale effects
        gray = cv2.resize(gray, (640, 360))
        fm = cv2.Laplacian(gray, cv2.CV_64F).var()
        return fm < float(threshold)
    except Exception as e:
        # If OpenCV missing, be conservative and do not mark as blurry
        print(f"[select_slides] Warning: blur check unavailable ({e}).", file=sys.stderr)
        return False
# --- End helpers ---

def phash_distance(img_path, last_hash):
    from PIL import Image
    import imagehash
    h = imagehash.phash(Image.open(img_path).convert("RGB"))
    if last_hash is None:
        return 9999, h
    return h - last_hash, h  # Hamming distance

def ssim_diff(img_path, last_img):
    import cv2
    from skimage.metrics import structural_similarity as ssim
    img = cv2.imread(str(img_path))
    if img is None:
        return 0.0, None
    img = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    img = cv2.resize(img, (640, 360))
    if last_img is None:
        return 1.0, img  # treat as very different (force keep)
    score = ssim(last_img, img, data_range=img.max()-img.min() if img.max()>img.min() else 1)
    diff = 1.0 - float(score)  # larger diff = more change
    return diff, img

def hist_diff(img_path, last_hist):
    import cv2, numpy as np
    img = cv2.imread(str(img_path))
    if img is None:
        return 0.0, None
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    hist = cv2.calcHist([hsv], [0,1], None, [50,50], [0,180, 0,256])
    cv2.normalize(hist, hist, 0, 1, cv2.NORM_MINMAX)
    if last_hist is None:
        return 1.0, hist
    corr = cv2.compareHist(last_hist, hist, cv2.HISTCMP_CORREL)
    diff = 1.0 - float(corr)  # larger diff = more change
    return diff, hist

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", required=True, help="Directory with frames (e.g., shots/*.jpg)")
    ap.add_argument("--outdir", default="", help="Output directory for selected slides")
    ap.add_argument("--method", default="phash", choices=["phash","ssim","hist"])
    ap.add_argument("--threshold", type=float, default=-1.0)
    ap.add_argument("--min-gap", dest="min_gap", type=int, default=0, help="Frames to skip after a keep")
    
    ap.add_argument("--min-words", type=int, default=2, help="Minimum OCR-detected words to keep a slide (default: 2). Use 0 to disable.")
    ap.add_argument("--blur-thresh", type=float, default=100.0, help="Variance of Laplacian threshold; below is blurry (default: 100). Use <0 to disable.")
    ap.add_argument("--ocr-lang", default="eng+spa", help="OCR languages for pytesseract (default: eng+spa)")

    args = ap.parse_args()

    indir = Path(args.indir)
    assert indir.exists() and indir.is_dir(), f"Input directory not found: {indir}"
    outdir = Path(args.outdir) if args.outdir else (indir.parent / "slides")
    outdir.mkdir(parents=True, exist_ok=True)

    # Default thresholds per method
    if args.threshold < 0:
        if args.method == "phash":   thr = 12.0
        elif args.method == "ssim":  thr = 0.15
        else:                        thr = 0.30
    else:
        thr = args.threshold

    # Gather frames sorted
    frames = sorted([p for p in indir.glob("*.jpg")])
    if not frames:
        print(f"No frames found in {indir} (expected .jpg files)", file=sys.stderr)
        sys.exit(2)

    kept = 0
    gap = 0

    last_hash = None
    last_img  = None
    last_hist = None

    for fp in frames:
        if gap > 0:
            gap -= 1
            continue

        if args.method == "phash":
            d, new_hash = phash_distance(fp, last_hash)
            keep = (d >= thr) or (last_hash is None)
            last_hash = new_hash
        elif args.method == "ssim":
            d, new_img = ssim_diff(fp, last_img)
            keep = (d >= thr) or (last_img is None)
            last_img = new_img
        else:
            d, new_hist = hist_diff(fp, last_hist)
            keep = (d >= thr) or (last_hist is None)
            last_hist = new_hist

        if keep:

            # Additional validation: skip blurry or low-text slides
            # Blur check
            if args.blur_thresh >= 0:
                if _is_blurry(fp, args.blur_thresh):
                    continue
            # Text/word count check via OCR
            if args.min_words > 0:
                wc = _count_words_ocr(fp, lang=args.ocr_lang)
                if wc < args.min_words:
                    continue
            shutil.copy2(fp, outdir / fp.name)
            kept += 1
            gap = max(0, args.min_gap)

    print(str(outdir))

if __name__ == "__main__":
    main()