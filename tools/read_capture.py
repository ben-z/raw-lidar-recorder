#!/usr/bin/env python3
"""Read Raw LiDAR folders / ZIPs without extracting the entire recording.

Requires Python 3.10+ and numpy. No Apple SDK or proprietary format dependencies.
"""
from __future__ import annotations

import argparse
import json
import sys
import zipfile
from pathlib import Path, PurePosixPath

import numpy as np


class Session:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.archive = None
        if self.path.is_file():
            self.archive = zipfile.ZipFile(self.path)
            candidates = [n for n in self.archive.namelist()
                          if PurePosixPath(n).name == "manifest.json" and not n.startswith("__MACOSX/")]
            if len(candidates) != 1:
                self.archive.close()
                raise ValueError("ZIP must contain exactly one session manifest.json")
            self.prefix = candidates[0][:-len("manifest.json")]
        else:
            if not (self.path / "manifest.json").is_file():
                candidates = list(self.path.glob("*/manifest.json"))
                if len(candidates) != 1:
                    raise ValueError("Choose a specific recording folder containing manifest.json")
                self.path = candidates[0].parent
            self.prefix = ""
        try:
            self.manifest = self.json("manifest.json")
            if self.manifest.get("schema") != "raw-lidar/1":
                raise ValueError("Unsupported capture schema")
        except Exception:
            self.close()
            raise

    def close(self):
        if self.archive is not None:
            self.archive.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def open(self, relative: str):
        # Treat paths inside captures as relative, even for local folder reads.
        parts = PurePosixPath(relative)
        if parts.is_absolute() or ".." in parts.parts or "\\" in relative:
            raise ValueError("Invalid relative capture path")
        if self.archive is not None:
            return self.archive.open(self.prefix + relative)
        target = (self.path / relative).resolve()
        if not target.is_relative_to(self.path.resolve()):
            raise ValueError("Capture path escapes recording folder")
        return target.open("rb")

    def read(self, relative: str) -> bytes:
        with self.open(relative) as file:
            return file.read()

    def json(self, relative: str):
        return json.loads(self.read(relative))

    def records(self, name: str):
        with self.open(name) as file:
            for line in file:
                if not line.endswith(b"\n"):
                    # A killed process can leave one incomplete final JSONL record.
                    return
                if line.strip():
                    yield json.loads(line)

    def frame(self, index: int):
        # Resolve via the committed index so an incomplete frame is never returned.
        for entry in self.records("frames.jsonl"):
            if entry["index"] == index:
                return self._frame_from_entry(entry)
        raise IndexError(f"No committed frame {index}")

    def frames(self):
        """Stream committed frames in order without repeatedly scanning the index."""
        for entry in self.records("frames.jsonl"):
            yield self._frame_from_entry(entry)

    def _frame_from_entry(self, entry):
        frame = Frame(self, entry["path"])
        if frame.metadata["timestamp"] != entry["timestamp"] or frame.metadata["index"] != entry["index"]:
            raise ValueError("Frame metadata disagrees with committed index")
        return frame

    def validate(self) -> dict:
        count, missing_depth, gaps = 0, 0, 0
        previous = None
        last_index = -1
        fps = self.manifest["videoFormat"]["fps"]
        for frame in self.frames():
            meta = frame.metadata
            if meta["index"] != last_index + 1:
                raise ValueError("Non-contiguous committed frame indices")
            frame.intrinsics(*meta["imageResolution"])
            transform = np.asarray(meta["cameraToWorld"], dtype=np.float64)
            if transform.shape != (4, 4) or not np.isfinite(transform).all():
                raise ValueError("Camera pose must be a finite 4x4 matrix")
            for key in ("rgb", "depth", "confidence", "smoothedDepth", "smoothedConfidence"):
                if key in frame.metadata:
                    frame.planes(key)  # Checks lengths, shapes and declared pixel type.
            if "features" in frame.metadata:
                xyz, ids = frame.features()
                if len(xyz) != len(ids):
                    raise ValueError("Feature coordinate / ID count mismatch")
            if "depth" not in frame.metadata:
                missing_depth += 1
            stamp = meta["timestamp"]
            if previous is not None:
                if stamp <= previous:
                    raise ValueError("Frame timestamps must increase")
                if stamp - previous > 1.5 / fps:
                    gaps += 1
            previous, last_index = stamp, meta["index"]
            count += 1
        if self.manifest["state"] != "recording" and self.manifest["frameCount"] != count:
            raise ValueError("Manifest frame count disagrees with index")
        motion_count = sum(1 for _ in self.records("motion.jsonl"))
        event_count = sum(1 for _ in self.records("events.jsonl"))
        result = {"frames": count, "framesWithoutDepth": missing_depth,
                  "timingGaps": gaps, "motionSamples": motion_count, "events": event_count}
        if "context" in self.manifest:
            context_count = 0
            for record in self.records(self.manifest["context"]["file"]):
                if not isinstance(record["sensor"], str) or not np.isfinite(record["timestamp"]):
                    raise ValueError("Context records need a sensor name and finite timestamp")
                context_count += 1
            result["contextSamples"] = context_count
        return result


