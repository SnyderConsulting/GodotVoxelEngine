#!/usr/bin/env python3
import argparse
import itertools
import math
import sys

try:
    import numpy as np
except ImportError as exc:
    raise SystemExit("This script requires numpy.") from exc

EPS = 1e-6


def bcc_neighbors():
    neighbors = []
    for axis in range(3):
        for s in (-2.0, 2.0):
            v = [0.0, 0.0, 0.0]
            v[axis] = s
            neighbors.append(np.array(v, dtype=float))
    for sx, sy, sz in itertools.product([-1.0, 1.0], repeat=3):
        neighbors.append(np.array([sx, sy, sz], dtype=float))
    return neighbors


def planes_from_neighbors(neighbors):
    return [(n, float(np.dot(n, n)) / 2.0) for n in neighbors]


def voronoi_vertices(planes):
    vertices = []
    for (n1, d1), (n2, d2), (n3, d3) in itertools.combinations(planes, 3):
        A = np.vstack([n1, n2, n3])
        if abs(np.linalg.det(A)) < EPS:
            continue
        x = np.linalg.solve(A, np.array([d1, d2, d3], dtype=float))
        if any(np.dot(n, x) - d > EPS for n, d in planes):
            continue
        key = tuple(round(float(c), 6) for c in x)
        if key not in vertices:
            vertices.append(key)
    return np.array(vertices, dtype=float)


def truncated_vertices_base():
    base = [0.0, 0.5, 1.0]
    verts = set()
    for perm in set(itertools.permutations(base, 3)):
        for sx, sy, sz in itertools.product([-1.0, 1.0], repeat=3):
            verts.add((perm[0] * sx, perm[1] * sy, perm[2] * sz))
    return np.array(sorted(verts), dtype=float)


def face_vertices(planes, vertices):
    faces = []
    for n, d in planes:
        pts = [v for v in vertices if abs(float(np.dot(n, v)) - d) < EPS]
        if pts:
            faces.append((n, d, np.array(pts, dtype=float)))
    return faces


def order_face(pts, normal):
    n = normal / np.linalg.norm(normal)
    ref = np.array([1.0, 0.0, 0.0], dtype=float)
    if abs(float(np.dot(ref, n))) > 0.9:
        ref = np.array([0.0, 1.0, 0.0], dtype=float)
    u = np.cross(n, ref)
    u /= np.linalg.norm(u)
    v = np.cross(n, u)
    proj = [(float(np.dot(p, u)), float(np.dot(p, v))) for p in pts]
    cx = sum(p[0] for p in proj) / len(proj)
    cy = sum(p[1] for p in proj) / len(proj)
    angles = [math.atan2(p[1] - cy, p[0] - cx) for p in proj]
    ordered = [p for _, p in sorted(zip(angles, pts), key=lambda x: x[0])]
    return ordered


def polygon_area(ordered):
    area = 0.0
    p0 = ordered[0]
    for i in range(1, len(ordered) - 1):
        area += 0.5 * np.linalg.norm(np.cross(ordered[i] - p0, ordered[i + 1] - p0))
    return area


def compute_edges(faces):
    lengths = []
    for n, _d, pts in faces:
        ordered = order_face(pts, n)
        for i in range(len(ordered)):
            a = ordered[i]
            b = ordered[(i + 1) % len(ordered)]
            lengths.append(float(np.linalg.norm(a - b)))
    return lengths


def sdf_truncated_octahedron(p):
    inv_sqrt3 = 1.0 / math.sqrt(3.0)
    scale = 2.0
    q = np.abs(p) * scale
    d1 = max(q[0], q[1], q[2]) - 2.0
    d2 = (q[0] + q[1] + q[2] - 3.0) * inv_sqrt3
    return max(d1, d2) / scale


def bcc_parity(x, y, z):
    return (x & 1) == (y & 1) == (z & 1)


def bcc_count_in_cube(n):
    # Count valid BCC sites in an n x n x n cube of integer coordinates.
    even = (n + 1) // 2
    odd = n // 2
    return even ** 3 + odd ** 3


def assert_close(actual, expected, tol, label):
    if abs(actual - expected) > tol:
        raise AssertionError(f"{label}: {actual} != {expected}")


