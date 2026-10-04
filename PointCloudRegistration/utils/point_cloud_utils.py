import os
from pathlib import Path

import numpy as np
import open3d as o3d

from utils.colmap_loader import qvec2rotmat, read_extrinsics_binary, read_points3D_binary
from utils.read_write_model import Point3D, read_model, write_model


def sort_image_name_key(name: str):
    try:
        return int(name)
    except ValueError:
        return name


def print_point_count(name: str, pcd: o3d.geometry.PointCloud) -> None:
    print(f"{name}: {len(pcd.points)}")


def get_camera_center_from_extrinsic(extr):
    """
    Compute the camera center from a COLMAP extrinsic.

    COLMAP:
        x_cam = Rcw @ x_world + tcw

    camera center:
        C = -Rcw.T @ tcw
    """
    Rcw = qvec2rotmat(extr.qvec)
    tcw = np.asarray(extr.tvec)
    return -Rcw.T @ tcw


def estimate_colmap_units_per_meter(
    unaligned_images_bin: Path,
    aligned_images_bin: Path,
    stride: int = 5,
    min_aligned_baseline_m: float = 0.20,
) -> float:
    """
    Estimate the scale factor of the unaligned COLMAP coordinate system
    relative to the ARKit meter coordinate system.

    Returns:
        colmap_units_per_meter

    Example:
        If 1m corresponds to 0.69 units in the COLMAP coordinate system,
        returns 0.69.
    """
    unaligned_extrinsics = read_extrinsics_binary(str(unaligned_images_bin))
    aligned_extrinsics = read_extrinsics_binary(str(aligned_images_bin))

    unaligned_by_name = {
        os.path.splitext(extr.name)[0]: extr
        for extr in unaligned_extrinsics.values()
    }

    aligned_by_name = {
        os.path.splitext(extr.name)[0]: extr
        for extr in aligned_extrinsics.values()
    }

    common_names = sorted(
        set(unaligned_by_name.keys()) & set(aligned_by_name.keys()),
        key=sort_image_name_key,
    )

    common_names = common_names[::stride]

    if len(common_names) < 2:
        raise ValueError("Not enough common images available for scale estimation.")

    unaligned_centers = {
        name: get_camera_center_from_extrinsic(unaligned_by_name[name])
        for name in common_names
    }

    aligned_centers = {
        name: get_camera_center_from_extrinsic(aligned_by_name[name])
        for name in common_names
    }

    scale_ratios = []

    for i in range(len(common_names)):
        name_i = common_names[i]

        for j in range(i + 1, len(common_names)):
            name_j = common_names[j]

            d_unaligned = np.linalg.norm(
                unaligned_centers[name_i] - unaligned_centers[name_j]
            )
            d_aligned = np.linalg.norm(
                aligned_centers[name_i] - aligned_centers[name_j]
            )

            if d_aligned < min_aligned_baseline_m:
                continue

            if d_unaligned <= 0:
                continue

            scale_ratios.append(d_unaligned / d_aligned)

    if len(scale_ratios) == 0:
        raise ValueError(
            "Not enough camera-to-camera distances available for scale estimation. "
            "Lower min_aligned_baseline_m or specify MANUAL_COLMAP_UNITS_PER_METER."
        )

    scale_ratios = np.asarray(scale_ratios)
    colmap_units_per_meter = float(np.median(scale_ratios))

    return colmap_units_per_meter


def remove_outliers(
    pcd: o3d.geometry.PointCloud,
    nb_neighbors: int = 30,
    std_ratio: float = 2.0,
) -> o3d.geometry.PointCloud:
    """Remove isolated/floating points."""
    if len(pcd.points) == 0:
        return pcd

    filtered_pcd, _ = pcd.remove_statistical_outlier(
        nb_neighbors=nb_neighbors,
        std_ratio=std_ratio,
    )
    return filtered_pcd


