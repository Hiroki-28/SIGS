import open3d as o3d

# Settings
INPUT_PLY = "./output/Indoor4/points3D.ply"


def main():
    # 1. Load the point cloud
    pcd = o3d.io.read_point_cloud(INPUT_PLY)
    pcd.normals = o3d.utility.Vector3dVector()
    print("Number of points:", len(pcd.points))

    # 2. Visualization
    # 2-1. Visualization settings
    front = [0.0, 0.0, -0.5]
    lookat = [0.0, 0.0, 0.0]
    up = [0.0, 1.0, 0.0]
    zoom = 0.7

    # 2-2. Visualize the point cloud
    o3d.visualization.draw_geometries(
        [pcd],
        front=front,
        lookat=lookat,
        up=up,
        zoom=zoom
    )

if __name__ == "__main__":
    main()