def parse_chunk_sizes(args):
    if args.chunk_range:
        parts = args.chunk_range.split(":")
        if len(parts) not in (2, 3):
            raise ValueError("chunk-range must be start:end[:step]")
        start = int(parts[0])
        end = int(parts[1])
        step = int(parts[2]) if len(parts) == 3 else 1
        if step <= 0:
            raise ValueError("chunk-range step must be > 0")
        return list(range(start, end + 1, step))
    if args.chunk_size:
        sizes = []
        for item in args.chunk_size:
            for part in item.split(","):
                part = part.strip()
                if part:
                    sizes.append(int(part))
        return sizes
    return [5, 6, 7, 10]


def main():
    parser = argparse.ArgumentParser(
        description="Validate truncated octahedron lattice + BCC brick mapping."
    )
    parser.add_argument(
        "--chunk-size",
        action="append",
        help="Chunk size(s) to validate. Repeat or comma-separate values.",
    )
    parser.add_argument(
        "--chunk-range",
        help="Validate a range of sizes: start:end[:step] (inclusive).",
    )
    args = parser.parse_args()
    chunk_sizes = parse_chunk_sizes(args)
    for size in chunk_sizes:
        if size <= 0:
            raise ValueError("chunk sizes must be positive integers.")

    neighbors = bcc_neighbors()
    if len(neighbors) != 14:
        raise AssertionError("BCC neighbor count mismatch.")

    planes = planes_from_neighbors(neighbors)
    voronoi = voronoi_vertices(planes)
    base_vertices = truncated_vertices_base()

    if len(voronoi) != 24:
        raise AssertionError("Voronoi vertex count mismatch.")
    if len(base_vertices) != 24:
        raise AssertionError("Base vertex count mismatch.")

    voronoi_set = {tuple(round(float(c), 6) for c in v) for v in voronoi}
    base_set = {tuple(round(float(c), 6) for c in v) for v in base_vertices}
    if voronoi_set != base_set:
        missing = sorted(base_set - voronoi_set)
        raise AssertionError(f"Voronoi vertices do not match base set: {missing[:3]}")

    faces = face_vertices(planes, voronoi)
    if len(faces) != 14:
        raise AssertionError("Face count mismatch.")
    face_counts = sorted(len(f[2]) for f in faces)
    if face_counts != [4] * 6 + [6] * 8:
        raise AssertionError("Square/hex face counts mismatch.")

    edge_lengths = compute_edges(faces)
    edge_len = min(edge_lengths)
    if any(abs(l - edge_len) > 1e-5 for l in edge_lengths):
        raise AssertionError("Edge lengths are not uniform.")

    areas = [polygon_area(order_face(f[2], f[0])) for f in faces]
    total_area = sum(areas)
    expected_area = (6.0 + 12.0 * math.sqrt(3.0)) * edge_len * edge_len
    assert_close(total_area, expected_area, 1e-5, "Surface area")

    volume = 0.0
    for n, _d, pts in faces:
        ordered = order_face(pts, n)
        face_normal = np.cross(ordered[1] - ordered[0], ordered[2] - ordered[0])
        if float(np.dot(face_normal, n)) < 0.0:
            ordered = list(reversed(ordered))
        p0 = ordered[0]
        for i in range(1, len(ordered) - 1):
            p1 = ordered[i]
            p2 = ordered[i + 1]
            volume += float(np.dot(p0, np.cross(p1, p2))) / 6.0
    volume = abs(volume)
    expected_volume = 8.0 * math.sqrt(2.0) * edge_len ** 3
    assert_close(volume, expected_volume, 1e-5, "Volume")

    for v in base_vertices:
        if abs(sdf_truncated_octahedron(v)) > 1e-6:
            raise AssertionError("SDF does not match vertex set.")
    if sdf_truncated_octahedron(np.array([0.0, 0.0, 0.0])) >= 0.0:
        raise AssertionError("SDF origin should be inside.")

    for chunk_size in chunk_sizes:
        total = chunk_size ** 3
        valid = 0
        for x in range(chunk_size):
            for y in range(chunk_size):
                for z in range(chunk_size):
                    if bcc_parity(x, y, z):
                        valid += 1
        expected = bcc_count_in_cube(chunk_size)
        if valid != expected:
            raise AssertionError("BCC parity count mismatch.")
        if chunk_size % 2 == 0:
            assert_close(valid, total / 4.0, 0.0, "BCC even chunk ratio")

    print("Truncated octahedron validation OK")
    print(f"edge_length={edge_len:.6f} area={total_area:.6f} volume={volume:.6f}")
    print("faces=14 squares=6 hexagons=8 vertices=24 neighbors=14")
    print(f"chunk_sizes={chunk_sizes}")


if __name__ == "__main__":
    main()