def remove_small_clusters_by_dbscan(
    pcd: o3d.geometry.PointCloud,
    eps: float = 0.10,
    min_points: int = 30,
    min_cluster_size: int = 1000,
) -> o3d.geometry.PointCloud:
    """
    Remove small clusters using DBSCAN.
    eps should already be in COLMAP scale (not meters).
    """
    if len(pcd.points) == 0:
        return pcd

    labels = np.array(
        pcd.cluster_dbscan(
            eps=eps,
            min_points=min_points,
            print_progress=True,
        )
    )

    valid_labels = labels[labels >= 0]

    if len(valid_labels) == 0:
        print("DBSCAN: no valid clusters found")
        return pcd

    counts = np.bincount(valid_labels)

    print("cluster count:", len(counts))
    print("top cluster sizes:", sorted(counts, reverse=True)[:10])

    keep_labels = np.where(counts >= min_cluster_size)[0]
    mask = np.isin(labels, keep_labels)

    before_count = len(pcd.points)
    filtered_pcd = pcd.select_by_index(np.where(mask)[0])
    after_count = len(filtered_pcd.points)

    print(
        f"DBSCAN removed: {before_count - after_count} / {before_count} "
        f"({(before_count - after_count) / before_count:.2%})"
    )

    return filtered_pcd


def filter_points_by_distance(
    pcd: o3d.geometry.PointCloud,
    min_distance_m: float,
    max_distance_m: float,
) -> o3d.geometry.PointCloud:
    """
    In the ARKit camera coordinate system, keep only points whose distance
    from the camera is between min_distance_m and max_distance_m.
    This is before conversion, so units are meters.
    """
    points = np.asarray(pcd.points)

    if len(points) == 0:
        return pcd

    distances = np.linalg.norm(points, axis=1)
    mask = (distances >= min_distance_m) & (distances <= max_distance_m)

    filtered_pcd = pcd.select_by_index(np.where(mask)[0])

    return filtered_pcd


def transform_points_by_camera_pose(
    points_cam_arkit: np.ndarray,
    extr,
    colmap_units_per_meter: float = 1.0,
) -> np.ndarray:
    """
    Transform a point cloud in ARKit camera coordinates into ARKit's
    world coordinates, or an external world coordinate system, using a
    COLMAP camera pose `extr` (position and orientation, from images.bin).

    ARKit-based camera coordinates used in this study:
        X right, Y up, Z backward

    COLMAP's camera-axis convention (required by qvec/tvec):
        X right, Y down, Z forward
    """
    F = np.diag([1.0, -1.0, -1.0])
    points_cam = points_cam_arkit @ F.T

    points_cam = points_cam * colmap_units_per_meter

    Rcw = qvec2rotmat(extr.qvec)
    tcw = np.asarray(extr.tvec)

    points_world = (points_cam - tcw) @ Rcw

    return points_world


def load_colmap_point_cloud(points3d_bin_path: Path) -> o3d.geometry.PointCloud:
    """Load points3D.bin from a COLMAP model as an Open3D point cloud."""
    xyz, rgb, _ = read_points3D_binary(str(points3d_bin_path))

    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(xyz)
    pcd.colors = o3d.utility.Vector3dVector(rgb / 255.0)

    return pcd


def preprocess_point_cloud(
    pcd: o3d.geometry.PointCloud,
    voxel_size: float | None = None,
    apply_outlier_removal: bool = True,
) -> o3d.geometry.PointCloud:
    """Remove outliers from and downsample a point cloud."""
    processed = o3d.geometry.PointCloud(pcd)

    if apply_outlier_removal:
        processed = remove_outliers(processed)

    if voxel_size is not None:
        processed = processed.voxel_down_sample(voxel_size)

    return processed


