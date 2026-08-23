import glob
import os
from pathlib import Path

import numpy as np
import open3d as o3d

from utils.colmap_loader import read_extrinsics_binary
from utils.point_cloud_utils import (
    filter_points_by_distance,
    remove_outliers,
    remove_small_clusters_by_dbscan,
    reset_normals,
    save_as_colmap_sparse_model,
    transform_points_by_camera_pose,
)

# Scene directory
SCENE_NAME = "Indoor4"
INPUT_SCENE_DIR = Path("./input") / SCENE_NAME
OUTPUT_SCENE_DIR = Path("./output") / SCENE_NAME

# ARKit-side input
INPUT_POINTCLOUD_DIR = INPUT_SCENE_DIR / "arkit" / "PointCloud"

# COLMAP-side input (camera poses already aligned to the ARKit coordinate system)
INPUT_SPARSE_DIR = INPUT_SCENE_DIR / "colmap" / "sparse_aligned_to_arkit"
INPUT_IMAGES_BIN = INPUT_SPARSE_DIR / "images.bin"

# Output
OUTPUT_PATH = OUTPUT_SCENE_DIR / "points3D.ply"
OUTPUT_SPARSE_DIR = OUTPUT_SCENE_DIR / "merged_sparse"
OUTPUT_SPARSE_DIR.mkdir(parents=True, exist_ok=True)

FRAME_START = 0
FRAME_END = 540

# Point cloud distance filter settings
USE_DISTANCE_FILTER = True
MIN_DISTANCE_M = 0.00
MAX_DISTANCE_M = 5.00

# Point cloud processing parameters
VOXEL_SIZE_M = 0.02
APPLY_MERGED_DOWNSAMPLE = True

# Parameters for removing small clusters via DBSCAN after merging
DBSCAN_EPS_M = 0.05
DBSCAN_MIN_POINTS = 30
DBSCAN_MIN_CLUSTER_SIZE = 500


def main():
    # 1. Load data
    # 1-1. Load point clouds
    length = len(glob.glob(f"{INPUT_POINTCLOUD_DIR}/*.ply"))
    point_clouds = [
        o3d.io.read_point_cloud(f"{INPUT_POINTCLOUD_DIR}/{i}.ply")
        for i in range(1, length + 1)
    ]

    # 1-2. Load COLMAP images.bin
    cam_extrinsics = read_extrinsics_binary(INPUT_IMAGES_BIN)

    # Replace COLMAP image IDs with image names as dictionary keys
    extrinsics_by_name = {
        os.path.splitext(extr.name)[0]: extr
        for extr in cam_extrinsics.values()
    }

    # 2. Merge point clouds
    combined_point_cloud = o3d.geometry.PointCloud()
    skipped_frames: dict[str, list[int]] = {}

    for i in range(FRAME_START, FRAME_END):
        frame_no = i + 1
        image_name = str(frame_no)

        if image_name not in extrinsics_by_name:
            skipped_frames.setdefault("no corresponding image found in images.bin", []).append(frame_no)
            continue

        extr = extrinsics_by_name[image_name]

        # Copy the current point cloud
        current_pcd = o3d.geometry.PointCloud(point_clouds[i])

        # Filter points by distance for each frame
        if USE_DISTANCE_FILTER:
            current_pcd = filter_points_by_distance(
                current_pcd,
                min_distance_m=MIN_DISTANCE_M,
                max_distance_m=MAX_DISTANCE_M,
            )

        # Convert the point coordinates to a NumPy array
        current_points = np.asarray(current_pcd.points)
        if len(current_points) == 0:
            skipped_frames.setdefault("no points after distance filter", []).append(frame_no)
            continue

        # Transform the ARKit point cloud using the COLMAP camera pose
        transformed_points = transform_points_by_camera_pose(
            current_points,
            extr
        )
        current_pcd.points = o3d.utility.Vector3dVector(transformed_points)

        # Remove outliers from each frame
        current_pcd = remove_outliers(current_pcd)

        # Downsample each frame
        current_pcd = current_pcd.voxel_down_sample(
            voxel_size=VOXEL_SIZE_M
        )

        combined_point_cloud += current_pcd

    for reason, frames in skipped_frames.items():
        print(f"skipped {len(frames)} frames ({reason}): {frames}")

    # 3. Post-process the merged point cloud
    combined_point_cloud = remove_outliers(combined_point_cloud)

    combined_point_cloud = remove_small_clusters_by_dbscan(
        combined_point_cloud,
        eps=DBSCAN_EPS_M,
        min_points=DBSCAN_MIN_POINTS,
        min_cluster_size=DBSCAN_MIN_CLUSTER_SIZE
    )

    if APPLY_MERGED_DOWNSAMPLE:
        combined_point_cloud = combined_point_cloud.voxel_down_sample(
            voxel_size=VOXEL_SIZE_M
        )

    # 4. Visualization
    # Clear normals so draw_geometries renders flat colors without shading
    combined_point_cloud.normals = o3d.utility.Vector3dVector()
    o3d.visualization.draw_geometries([combined_point_cloud])

    # 5. Output
    # 5-1. Save the merged point cloud in PLY format
    pcd_merged = reset_normals(combined_point_cloud)
    o3d.io.write_point_cloud(str(OUTPUT_PATH), pcd_merged)
    print("Merged points:", len(pcd_merged.points))
    print(f"Merged point cloud saved to: {OUTPUT_PATH}")

    # 5-2. Save the merged point cloud in COLMAP BIN format
    save_as_colmap_sparse_model(
        input_sparse_dir=INPUT_SPARSE_DIR,
        output_sparse_dir=OUTPUT_SPARSE_DIR,
        pcd=pcd_merged,
    )
    print(f"COLMAP sparse model saved to: {OUTPUT_SPARSE_DIR}")


if __name__ == "__main__":
    main()
