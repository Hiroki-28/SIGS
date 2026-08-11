import glob
import os
import re
from datetime import datetime
from pathlib import Path

# Project root (PointCloudRegistration/), regardless of the current working directory
PROJECT_ROOT = Path(__file__).resolve().parent.parent

# Scene directory
SCENE_NAME = "Outdoor2"
INPUT_SCENE_DIR = PROJECT_ROOT / "input" / SCENE_NAME

# Raw ARKit dump (CameraTransform / DepthMaps / FOV / Images / PointCloud)
TARGET_DIR = INPUT_SCENE_DIR / "arkit"

# Timestamp embedded in the raw filenames (e.g. "..._2026-08-10T01:41:03Z...")
TIMESTAMP_PATTERN = re.compile(r"_(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z")


def main():
    subfolders = [f.path for f in os.scandir(TARGET_DIR) if f.is_dir()]

    for subfolder in subfolders:
        # Recurse into the subfolder itself and any nested subfolders
        all_subfolders = [
            f for f in glob.glob(f"{subfolder}/**/", recursive=True)
            if os.path.isdir(f)
        ]

        for subsubfolder in all_subfolders:
            files = [f for f in glob.glob(f"{subsubfolder}/*") if os.path.isfile(f)]

            # Extract the timestamp from each filename
            files_with_timestamp = []
            for file_path in files:
                filename = os.path.basename(file_path)
                match = TIMESTAMP_PATTERN.search(filename)
                if match:
                    timestamp = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
                    files_with_timestamp.append((file_path, timestamp))

            # Sort by timestamp and rename sequentially starting from 1
            sorted_files = sorted(files_with_timestamp, key=lambda x: x[1])

            for i, (file_path, _) in enumerate(sorted_files, start=1):
                ext = Path(file_path).suffix
                new_file_path = os.path.join(os.path.dirname(file_path), f"{i}{ext}")
                os.rename(file_path, new_file_path)
                print(f"Renamed {file_path} to {new_file_path}")


if __name__ == "__main__":
    main()
