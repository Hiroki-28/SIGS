import glob
import os
from pathlib import Path

import numpy as np
import open3d as o3d

from utils.colmap_loader import read_extrinsics_binary
from utils.point_cloud_utils import (
    align_source_to_target_icp,
    estimate_colmap_units_per_meter,
    filter_points_by_distance,
    load_colmap_point_cloud,
    preprocess_point_cloud,
    print_point_count,
    remove_outliers,
    remove_points_near_reference,
    remove_small_clusters_by_dbscan,
    reset_normals,
    save_as_colmap_sparse_model,
    transform_points_by_camera_pose,
)


# Scene directory
SCENE_NAME = "Outdoor2"
INPUT_SCENE_DIR = Path("./input") / SCENE_NAME
OUTPUT_SCENE_DIR = Path("./output") / SCENE_NAME

# ARKit-side input
INPUT_POINTCLOUD_DIR = INPUT_SCENE_DIR / "arkit" / "PointCloud"

# COLMAP-side input (unaligned COLMAP)
INPUT_SPARSE_DIR = INPUT_SCENE_DIR / "colmap" / "sparse_original"
INPUT_IMAGES_BIN = INPUT_SPARSE_DIR / "images.bin"
INPUT_POINTS3D_BIN = INPUT_SPARSE_DIR / "points3D.bin"

# aligned_sparse is only used for scale estimation
ALIGNED_SPARSE_DIR = INPUT_SCENE_DIR / "colmap" / "sparse_aligned_to_arkit"
ALIGNED_IMAGES_BIN = ALIGNED_SPARSE_DIR / "images.bin"

# Output
OUTPUT_PLY = OUTPUT_SCENE_DIR / "points3D.ply"
OUTPUT_SPARSE_DIR = OUTPUT_SCENE_DIR / "merged_sparse"
OUTPUT_SPARSE_DIR.mkdir(parents=True, exist_ok=True)

# Frames to skip
SKIP_FRAMES = []

FRAME_START = 0
FRAME_END = 540

# ARKit point cloud distance filter
# Leave this False if you want to keep far points outdoors
USE_DISTANCE_FILTER = False
MIN_DISTANCE_M = 0.0
MAX_DISTANCE_M = 5.0

# Scale estimation
ESTIMATE_SCALE_FROM_ALIGNED_SPARSE = True
MANUAL_COLMAP_UNITS_PER_METER = 1.0
SCALE_ESTIMATION_STRIDE = 5
MIN_ALIGNED_BASELINE_M = 0.20

# Point cloud processing parameters
# Written in meters here; converted to COLMAP scale during actual processing.
VOXEL_SIZE_M = 0.02
COARSE_ICP_THRESHOLD_M = 0.20
FINE_ICP_THRESHOLD_M = 0.05
NEAR_THRESHOLD_M = VOXEL_SIZE_M
DBSCAN_EPS_M = 0.05

APPLY_COLMAP_DOWNSAMPLE = True
APPLY_ARKIT_DOWNSAMPLE = True
APPLY_DBSCAN_CLUSTER_REMOVAL = True
APPLY_ICP = True
APPLY_MERGED_DOWNSAMPLE = True
APPLY_MERGED_OUTLIER_REMOVAL = False