class Frame:
    def __init__(self, session: Session, path: str):
        self.session, self.path = session, path
        self.metadata = session.json(f"{path}/metadata.json")

    def planes(self, key: str):
        item = self.metadata[key]
        code = item["pixelFormat"]
        def fourcc(value):
            return int.from_bytes(value.encode("ascii"), "big")
        dtype = {fourcc("fdep"): "<f4", fourcc("hdep"): "<f2",
                 fourcc("L008"): "u1", fourcc("420f"): "u1",
                 fourcc("420v"): "u1", fourcc("BGRA"): "u1"}.get(code)
        if dtype is None:
            raise ValueError(f"Unsupported pixel format {code}")
        arrays = []
        for plane in item["planes"]:
            raw = self.session.read(f"{self.path}/{plane['file']}")
            expected = plane["rowBytes"] * plane["height"]
            if len(raw) != expected or len(raw) != plane["byteCount"]:
                raise ValueError(f"Incorrect byte length: {self.path}/{plane['file']}")
            dt = np.dtype(dtype)
            channels = plane["bytesPerPixel"] // dt.itemsize
            if channels < 1 or plane["rowBytes"] != plane["width"] * channels * dt.itemsize:
                raise ValueError("Invalid packed plane layout")
            shape = (plane["height"], plane["width"])
            if channels > 1:
                shape += (channels,)
            arrays.append(np.frombuffer(raw, dtype=dt).reshape(shape))
        return arrays

    def depth(self, smoothed=False):
        return self.planes("smoothedDepth" if smoothed else "depth")[0]

    def confidence(self, smoothed=False):
        return self.planes("smoothedConfidence" if smoothed else "confidence")[0]

    def features(self):
        item = self.metadata["features"]
        xyz = np.frombuffer(self.session.read(f"{self.path}/{item['xyz']}"), dtype="<f4").reshape(-1, 3)
        ids = np.frombuffer(self.session.read(f"{self.path}/{item['ids']}"), dtype="<u8")
        if len(xyz) != item["count"] or len(ids) != item["count"]:
            raise ValueError("Feature byte count does not match metadata")
        return xyz, ids

    def intrinsics(self, width: int, height: int):
        k = np.asarray(self.metadata["intrinsics"], dtype=np.float64).copy()
        reference_w, reference_h = self.metadata["imageResolution"]
        if min(width, height, reference_w, reference_h) <= 0:
            raise ValueError("Image dimensions must be positive")
        if k.shape != (3, 3) or not np.isfinite(k).all() or abs(np.linalg.det(k)) < 1e-12:
            raise ValueError("Intrinsics must be a finite, invertible 3x3 matrix")
        k[0, :] *= width / reference_w
        k[1, :] *= height / reference_h
        return k

    def point_cloud(self, min_confidence=1, world=True, smoothed=False):
        depth = self.depth(smoothed).astype(np.float64)
        height, width = depth.shape
        k = self.intrinsics(width, height)
        u, v = np.meshgrid(np.arange(width), np.arange(height))
        rays = np.stack((u, v, np.ones_like(u)), axis=-1) @ np.linalg.inv(k).T
        # Depth is optical-axis z, not Euclidean range along a unit ray.
        xyz = rays * depth[..., None]
        valid = np.isfinite(depth) & (depth > 0)
        confidence_key = "smoothedConfidence" if smoothed else "confidence"
        if min_confidence > 0:
            if confidence_key not in self.metadata:
                raise ValueError("Confidence unavailable; pass min_confidence=0 to use positive finite depth")
            valid &= self.confidence(smoothed) >= min_confidence
        xyz = xyz[valid] * np.array([1, -1, -1])  # CV camera -> ARKit camera axes
        if world:
            transform = np.asarray(self.metadata["cameraToWorld"], dtype=np.float64)
            xyz = xyz @ transform[:3, :3].T + transform[:3, 3]
        return xyz

    def rgb(self):
        """Convenience RGB preview conversion. Original YCbCr planes stay unchanged."""
        item = self.metadata["rgb"]
        planes = self.planes("rgb")
        if item["pixelFormatFourCC"] == "BGRA":
            return planes[0][..., [2, 1, 0]].copy()
        if item["pixelFormatFourCC"] not in ("420f", "420v"):
            raise ValueError("RGB preview supports NV12 or BGRA")
        y = planes[0].astype(np.float64)
        uv = planes[1].repeat(2, axis=0).repeat(2, axis=1)[:y.shape[0], :y.shape[1]].astype(np.float64)
        cb, cr = uv[..., 0] - 128, uv[..., 1] - 128
        if item["pixelFormatFourCC"] == "420v":
            y = (y - 16) * (255 / 219)
            cb *= 255 / 224
            cr *= 255 / 224
        matrix = str(item["attachments"].get("CVImageBufferYCbCrMatrix", ""))
        if "709" in matrix:
            kr, kb = 0.2126, 0.0722
        elif "601" in matrix:
            kr, kb = 0.299, 0.114
        elif "2020" in matrix:
            kr, kb = 0.2627, 0.0593
        else:
            raise ValueError("Missing/unknown YCbCrMatrix attachment; use raw planes or supply a color conversion")
        kg = 1 - kr - kb
        r = y + 2 * (1 - kr) * cr
        b = y + 2 * (1 - kb) * cb
        g = (y - kr * r - kb * b) / kg
        return np.clip(np.stack((r, g, b), axis=-1), 0, 255).round().astype(np.uint8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="Recording folder or exported ZIP")
    parser.add_argument("--validate", action="store_true", help="Read and check every committed frame")
    parser.add_argument("--frame", type=int, help="Frame to export as a NumPy .npz file")
    parser.add_argument("--output", type=Path, default=Path("frame.npz"))
    parser.add_argument("--ply", type=Path, help="Also write the selected frame as world-space XYZ PLY")
    parser.add_argument("--min-confidence", type=int, choices=(0, 1, 2), default=1)
    args = parser.parse_args()
    if args.ply and args.frame is None:
        parser.error("--ply requires --frame")
    with Session(args.capture) as session:
        print(json.dumps(session.manifest, indent=2))
        if args.validate:
            print("Validated:", json.dumps(session.validate()))
        if args.frame is not None:
            frame = session.frame(args.frame)
            arrays = {
                "intrinsics": np.asarray(frame.metadata["intrinsics"]),
                "camera_to_world": np.asarray(frame.metadata["cameraToWorld"]),
                "timestamp": np.asarray(frame.metadata["timestamp"]),
            }
            for key in ("rgb", "depth", "confidence", "smoothedDepth", "smoothedConfidence"):
                if key in frame.metadata:
                    for i, plane in enumerate(frame.planes(key)):
                        arrays[f"{key}_{i}"] = plane
            if "features" in frame.metadata:
                arrays["features_xyz"], arrays["features_ids"] = frame.features()
            if "depth" in frame.metadata:
                arrays["depth_intrinsics"] = frame.intrinsics(*frame.depth().shape[::-1])
            np.savez(args.output, **arrays)
            print("Wrote", args.output)
            if args.ply:
                points = frame.point_cloud(min_confidence=args.min_confidence)
                with args.ply.open("w") as file:
                    file.write(f"ply\nformat ascii 1.0\nelement vertex {len(points)}\n")
                    file.write("property float x\nproperty float y\nproperty float z\nend_header\n")
                    np.savetxt(file, points, fmt="%.8g")
                print("Wrote", args.ply)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, IndexError, zipfile.BadZipFile) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
