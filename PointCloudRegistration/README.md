# PointCloudRegistration

## Background & Purpose

- Point clouds obtained from the iPhone's LiDAR sensor are saved separately for each shot and therefore need to be merged to represent the entire scene.
- This process aligns the point clouds in a common coordinate system using the corresponding camera poses, applies outlier removal and downsampling, and merges them into a single scene point cloud.

## Project Directory Structure

```
PointCloudRegistration/
├── preprocess/                                          # Preprocessing scripts for raw ARKit data
│   ├── 01_rename_arkit_files.py
│   └── 02_create_camera_positions.py
│
├── 01_arkit_pointcloud_registration.py                  # Merges ARKit point clouds only
├── 02_arkit_colmap_registration_in_arkit_coords.py      # ARKit + COLMAP point clouds (ARKit coordinate system)
├── 03_arkit_colmap_registration_in_colmap_coords.py     # ARKit + COLMAP point clouds (COLMAP coordinate system)
├── 04_visualize_pointcloud.py                           # Visualizes the generated point cloud
├── utils/                                                # Shared functions for reading COLMAP binaries and processing point clouds
├── input/<SCENE_NAME>/                                   # Input data per scene
└── output/<SCENE_NAME>/                                  # Output per scene (points3D.ply, merged_sparse/)
```

Input data for each scene is expected to follow this layout.

```
input/<SCENE_NAME>/
├── arkit/
│   ├── PointCloud/       # Point cloud for each frame (1.ply, 2.ply, ...)
│   ├── Images/
│   ├── DepthMaps/
│   ├── CameraTransform/  # Camera pose for each frame (1.json, 2.json, ...)
│   └── FOV/
│
└── colmap/
    ├── sparse_original/          # Original COLMAP model before alignment to ARKit
    └── sparse_aligned_to_arkit/  # COLMAP model aligned to the ARKit coordinate system
```

## Setup
This repository uses Poetry for environment management, but Poetry is not required. The main dependencies are NumPy and Open3D, and the scripts can be run in any Python environment where these packages are available.

If using Poetry, install the dependencies and activate the virtual environment as follows.

```bash
poetry install
poetry shell
```

## Usage

### 1. Preprocessing (Preparing Raw ARKit Data)

Run the scripts in `preprocess/` in numerical order to prepare the raw ARKit data for point cloud registration.

```bash
python ./preprocess/01_rename_arkit_files.py   # Renames timestamped files to 1, 2, 3, ...
python ./preprocess/02_create_camera_positions.py  # Generates camera_positions.txt from each json in CameraTransform
```

`camera_positions.txt` is used as reference data when aligning the COLMAP model to the ARKit coordinate system with COLMAP's `model_aligner`.

### 2. Point Cloud Registration & Merging

- Using ARKit point clouds only (mainly for indoor scenes)
```bash
python 01_arkit_pointcloud_registration.py
```

- Merging ARKit + COLMAP point clouds, processed in the ARKit coordinate system (indoor or outdoor)
```bash
python 02_arkit_colmap_registration_in_arkit_coords.py
```

- Merging ARKit + COLMAP point clouds, processed in the COLMAP coordinate system (indoor or outdoor)
```bash
python 03_arkit_colmap_registration_in_colmap_coords.py
```

Running a script displays the merged point cloud in the Open3D viewer and saves it to `output/<SCENE_NAME>/points3D.ply`. It also saves a COLMAP-format model to `output/<SCENE_NAME>/merged_sparse/`, with the camera information preserved and `points3D.bin` replaced with the merged point cloud.

## Preparing COLMAP Data
In this study, COLMAP-based SfM was performed using the following steps to obtain the camera extrinsics and a sparse point cloud.

1. `colmap feature_extractor`: extracts features from each image
2. `colmap exhaustive_matcher`: matches features between images
3. `colmap mapper`: reconstructs camera poses and the 3D point cloud

The resulting reconstruction (`sparse_original`) does not match real-world metric scale or the ARKit coordinate system. Therefore, `colmap model_aligner` is used together with `camera_positions.txt` (the ARKit camera position for each image) generated during preprocessing, to create a model aligned to the ARKit coordinate system (`sparse_aligned_to_arkit`).