def build_arkit_point_cloud_in_colmap_world(
    colmap_units_per_meter: float,
    frame_voxel_size_colmap: float,
    dbscan_eps_colmap: float,
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

        if frame_no in SKIP_FRAMES:
            skipped_frames.setdefault("skipped due to an obviously bad point cloud", []).append(frame_no)
            continue

        extr = extrinsics_by_name[image_name]

        # Copy the current point cloud
        current_pcd = o3d.geometry.PointCloud(point_clouds[i])
        current_points = np.asarray(current_pcd.points)
        if len(current_points) == 0:
            skipped_frames.setdefault("empty point cloud", []).append(frame_no)
            continue

        # Filter points by distance for each frame
        if USE_DISTANCE_FILTER:
            current_pcd = filter_points_by_distance(
                current_pcd,
                min_distance_m=MIN_DISTANCE_M,
                max_distance_m=MAX_DISTANCE_M,
            )

            current_points = np.asarray(current_pcd.points)
            if len(current_points) == 0:
                skipped_frames.setdefault("no points after distance filter", []).append(frame_no)
                continue

        # Transform the ARKit point cloud using the COLMAP camera pose
        transformed_points = transform_points_by_camera_pose(
            points_cam_arkit=current_points,
            extr=extr,
            colmap_units_per_meter=colmap_units_per_meter,
        )
        current_pcd.points = o3d.utility.Vector3dVector(transformed_points)

        # Remove outliers from each frame
        current_pcd = remove_outliers(current_pcd)

        # Downsample each frame
        current_pcd = current_pcd.voxel_down_sample(
            voxel_size=frame_voxel_size_colmap
        )

        combined_point_cloud += current_pcd

    for reason, frames in skipped_frames.items():
        print(f"skipped {len(frames)} frames ({reason}): {frames}")

    # 3. Post-process the merged point cloud
    combined_point_cloud = remove_outliers(combined_point_cloud)

    if APPLY_DBSCAN_CLUSTER_REMOVAL:
        combined_point_cloud = remove_small_clusters_by_dbscan(
            combined_point_cloud,
            eps=dbscan_eps_colmap,
            min_points=30,
            min_cluster_size=500,
        )

    return combined_point_cloud


def merge_colmap_and_arkit_point_clouds(
    pcd_arkit: o3d.geometry.PointCloud,
    voxel_size_colmap: float,
    coarse_icp_threshold_colmap: float,
    fine_icp_threshold_colmap: float,
    near_threshold_colmap: float,
    colmap_units_per_meter: float,
) -> o3d.geometry.PointCloud:
    
    # 1. Load the COLMAP point cloud
    pcd_colmap = load_colmap_point_cloud(INPUT_POINTS3D_BIN)
    print_point_count("COLMAP points", pcd_colmap)
    print_point_count("ARKit points", pcd_arkit)

    # 2. Preprocess both point clouds before alignment
    colmap_voxel_size = voxel_size_colmap if APPLY_COLMAP_DOWNSAMPLE else None
    arkit_voxel_size = voxel_size_colmap if APPLY_ARKIT_DOWNSAMPLE else None

    pcd_colmap = preprocess_point_cloud(
        pcd_colmap,
        voxel_size=colmap_voxel_size,
        apply_outlier_removal=True,
    )
    pcd_arkit = preprocess_point_cloud(
        pcd_arkit,
        voxel_size=arkit_voxel_size,
        apply_outlier_removal=True,
    )

    # 3. Align the ARKit point cloud to the COLMAP point cloud via ICP
    if APPLY_ICP:
        pcd_arkit_aligned = align_source_to_target_icp(
            source=pcd_arkit,
            target=pcd_colmap,
            coarse_threshold=coarse_icp_threshold_colmap,
            fine_threshold=fine_icp_threshold_colmap,
            units_per_meter=colmap_units_per_meter,
        )
    else:
        pcd_arkit_aligned = pcd_arkit

    # 4. Remove COLMAP points that duplicate the aligned ARKit points
    pcd_colmap_filtered = remove_points_near_reference(
        source=pcd_colmap,
        reference=pcd_arkit_aligned,
        threshold=near_threshold_colmap,
    )

    # 5. Merge and post-process
    pcd_merged = pcd_arkit_aligned + pcd_colmap_filtered

    if APPLY_MERGED_DOWNSAMPLE:
        pcd_merged = pcd_merged.voxel_down_sample(voxel_size_colmap)

    if APPLY_MERGED_OUTLIER_REMOVAL:
        pcd_merged = remove_outliers(pcd_merged)

    return pcd_merged


def main() -> None:
    # 1. Estimate COLMAP units per meter
    if ESTIMATE_SCALE_FROM_ALIGNED_SPARSE:
        colmap_units_per_meter = estimate_colmap_units_per_meter(
            unaligned_images_bin=INPUT_IMAGES_BIN,
            aligned_images_bin=ALIGNED_IMAGES_BIN,
            stride=SCALE_ESTIMATION_STRIDE,
            min_aligned_baseline_m=MIN_ALIGNED_BASELINE_M,
        )
    else:
        colmap_units_per_meter = MANUAL_COLMAP_UNITS_PER_METER
    print("colmap_units_per_meter:", colmap_units_per_meter)

    voxel_size_colmap = VOXEL_SIZE_M * colmap_units_per_meter
    coarse_icp_threshold_colmap = COARSE_ICP_THRESHOLD_M * colmap_units_per_meter
    fine_icp_threshold_colmap = FINE_ICP_THRESHOLD_M * colmap_units_per_meter
    near_threshold_colmap = NEAR_THRESHOLD_M * colmap_units_per_meter
    dbscan_eps_colmap = DBSCAN_EPS_M * colmap_units_per_meter

    # 2. Transform the ARKit / LiDAR point cloud into the unaligned COLMAP coordinate system
    pcd_arkit = build_arkit_point_cloud_in_colmap_world(
        colmap_units_per_meter=colmap_units_per_meter,
        frame_voxel_size_colmap=voxel_size_colmap,
        dbscan_eps_colmap=dbscan_eps_colmap,
    )

    pcd_arkit = reset_normals(pcd_arkit)

    # 3. Merge with the COLMAP point cloud
    pcd_merged = merge_colmap_and_arkit_point_clouds(
        pcd_arkit=pcd_arkit,
        voxel_size_colmap=voxel_size_colmap,
        coarse_icp_threshold_colmap=coarse_icp_threshold_colmap,
        fine_icp_threshold_colmap=fine_icp_threshold_colmap,
        near_threshold_colmap=near_threshold_colmap,
        colmap_units_per_meter=colmap_units_per_meter,
    )

    # 4. Visualization
    o3d.visualization.draw_geometries([pcd_merged])

    # 5. Save as PLY
    pcd_merged = reset_normals(pcd_merged)
    o3d.io.write_point_cloud(str(OUTPUT_PLY), pcd_merged)
    print("Merged points:", len(pcd_merged.points))
    print(f"Merged point cloud saved to: {OUTPUT_PLY}")

    # 6. Save as COLMAP sparse model
    save_as_colmap_sparse_model(
        input_sparse_dir=INPUT_SPARSE_DIR,
        output_sparse_dir=OUTPUT_SPARSE_DIR,
        pcd=pcd_merged,
    )
    print(f"COLMAP sparse model saved to: {OUTPUT_SPARSE_DIR}")


if __name__ == "__main__":
    main()
