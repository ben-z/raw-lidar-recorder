"""Synthetic contract tests; these do not substitute for an iPhone capture test."""
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location("read_capture", Path(__file__).parents[1] / "tools/read_capture.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Session = module.Session


def make_capture(root):
    folder = root / "frames/00000000"
    folder.mkdir(parents=True)
    def image(prefix, code, arrays):
        planes = []
        for i, array in enumerate(arrays):
            file = f"{prefix}_{i}.bin"
            raw = array.tobytes()
            (folder / file).write_bytes(raw)
            h, w = array.shape[:2]
            bpp = array.dtype.itemsize * (array.shape[2] if array.ndim == 3 else 1)
            planes.append(dict(file=file, width=w, height=h, bytesPerPixel=bpp,
                               rowBytes=w*bpp, sourceRowBytes=w*bpp+16, byteCount=len(raw)))
        return dict(pixelFormat=int.from_bytes(code.encode(), "big"), pixelFormatFourCC=code,
                    width=arrays[0].shape[1], height=arrays[0].shape[0], planes=planes,
                    attachments={"CVImageBufferYCbCrMatrix": "ITU_R_709_2"})
    depth = np.array([[2, 2], [np.nan, 0]], dtype="<f4")
    rgb = image("rgb", "420f", [np.full((4, 4), 100, dtype="u1"), np.full((2, 2, 2), 128, dtype="u1")])
    meta = dict(index=0, timestamp=100.0, path="frames/00000000", imageResolution=[4, 4],
                intrinsics=[[4, 0, 0], [0, 4, 0], [0, 0, 1]],
                cameraToWorld=[[1, 0, 0, 10], [0, 1, 0, 20], [0, 0, 1, 30], [0, 0, 0, 1]],
                rgb=rgb, depth=image("depth", "fdep", [depth]),
                confidence=image("confidence", "L008", [np.array([[2, 1], [0, 2]], dtype="u1")]),
                smoothedDepth=image("smoothed_depth", "hdep", [depth.astype("<f2")]))
    xyz = np.array([[1, 2, 3]], dtype="<f4")
    ids = np.array([2**63 + 123], dtype="<u8")
    (folder / "features_xyz.f32").write_bytes(xyz.tobytes())
    (folder / "features_ids.u64").write_bytes(ids.tobytes())
    meta["features"] = dict(count=1, xyz="features_xyz.f32", ids="features_ids.u64")
    (folder / "metadata.json").write_text(json.dumps(meta))
    manifest = dict(schema="raw-lidar/1", state="complete", frameCount=1, videoFormat=dict(fps=30))
    (root / "manifest.json").write_text(json.dumps(manifest))
    (root / "frames.jsonl").write_text(json.dumps(dict(index=0, timestamp=100.0, path="frames/00000000"))+"\n")
    (root / "motion.jsonl").write_text('{"sensor":"gyro","timestamp":100.0,"rad_s":[0,0,0]}\n')
    (root / "events.jsonl").write_text("")


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "session"
        make_capture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_depth_confidence_and_uint64_fidelity(self):
        with Session(self.root) as session:
            frame = session.frame(0)
            np.testing.assert_equal(frame.depth(), [[2, 2], [np.nan, 0]])
            np.testing.assert_equal(frame.depth(smoothed=True), frame.depth())
            self.assertEqual(frame.features()[1][0], 2**63 + 123)
            self.assertEqual(session.validate()["frames"], 1)

    def test_intrinsics_scaling_axes_and_world_transform(self):
        with Session(self.root) as session:
            frame = session.frame(0)
            np.testing.assert_allclose(frame.intrinsics(2, 2), np.diag([2, 2, 1]))
            np.testing.assert_allclose(frame.point_cloud(world=False), [[0, 0, -2], [1, 0, -2]])
            np.testing.assert_allclose(frame.point_cloud(), [[10, 20, 28], [11, 20, 28]])
            np.testing.assert_allclose(frame.point_cloud(min_confidence=2), [[10, 20, 28]])

    def test_native_ycbcr_planes_and_neutral_rgb_conversion(self):
        with Session(self.root) as session:
            frame = session.frame(0)
            self.assertEqual(frame.planes("rgb")[1].shape, (2, 2, 2))
            np.testing.assert_equal(frame.rgb(), np.full((4, 4, 3), 100, dtype="u1"))

    def test_declared_context_stream_preserves_location_values(self):
        manifest_path = self.root / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["context"] = {"file": "context.jsonl"}
        manifest_path.write_text(json.dumps(manifest))
        record = {"sensor": "location", "timestamp": 100.25, "timestampUnix": 1800000000.25,
                  "latitudeDegrees": 37.5, "longitudeDegrees": -122.5,
                  "speedMetersPerSecond": -1, "horizontalAccuracyMeters": 10}
        (self.root / "context.jsonl").write_text(json.dumps(record) + "\n")
        with Session(self.root) as session:
            self.assertEqual(session.validate()["contextSamples"], 1)
            self.assertEqual(list(session.records("context.jsonl")), [record])
        archive_path = Path(self.temp.name) / "context.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            for path in self.root.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(self.root))
        with Session(archive_path) as session:
            self.assertEqual(session.validate()["contextSamples"], 1)
            self.assertEqual(list(session.records("context.jsonl")), [record])
        (self.root / "context.jsonl").unlink()
        with Session(self.root) as session:
            with self.assertRaises(FileNotFoundError):
                session.validate()

    def test_invalid_context_record_is_rejected(self):
        path = self.root / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["context"] = {"file": "context.jsonl"}
        path.write_text(json.dumps(manifest))
        for sensor, stamp in [(123, 100.0), ("location", float("nan"))]:
            (self.root / "context.jsonl").write_text(json.dumps({"sensor": sensor, "timestamp": stamp}) + "\n")
            with Session(self.root) as session:
                with self.assertRaisesRegex(ValueError, "sensor name and finite timestamp"):
                    session.validate()

    def test_zip_with_and_without_enclosing_folder(self):
        for prefix in ("", "session/"):
            zip_path = Path(self.temp.name) / "capture.zip"
            with zipfile.ZipFile(zip_path, "w") as archive:
                for path in self.root.rglob("*"):
                    if path.is_file():
                        archive.write(path, prefix + path.relative_to(self.root).as_posix())
            with Session(zip_path) as session:
                self.assertEqual(session.validate()["motionSamples"], 1)
                np.testing.assert_allclose(session.frame(0).point_cloud()[0], [10, 20, 28])

    def test_partial_index_tail_is_recoverable(self):
        with (self.root / "frames.jsonl").open("ab") as file:
            file.write(b'{"index":1,')
        with Session(self.root) as session:
            self.assertEqual(session.validate()["frames"], 1)
            with self.assertRaises(IndexError):
                session.frame(1)

    def test_corrupt_plane_is_rejected(self):
        (self.root / "frames/00000000/depth_0.bin").write_bytes(b"bad")
        with Session(self.root) as session:
            with self.assertRaisesRegex(ValueError, "byte length"):
                session.validate()

    def test_missing_confidence_requires_explicit_override(self):
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        del meta["confidence"]
        path.write_text(json.dumps(meta))
        with Session(self.root) as session:
            with self.assertRaisesRegex(ValueError, "Confidence unavailable"):
                session.frame(0).point_cloud()
            self.assertEqual(len(session.frame(0).point_cloud(min_confidence=0)), 2)

    def test_paths_cannot_escape_session(self):
        with Session(self.root) as session:
            for path in ("../secret", "/etc/passwd", "..\\secret"):
                with self.assertRaises(ValueError):
                    session.read(path)

    def test_streaming_frames_uses_committed_index(self):
        with Session(self.root) as session:
            frames = list(session.frames())
            self.assertEqual(len(frames), 1)
            self.assertEqual(frames[0].metadata["index"], 0)

    def test_index_and_frame_disagreement_is_rejected(self):
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        meta["timestamp"] += 1
        path.write_text(json.dumps(meta))
        with Session(self.root) as session:
            with self.assertRaisesRegex(ValueError, "disagrees"):
                session.frame(0)

    def test_invalid_calibration_is_rejected(self):
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        meta["intrinsics"] = [[0, 0, 0]] * 3
        path.write_text(json.dumps(meta))
        with Session(self.root) as session:
            with self.assertRaisesRegex(ValueError, "invertible"):
                session.validate()

    def test_vertical_axis_and_rotated_camera_pose(self):
        # Only the lower-left depth pixel is valid. Rotate camera x/y by +90deg.
        path = self.root / "frames/00000000/depth_0.bin"
        path.write_bytes(np.array([[0, 0], [2, 0]], dtype="<f4").tobytes())
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        meta["cameraToWorld"] = [[0, -1, 0, 10], [1, 0, 0, 20], [0, 0, 1, 30], [0, 0, 0, 1]]
        path.write_text(json.dumps(meta))
        with Session(self.root) as session:
            frame = session.frame(0)
            np.testing.assert_allclose(frame.point_cloud(min_confidence=0, world=False), [[0, -1, -2]])
            np.testing.assert_allclose(frame.point_cloud(min_confidence=0), [[11, 20, 28]])

    def test_video_range_ycbcr_black_and_white(self):
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        meta["rgb"]["pixelFormat"] = int.from_bytes(b"420v", "big")
        meta["rgb"]["pixelFormatFourCC"] = "420v"
        path.write_text(json.dumps(meta))
        y = np.full((4, 4), 16, dtype="u1")
        y[2:, :] = 235
        (path.parent / "rgb_0.bin").write_bytes(y.tobytes())
        with Session(self.root) as session:
            rgb = session.frame(0).rgb()
            np.testing.assert_equal(rgb[:2], 0)
            np.testing.assert_equal(rgb[2:], 255)


if __name__ == "__main__":
    unittest.main()
