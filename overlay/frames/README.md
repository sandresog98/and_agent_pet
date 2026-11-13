# Frames

This directory is intentionally empty in the public repository.

The overlay can use a Gengar spritesheet, but the frames are not distributed
here for copyright reasons. To create them from an asset you own:

```bash
python -m pip install -r requirements.txt
python tools/extract_gengar_frames.py --zip "C:\path\to\gengar.zip"
```

The script writes `frame-*.png` files into `overlay/frames/<state>/`. Without
them, the overlay uses its original generic ghost pet.
