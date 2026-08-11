import glob
import os
from pathlib import Path

import numpy as np
import open3d as o3d

from utils.colmap_loader import read_extrinsics_binary
from utils.point_cloud_utils import (
    align_source_to_target_icp,
    load_colmap_point_cloud,
    preprocess_point_cloud,
    print_point_count,
    remove_outliers,
    remove_points_near_reference,
    remove_small_clusters_by_dbscan,
    reset_normals,
    save_as_colmap_sparse_model,
    transform_points_by_colmap_pose,
)


# Scene directory
SCENE_NAME = "Outdoor2"
INPUT_SCENE_DIR = Path("./input") / SCENE_NAME
OUTPUT_SCENE_DIR = Path("./output") / SCENE_NAME

# ARKit-side input
INPUT_POINTCLOUD_DIR = INPUT_SCENE_DIR / "arkit" / "PointCloud"

# COLMAP-side input (camera poses already aligned to the ARKit coordinate system)
INPUT_SPARSE_DIR = INPUT_SCENE_DIR / "colmap" / "sparse_aligned_to_arkit"
INPUT_IMAGES_BIN = INPUT_SPARSE_DIR / "images.bin"
INPUT_POINTS3D_BIN = INPUT_SPARSE_DIR / "points3D.bin"

# Output
OUTPUT_PLY = OUTPUT_SCENE_DIR / "points3D.ply"
OUTPUT_SPARSE_DIR = OUTPUT_SCENE_DIR / "merged_sparse"
OUTPUT_SPARSE_DIR.mkdir(parents=True, exist_ok=True)

FRAME_START = 0
FRAME_END = 540

# Point cloud processing parameters
# This model's scale is already aligned with ARKit, so meter values are used directly.
VOXEL_SIZE = 0.02
COARSE_ICP_THRESHOLD = 0.20
FINE_ICP_THRESHOLD = 0.05
NEAR_THRESHOLD = VOXEL_SIZE
DBSCAN_EPS = 0.05

APPLY_COLMAP_DOWNSAMPLE = True
APPLY_MERGED_DOWNSAMPLE = True
APPLY_MERGED_OUTLIER_REMOVAL = False


def build_arkit_point_cloud_in_arkit_world(
    frame_voxel_size: float,
    dbscan_eps: float,
) -> o3d.geometry.PointCloud:
    
    # 1. Load point clouds
    length = len(glob.glob(str(INPUT_POINTCLOUD_DIR / "*.ply")))
    point_clouds = [
        o3d.io.read_point_cloud(str(INPUT_POINTCLOUD_DIR / f"{i}.ply"))
        for i in range(1, length + 1)
    ]

    # Load COLMAP images.bin
    cam_extrinsics = read_extrinsics_binary(INPUT_IMAGES_BIN)
    
    # Replace COLMAP image IDs with image names as dictionary keys
    extrinsics_by_name = {
        os.path.splitext(extr.name)[0]: extr
        for extr in cam_extrinsics.values()
    }

    # 2. Merge point clouds
    combined_point_cloud = o3d.geometry.PointCloud()
    actual_frame_end = min(FRAME_END, length)
    skipped_frames: dict[str, list[int]] = {}

    for i in range(FRAME_START, actual_frame_end):
        frame_no = i + 1
        image_name = str(frame_no)

        if image_name not in extrinsics_by_name:
            skipped_frames.setdefault("no corresponding image found in images.bin", []).append(frame_no)
            continue

        extr = extrinsics_by_name[image_name]

        # Copy the current point cloud
        current_pcd = o3d.geometry.PointCloud(point_clouds[i])
        current_points = np.asarray(current_pcd.points)
        if len(current_points) == 0:
            skipped_frames.setdefault("empty point cloud", []).append(frame_no)
            continue

        # Transform the ARKit point cloud using the COLMAP camera pose
        transformed_points = transform_points_by_colmap_pose(
            points_cam_arkit=current_points,
            extr=extr,
        )
        current_pcd.points = o3d.utility.Vector3dVector(transformed_points)

        # Remove outliers from each frame
        current_pcd = remove_outliers(current_pcd)

        # Downsample each frame
        current_pcd = current_pcd.voxel_down_sample(voxel_size=frame_voxel_size)

        combined_point_cloud += current_pcd

    for reason, frames in skipped_frames.items():
        print(f"skipped {len(frames)} frames ({reason}): {frames}")

    # 3. Post-process the merged point cloud
    combined_point_cloud = remove_outliers(combined_point_cloud)

    combined_point_cloud = remove_small_clusters_by_dbscan(
        combined_point_cloud,
        eps=dbscan_eps,
        min_points=30,
        min_cluster_size=500,
    )

    return combined_point_cloud


