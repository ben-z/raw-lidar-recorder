"""Synthetic contract tests; these do not substitute for an iPhone capture test."""
import importlib.util
import json
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location("read_capture", Path(__file__).parents[1] / "tools/read_capture.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Session = module.Session


def write_image(folder, prefix, code, arrays):
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


def compress_capture(root, predictor):
    path = root / "frames/00000000/metadata.json"
    meta = json.loads(path.read_text())
    for key in ("rgb", "depth", "confidence", "smoothedDepth", "smoothedConfidence"):
        if key not in meta:
            continue
        for plane in meta[key]["planes"]:
            original = path.parent / plane["file"]
            values = np.frombuffer(original.read_bytes(), dtype="u1")
            if predictor == "up":
                rows = values.reshape(plane["height"], plane["rowBytes"])
                filtered = rows.copy()
                filtered[1:] = rows[1:] - rows[:-1]
            elif predictor == "byte-shuffle":
                filtered = values.reshape(-1, plane["bytesPerPixel"]).T.copy()
            else:
                raise ValueError(predictor)
            encoded = zlib.compress(filtered.tobytes(), level=1)
            plane["file"] += ".zlib"
            plane.update(encoding="zlib", predictor=predictor, storedByteCount=len(encoded))
            (path.parent / plane["file"]).write_bytes(encoded)
            original.unlink()
    path.write_text(json.dumps(meta))
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["schema"] = "raw-lidar/2"
    manifest_path.write_text(json.dumps(manifest))


def make_capture(root):
    folder = root / "frames/00000000"
    folder.mkdir(parents=True)
    depth = np.array([[2, 2], [np.nan, 0]], dtype="<f4")
    rgb = write_image(folder, "rgb", "420f", [np.full((4, 4), 100, dtype="u1"), np.full((2, 2, 2), 128, dtype="u1")])
    meta = dict(index=0, timestamp=100.0, path="frames/00000000", imageResolution=[4, 4],
                intrinsics=[[4, 0, 0], [0, 4, 0], [0, 0, 1]],
                cameraToWorld=[[1, 0, 0, 10], [0, 1, 0, 20], [0, 0, 1, 30], [0, 0, 0, 1]],
                rgb=rgb, depth=write_image(folder, "depth", "fdep", [depth]),
                confidence=write_image(folder, "confidence", "L008", [np.array([[2, 1], [0, 2]], dtype="u1")]),
                smoothedDepth=write_image(folder, "smoothed_depth", "hdep", [depth.astype("<f2")]))
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

    def test_compressed_planes_preserve_float_bits_and_uint64_ids(self):
        float32_bits = np.array([
            0x00000000, 0x80000000, 0x7f800000, 0xff800000,
            0x7fc12345, 0x7fc54321, 0x7fa12345, 0xffc12345,
            0x00000001, 0x80000001, 0x3f800347, 0x4780e800,
            0x7f7fffff, 0xff7fffff, 0x00800000, 0x80800000,
        ], dtype="<u4").reshape(4, 4)
        float16_bits = np.array([
            0x0000, 0x8000, 0x7c00, 0xfc00, 0x7e11, 0x7c01, 0xfe12, 0x0001,
            0x8001, 0x0400, 0x8400, 0x3c01, 0x7bff, 0xfbff, 0x3555, 0xb555,
        ], dtype="<u2").reshape(4, 4)
        feature_bits = float32_bits.reshape(-1)[:9].reshape(3, 3)
        feature_ids = np.array([0, 2**63 + 123, 2**64 - 1], dtype="<u8")
        for predictor in ("up", "byte-shuffle"):
            with self.subTest(predictor=predictor):
                root = Path(self.temp.name) / predictor
                make_capture(root)
                path = root / "frames/00000000/metadata.json"
                meta = json.loads(path.read_text())
                meta["depth"] = write_image(path.parent, "depth", "fdep", [float32_bits.view("<f4")])
                meta["smoothedDepth"] = write_image(path.parent, "smoothed_depth", "hdep", [float16_bits.view("<f2")])
                meta["features"]["count"] = 3
                (path.parent / meta["features"]["xyz"]).write_bytes(feature_bits.tobytes())
                (path.parent / meta["features"]["ids"]).write_bytes(feature_ids.tobytes())
                path.write_text(json.dumps(meta))
                compress_capture(root, predictor)
                with Session(root) as session:
                    frame = session.frame(0)
                    self.assertEqual(frame.depth().tobytes(), float32_bits.tobytes())
                    self.assertEqual(frame.depth(smoothed=True).tobytes(), float16_bits.tobytes())
                    xyz, ids = frame.features()
                    self.assertEqual(xyz.tobytes(), feature_bits.tobytes())
                    self.assertEqual(ids.tobytes(), feature_ids.tobytes())
                    self.assertEqual(session.validate()["frames"], 1)

    def test_compressed_nv12_planes_and_confidence_are_byte_exact(self):
        y = np.array([[255, 0, 128, 7], [0, 255, 1, 250],
                      [7, 0, 255, 127], [1, 2, 3, 4]], dtype="u1")
        uv = np.array([[[250, 0], [255, 128]], [[1, 255], [0, 7]]], dtype="u1")
        confidence = np.array([[0, 1], [2, 0]], dtype="u1")
        for predictor in ("up", "byte-shuffle"):
            with self.subTest(predictor=predictor):
                root = Path(self.temp.name) / predictor
                make_capture(root)
                path = root / "frames/00000000/metadata.json"
                meta = json.loads(path.read_text())
                meta["rgb"] = write_image(path.parent, "rgb", "420f", [y, uv])
                meta["confidence"] = write_image(path.parent, "confidence", "L008", [confidence])
                path.write_text(json.dumps(meta))
                compress_capture(root, predictor)
                with Session(root) as session:
                    frame = session.frame(0)
                    planes = frame.planes("rgb")
                    self.assertEqual([p.tobytes() for p in planes], [y.tobytes(), uv.tobytes()])
                    self.assertEqual(frame.confidence().tobytes(), confidence.tobytes())

    def test_compressed_bgra_preserves_all_channels(self):
        pixels = np.array([[[255, 0, 1, 128], [3, 254, 9, 0]],
                           [[0, 255, 127, 255], [128, 7, 0, 1]]], dtype="u1")
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        meta["rgb"] = write_image(path.parent, "rgb", "BGRA", [pixels])
        path.write_text(json.dumps(meta))
        compress_capture(self.root, "byte-shuffle")
        with Session(self.root) as session:
            frame = session.frame(0)
            self.assertEqual(frame.planes("rgb")[0].tobytes(), pixels.tobytes())
            np.testing.assert_array_equal(frame.rgb(), pixels[..., [2, 1, 0]])

    def test_compressed_capture_reads_from_zip(self):
        compress_capture(self.root, "up")
        for prefix in ("", "session/"):
            with self.subTest(prefix=prefix):
                archive_path = Path(self.temp.name) / "compressed.zip"
                with zipfile.ZipFile(archive_path, "w") as archive:
                    for path in self.root.rglob("*"):
                        if path.is_file():
                            archive.write(path, prefix + path.relative_to(self.root).as_posix())
                with Session(archive_path) as session:
                    self.assertEqual(session.validate()["frames"], 1)
                    self.assertEqual(session.frame(0).features()[1][0], 2**63 + 123)
                    np.testing.assert_equal(session.frame(0).depth(), [[2, 2], [np.nan, 0]])

    def test_compressed_capture_keeps_empty_feature_buffers_raw(self):
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        meta["features"]["count"] = 0
        for key in ("xyz", "ids"):
            (path.parent / meta["features"][key]).write_bytes(b"")
        path.write_text(json.dumps(meta))
        compress_capture(self.root, "up")
        with Session(self.root) as session:
            xyz, ids = session.frame(0).features()
            self.assertEqual(xyz.shape, (0, 3))
            self.assertEqual(ids.shape, (0,))
            self.assertEqual(session.validate()["frames"], 1)

    def test_compressed_plane_requires_explicit_storage_fields(self):
        compress_capture(self.root, "up")
        path = self.root / "frames/00000000/metadata.json"
        original = path.read_text()
        for field in ("encoding", "predictor", "storedByteCount"):
            with self.subTest(field=field):
                meta = json.loads(original)
                del meta["depth"]["planes"][0][field]
                path.write_text(json.dumps(meta))
                with Session(self.root) as session:
                    with self.assertRaisesRegex(ValueError, "Missing compressed plane fields.*" + field):
                        session.frame(0).depth()

    def test_compressed_plane_rejects_unknown_storage_fields(self):
        compress_capture(self.root, "up")
        path = self.root / "frames/00000000/metadata.json"
        original = path.read_text()
        for field, value, message in (("encoding", "gzip", "encoding"),
                                      ("predictor", "previous-frame", "predictor"),
                                      ("storedByteCount", -1, "positive integer"),
                                      ("storedByteCount", True, "positive integer"),
                                      ("storedByteCount", 1000, "stored byte length")):
            with self.subTest(field=field, value=value):
                meta = json.loads(original)
                meta["depth"]["planes"][0][field] = value
                path.write_text(json.dumps(meta))
                with Session(self.root) as session:
                    with self.assertRaisesRegex(ValueError, message):
                        session.frame(0).depth()

    def test_compressed_plane_validates_layout_before_decoding(self):
        compress_capture(self.root, "up")
        path = self.root / "frames/00000000/metadata.json"
        original = path.read_text()
        meta = json.loads(original)
        (path.parent / meta["depth"]["planes"][0]["file"]).write_bytes(b"not zlib")
        for field, value in (("width", 0), ("height", -1), ("rowBytes", 7),
                             ("byteCount", 15), ("bytesPerPixel", 3), ("height", True)):
            with self.subTest(field=field, value=value):
                meta = json.loads(original)
                meta["depth"]["planes"][0][field] = value
                path.write_text(json.dumps(meta))
                with Session(self.root) as session:
                    with self.assertRaisesRegex(ValueError, "packed plane layout"):
                        session.frame(0).depth()

    def test_compressed_plane_rejects_malformed_zlib_streams(self):
        compress_capture(self.root, "up")
        path = self.root / "frames/00000000/metadata.json"
        meta = json.loads(path.read_text())
        plane = meta["depth"]["planes"][0]
        target = path.parent / plane["file"]
        good = target.read_bytes()
        decoded = zlib.decompress(good)
        corrupt_checksum = good[:-1] + bytes([good[-1] ^ 1])
        cases = {
            "checksum": corrupt_checksum,
            "truncated trailer": good[:-1],
            "truncated payload": good[:len(good)//2],
            "trailing junk": good + b"junk",
            "concatenated stream": good + good,
            "short decoded payload": zlib.compress(decoded[:-1]),
            "oversized decoded payload": zlib.compress(decoded + b"x" * 2_000_000),
            "raw deflate without zlib wrapper": good[2:-4],
        }
        for name, data in cases.items():
            with self.subTest(case=name):
                target.write_bytes(data)
                plane["storedByteCount"] = len(data)
                path.write_text(json.dumps(meta))
                with Session(self.root) as session:
                    with self.assertRaisesRegex(ValueError, "zlib|decoded byte length"):
                        session.frame(0).depth()

    def test_schema_one_does_not_decode_compressed_metadata(self):
        compress_capture(self.root, "up")
        path = self.root / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["schema"] = "raw-lidar/1"
        path.write_text(json.dumps(manifest))
        with Session(self.root) as session:
            with self.assertRaisesRegex(ValueError, "requires raw-lidar/2"):
                session.frame(0).depth()

    def test_unknown_schema_is_rejected(self):
        path = self.root / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["schema"] = "raw-lidar/3"
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "Unsupported capture schema"):
            Session(self.root)


if __name__ == "__main__":
    unittest.main()
