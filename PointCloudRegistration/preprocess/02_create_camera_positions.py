import glob
import json
from pathlib import Path
import numpy as np

# Project root (PointCloudRegistration/), regardless of the current working directory
PROJECT_ROOT = Path(__file__).resolve().parent.parent

# Scene directory
SCENE_NAME = "Outdoor2"
INPUT_SCENE_DIR = PROJECT_ROOT / "input" / SCENE_NAME

# CameraTransform jsons
CAMERA_TRANSFORM_DIR = INPUT_SCENE_DIR / "arkit" / "CameraTransform"

# Output
OUTPUT_FILE = CAMERA_TRANSFORM_DIR / "camera_positions.txt"


def main():
    length = len(glob.glob(str(CAMERA_TRANSFORM_DIR / "*.json")))

    with open(OUTPUT_FILE, "w") as f:
        for i in range(1, length + 1):
            transform = json.load(open(CAMERA_TRANSFORM_DIR / f"{i}.json"))
            translation = np.array(transform["translation"])
            f.write(f"{i}.jpg {translation[0]} {translation[1]} {translation[2]}\n")

    print(f"Camera position data saved to: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