def merge_colmap_and_arkit_point_clouds(
    pcd_arkit: o3d.geometry.PointCloud,
    voxel_size: float,
    coarse_icp_threshold: float,
    fine_icp_threshold: float,
    near_threshold: float,
) -> o3d.geometry.PointCloud:
    
    # 1. Load the COLMAP point cloud
    pcd_colmap = load_colmap_point_cloud(INPUT_POINTS3D_BIN)
    print_point_count("COLMAP points", pcd_colmap)
    print_point_count("ARKit points", pcd_arkit)

    # 2. Preprocess both point clouds before alignment
    colmap_voxel_size = voxel_size if APPLY_COLMAP_DOWNSAMPLE else None
    pcd_colmap = preprocess_point_cloud(
        pcd_colmap,
        voxel_size=colmap_voxel_size,
        apply_outlier_removal=True,
    )
    pcd_arkit = preprocess_point_cloud(
        pcd_arkit,
        voxel_size=voxel_size,
        apply_outlier_removal=True,
    )

    # 3. Align the ARKit point cloud to the COLMAP point cloud via ICP
    pcd_arkit_aligned = align_source_to_target_icp(
        source=pcd_arkit,
        target=pcd_colmap,
        coarse_threshold=coarse_icp_threshold,
        fine_threshold=fine_icp_threshold,
    )

    # 4. Remove COLMAP points that duplicate the aligned ARKit points
    pcd_colmap_filtered = remove_points_near_reference(
        source=pcd_colmap,
        reference=pcd_arkit_aligned,
        threshold=near_threshold,
    )

    # 5. Merge and post-process
    pcd_merged = pcd_arkit_aligned + pcd_colmap_filtered

    if APPLY_MERGED_DOWNSAMPLE:
        pcd_merged = pcd_merged.voxel_down_sample(voxel_size)

    if APPLY_MERGED_OUTLIER_REMOVAL:
        pcd_merged = remove_outliers(pcd_merged)

    return pcd_merged


def main() -> None:
    # 1. Transform the ARKit / LiDAR point cloud into COLMAP world coordinates
    pcd_arkit = build_arkit_point_cloud_in_arkit_world(
        frame_voxel_size=VOXEL_SIZE,
        dbscan_eps=DBSCAN_EPS,
    )

    # 2. Merge with the COLMAP point cloud
    pcd_merged = merge_colmap_and_arkit_point_clouds(
        pcd_arkit=pcd_arkit,
        voxel_size=VOXEL_SIZE,
        coarse_icp_threshold=COARSE_ICP_THRESHOLD,
        fine_icp_threshold=FINE_ICP_THRESHOLD,
        near_threshold=NEAR_THRESHOLD,
    )

    # 3. Visualization
    o3d.visualization.draw_geometries([pcd_merged])

    # 4. Save as PLY
    pcd_merged = reset_normals(pcd_merged)
    o3d.io.write_point_cloud(str(OUTPUT_PLY), pcd_merged)
    print("Merged points:", len(pcd_merged.points))
    print(f"Merged point cloud saved to: {OUTPUT_PLY}")

    # 5. Save as COLMAP sparse model
    save_as_colmap_sparse_model(
        input_sparse_dir=INPUT_SPARSE_DIR,
        output_sparse_dir=OUTPUT_SPARSE_DIR,
        pcd=pcd_merged,
    )
    print(f"COLMAP sparse model saved to: {OUTPUT_SPARSE_DIR}")


if __name__ == "__main__":
    main()