def align_source_to_target_icp(
    source: o3d.geometry.PointCloud,
    target: o3d.geometry.PointCloud,
    coarse_threshold: float,
    fine_threshold: float,
    units_per_meter: float = 1.0,
    eval_camera_centers: np.ndarray | None = None,
    eval_max_distance_m: float | None = None,
) -> o3d.geometry.PointCloud:
    """
    Align the source point cloud to the target using two-stage ICP.
    Evaluate alignment only on target points within the LiDAR range of the camera centers.
    """

    def rmse_cm(rmse: float) -> float:
        return rmse / units_per_meter * 100

    if eval_camera_centers is not None and eval_max_distance_m is not None:
        camera_centers_pcd = o3d.geometry.PointCloud()
        camera_centers_pcd.points = o3d.utility.Vector3dVector(eval_camera_centers)
        dist_to_camera = np.asarray(target.compute_point_cloud_distance(camera_centers_pcd))
        in_range_mask = dist_to_camera <= (eval_max_distance_m * units_per_meter)
        eval_target = target.select_by_index(np.where(in_range_mask)[0])
        print(
            f"Eval target points within {eval_max_distance_m} m of a camera: "
            f"{len(eval_target.points)} / {len(target.points)}"
        )
    else:
        eval_target = target

    eval_threshold = fine_threshold

    # Before ICP evaluation: target (COLMAP) -> source (ARKit)
    before_eval = o3d.pipelines.registration.evaluate_registration(
        eval_target,
        source,
        eval_threshold,
        np.eye(4),
    )

    print(f"Before ICP fitness: {before_eval.fitness * 100:.2f}%")
    print(f"Before ICP RMSE: {rmse_cm(before_eval.inlier_rmse):.2f} cm")

    # Coarse ICP: source (ARKit) -> target (COLMAP)
    reg_coarse = o3d.pipelines.registration.registration_icp(
        source,
        target,
        coarse_threshold,
        np.eye(4),
        o3d.pipelines.registration.TransformationEstimationPointToPoint(),
    )

    # Fine ICP: source (ARKit) -> target (COLMAP)
    reg_fine = o3d.pipelines.registration.registration_icp(
        source,
        target,
        fine_threshold,
        reg_coarse.transformation,
        o3d.pipelines.registration.TransformationEstimationPointToPoint(),
    )

    # Apply ICP transformation to ARKit point cloud
    aligned = o3d.geometry.PointCloud(source)
    aligned.transform(reg_fine.transformation)

    # After ICP evaluation: target (COLMAP) -> aligned source (ARKit)
    after_eval = o3d.pipelines.registration.evaluate_registration(
        eval_target,
        aligned,
        eval_threshold,
        np.eye(4),
    )

    print(f"After ICP fitness: {after_eval.fitness * 100:.2f}%")
    print(f"After ICP RMSE: {rmse_cm(after_eval.inlier_rmse):.2f} cm")

    return aligned


def remove_points_near_reference(
    source: o3d.geometry.PointCloud,
    reference: o3d.geometry.PointCloud,
    threshold: float,
) -> o3d.geometry.PointCloud:
    """
    Remove source points that are near the reference point cloud.

    source:
        COLMAP point cloud

    reference:
        ARKit / LiDAR point cloud

    In overlapping regions, prioritize the ARKit / LiDAR point cloud and
    remove nearby COLMAP points.
    """
    if len(source.points) == 0:
        return source

    if len(reference.points) == 0:
        return source

    reference_tree = o3d.geometry.KDTreeFlann(reference)
    source_points = np.asarray(source.points)

    keep_indices = []

    for i, p in enumerate(source_points):
        k, _, dist2 = reference_tree.search_knn_vector_3d(p, 1)

        if k == 0:
            keep_indices.append(i)
            continue

        nearest_dist = np.sqrt(dist2[0])

        if nearest_dist > threshold:
            keep_indices.append(i)

    return source.select_by_index(keep_indices)


def reset_normals(pcd: o3d.geometry.PointCloud) -> o3d.geometry.PointCloud:
    """Initialize normals with zero vectors."""
    pcd.normals = o3d.utility.Vector3dVector(
        np.zeros((len(pcd.points), 3), dtype=np.float64)
    )
    return pcd


def save_as_colmap_sparse_model(
    input_sparse_dir: Path,
    output_sparse_dir: Path,
    pcd: o3d.geometry.PointCloud,
) -> None:
    """
    Save the merged point cloud as points3D.bin while preserving
    the existing cameras.bin and images.bin.
    """
    output_sparse_dir.mkdir(parents=True, exist_ok=True)

    cameras, images, _ = read_model(str(input_sparse_dir), ext=".bin")

    xyz = np.asarray(pcd.points, dtype=np.float64)

    if pcd.has_colors():
        rgb = np.asarray(pcd.colors)
        rgb = np.clip(rgb * 255.0, 0, 255).astype(np.uint8)
    else:
        rgb = np.full((len(xyz), 3), 255, dtype=np.uint8)

    points3d = {}

    for point_id, (point_xyz, point_rgb) in enumerate(zip(xyz, rgb), start=1):
        points3d[point_id] = Point3D(
            id=point_id,
            xyz=point_xyz,
            rgb=point_rgb,
            error=0.0,
            image_ids=np.array([], dtype=np.int32),
            point2D_idxs=np.array([], dtype=np.int32),
        )

    # Reset 2D-3D correspondences because points3D has been replaced
    updated_images = {}

    for image_id, image in images.items():
        updated_images[image_id] = image._replace(
            point3D_ids=np.full_like(image.point3D_ids, -1)
        )

    write_model(
        cameras,
        updated_images,
        points3d,
        str(output_sparse_dir),
        ext=".bin",
    )
