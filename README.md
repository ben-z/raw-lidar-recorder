# Raw LiDAR Recorder

A minimal, local-only iOS recorder: **Record → Stop → Export ZIP**.
No account, backend, cloud SDK, or third-party iOS dependencies.

## Install on your iPhone

1. Download or clone this project on a Mac with **Xcode 16 or later**.
2. Open **RawLiDAR.xcodeproj**. Select the **RawLiDAR** scheme.
3. In the target's **Signing & Capabilities**, choose your development team and
   change `com.example.RawLiDAR` to your own unique bundle identifier.
4. Connect a **LiDAR-equipped iPhone/iPad running iOS/iPadOS 17 or later**.
   Enable Developer Mode if prompted. Select that device and press **Run**.
5. Choose camera, location, and motion permissions before recording. Record a
   5–10 second test, stop, and export.

An Apple ID personal team can be used for local development; Apple's provisioning
restrictions apply. A physical device is required to test LiDAR. This download
is source code, not a signed IPA, TestFlight build, or App Store installation.

## Use

- Tap **Record**, move the phone, then tap **Stop**.
- Tap **Export latest**, then AirDrop the ZIP or choose **Save to Files**.
- The folder button lists previous recordings and exports any selected one.
- Originals are also visible in **Files → On My iPhone → Raw LiDAR → Recordings**
  and through Finder file sharing. Copy a session directly for very large captures.
- The app stops recording when it leaves the foreground, is interrupted, or runs
  low on storage. Start a new session when you return.
- To reclaim storage, delete copied recordings from Files. Export ZIP copies in
  the app's temporary storage are replaced on the next export; iOS may also
  clear temporary files.

The app deliberately has no room-layout processing or reconstruction UI.

## Captured data

| Stream | Stored representation |
|---|---|
| Camera image | Original native YCbCr planes, uncompressed; row padding removed |
| Scene depth | Original `sceneDepth.depthMap` pixel values; floating-point meters |
| Depth confidence | Original confidence bytes, when available |
| Smoothed depth | `smoothedSceneDepth` and its confidence, when supported/available |
| Camera pose | Per-frame ARKit camera-to-world 4×4 transform |
| Calibration | Intrinsics, reference image size, pixel format, plane dimensions, row layout, pixel-buffer attachments |
| Frame metadata | Timestamp, EXIF, exposure, tracking state, mapping status, lighting estimate |
| SLAM features | XYZ float32 and uint64 landmark IDs; distinct from LiDAR returns |
| Motion sensors | Individually timestamped accelerometer, gyroscope, and magnetometer samples |
| Fused motion | Core Motion attitude, gravity, user acceleration, angular velocity, magnetic field and accuracy |
| Altimeter | Barometric pressure in kPa, relative altitude in meters, and absolute altitude with reported accuracy/precision when supported |
| Location | Core Location latitude/longitude, mean-sea-level and ellipsoidal altitude, accuracy, speed, course, floor/source information when provided |
| Compass | Magnetic/true heading, accuracy, and magnetic vector in portrait device axes |
| Device context | Battery level/state, thermal state, low-power mode, and device orientation at start and on changes |
| Session metadata | Device identifier, OS, selected video format, sensor availability, timestamps, counts, timing gaps, stop reason |

**“Raw” means the values exposed by Apple's public APIs, saved without our own
filtering or lossy encoding.** Camera data has Apple's image processing; depth
has Apple's fusion/estimation. Original LiDAR time-of-flight returns, raw Bayer
camera frames, Apple-internal IMU samples, and camera-to-IMU extrinsics are not
provided by this recorder. Motion is Core Motion's exposed data, with its own
rates/calibration. Location is a fused Core Location estimate, not raw GNSS
satellite observations. Denied access and acquisition errors are logged; sensor
availability and location authorization are included in the manifest. Audio,
meshes, segmentation, and room objects are
outside this RGB-D/pose/IMU recorder's scope.

This is an **ARKit recorder**, chosen to keep camera pose and RGB-D together.
It is not a separate AVFoundation unfiltered-depth capture mode; those pipelines
are not assumed to operate simultaneously on the same rear camera.

## Code structure

`ContentView` provides the controls and camera preview. `Recorder` owns UI state
on the main actor. `CaptureEngine` owns the ARSession and disk writer on a serial
queue, while `MotionRecorder` delivers timestamped sensor events on that queue.
`SessionWriter` defines the recording format; `ArchiveExporter` creates ZIPs.

Every recording and motion subscription has an identity. Old callbacks cannot
write into a later session, and stopping a session twice has no effect. Export
presentation follows sheet dismissal instead of an animation timer. Each export
gets a fresh staging directory, with failed staging removed automatically.
Recording and ZIP creation keep the screen awake. Switching away can suspend
ZIP creation; keep the app foregrounded or copy the recording through Finder.

## Storage and timing

The app selects the smallest native ARKit camera format at ≤30 fps if available,
otherwise the smallest available format. It preserves every callback's buffers
at that format. The actual selection is written to `manifest.json`.

Raw camera frames are large: a 1920×1440 NV12 image is about 4.15 MB, or about
124 MB/s at 30 fps before depth, confidence, features and metadata. That example
is **roughly 7.5 GB/minute**. Check your actual device format and start short.
Export requires additional free space for a ZIP and system staging; direct
Files/Finder copying avoids ZIP staging for long recordings. File sizes shown
in-app count payload bytes written, not filesystem allocation.

ARKit callbacks and motion handlers use one serial writer queue. A frame is
written synchronously and released; the app does not retain an unbounded queue
of ARFrames. Storage throughput, thermals, and ARKit can still limit delivery.
Timestamp gaps over 1.5 nominal frame intervals are counted in the manifest;
these indicate delivery gaps, not an exact hardware dropped-frame counter.
Motion requests 100 Hz; actual sample rates and timestamps are authoritative.

ARFrame and Core Motion timestamps are boot-relative seconds. No interpolation
or synchronization correction is applied. Scene depth is associated with the
ARFrame timestamp; ARKit doesn't expose a separate scene-depth acquisition
timestamp here. `capturedDepthDataTimestamp` belongs to the front TrueDepth
pipeline and is deliberately not used as a rear LiDAR timestamp.

Each frame's files are written before its index entry. Files are periodically
flushed. If the app is killed, previously committed frames remain readable;
ignore unindexed folders and a partial final JSONL line. An unfinished manifest
will still say `state: recording`. Sudden termination can lose recent unflushed
writes. The app never resumes an old session or silently changes its world origin.

## Export format

Every session contains:

- `manifest.json`: versioned schema and session summary.
- `frames.jsonl`: one committed frame index entry per line.
- `motion.jsonl`: one timestamped sensor sample per line.
- `events.jsonl`: motion acquisition errors, if any.
- `context.jsonl`: location, heading, authorization, and device-state records in
  recordings made by build 2 or later; its path is declared in `manifest.context`.
- `FORMAT.txt`: compact format notes included in each exported recording.
- `frames/00000000/metadata.json`: paths and layout for that frame's files.
- Binary plane files, and optional `features_xyz.f32` / `features_ids.u64`.

Read sizes, formats and filenames from metadata rather than assuming a camera
or depth resolution. All binary numbers are little-endian. Matrices are JSON
arrays of **rows**, not Swift SIMD columns. Camera poses are estimates, not
ground truth; inspect `tracking` before using them.

Depth is axial z in meters. Use intrinsics scaled from `imageResolution` to
the depth image size. Unproject CV camera coordinates with `K^-1 [u,v,1] * z`,
then convert to ARKit camera axes with `diag(1,-1,-1)`, then apply
`cameraToWorld`. No screen rotation or mirroring is applied to stored images.
Confidence is 0=low, 1=medium, 2=high. Invalid depth values are preserved.
Core Motion vectors use device axes, not necessarily camera axes. Quaternion
order is x,y,z,w; attitude uses the `xArbitraryZVertical` reference frame and
is not interchangeable with ARKit's camera pose.

Altimeter sample rates are controlled by Core Motion. Location and heading retain
their original Unix timestamps, a boot-time estimate using a fixed session clock
offset, and the boot-relative callback arrival time. Initial cached fixes and
negative accuracy/speed/course sentinel values are preserved. Inspect reported
accuracy and timestamps before use. Location does not automatically georeference
the ARKit world; its yaw remains arbitrary. Sensor JSONL preserves callback order,
so sort by timestamp when combining streams. Fused magnetic fields with accuracy
`-1` are unavailable/uncalibrated, even when their vector contains zeros.

## Python postprocessing

Install `numpy`, then use the included reader directly on a folder **or ZIP**:

```sh
python3 -m pip install -r requirements.txt
python3 tools/read_capture.py /path/to/session.zip --validate
python3 tools/read_capture.py /path/to/session.zip --frame 0 --output frame.npz --ply frame.ply
```

`--validate` reads all committed frames, checks plane sizes and feature counts,
and reports missing depth, timing gaps, and motion sample counts. `.npz` contains
native image planes, depth/confidence, intrinsics and camera-to-world transform.
PLY contains XYZ world points with medium-or-higher confidence by default.
Use `--min-confidence 2` for high confidence only, or `0` to accept all positive
finite depths. It does not integrate frames or compensate pose drift.

```python
from tools.read_capture import Session

with Session("session.zip") as session:
    frame = session.frame(0)
    depth = frame.depth()                 # meters; original float buffer
    y_plane, cbcr_plane = frame.planes("rgb")
    rgb_preview = frame.rgb()             # optional YCbCr -> RGB convenience conversion
    xyz_world = frame.point_cloud(min_confidence=2)
    imu_samples = list(session.records("motion.jsonl"))

    # For long recordings, scan the index once instead of calling frame(i) repeatedly.
    for frame in session.frames():
        timestamp = frame.metadata["timestamp"]
```

The preview conversion honors NV12 range and common 601/709/2020 YCbCr matrices;
it is not a full color-managed ICC/transfer-function conversion. Use original
planes and attachments for a precise image-processing pipeline.

## Validation status

The Python reader has synthetic tests for binary fidelity (including nonfinite
depth and large uint64 IDs), calibration scaling, camera/world axes, confidence
filtering, YCbCr conversion, ZIP/folder reading, corrupt buffers and interrupted
index recovery, plus declared context streams in folders and ZIPs. Run
`python3 -m unittest discover -s tests -v`.

The included GitHub Actions workflow runs these tests and an unsigned iOS build
on macOS. It also compiles the production JSON helpers and ZIP exporter into a
small integration test, with Python independently checking the ZIP payloads.
The first [CI run](https://github.com/ben-z/raw-lidar-recorder/actions/runs/41979132276)
passed with Xcode 26.6: the unsigned iOS target built successfully, the production
JSON/ZIP integration checks passed, and all 13 Python tests passed.

Build 1 was signed, installed, and launched on an iPhone 12 Pro running iOS 26.6.
A 39-second hardware recording contained 1,172 camera frames and 15,658 motion
samples, with no frame timing gaps or acquisition errors. Three startup frames
lacked depth; the remaining frames had raw/smoothed depth and confidence. The
folder and a ZIP created on the Mac with the production exporter validated. This
does not establish sustained throughput, ground-truth depth/pose accuracy, or
on-phone ZIP completion. The additional build-2 location, heading, altitude, and
device-context streams still require a new hardware recording to validate.
Before using important data:

1. Confirm depth/confidence files exist and `--validate` passes.
2. Point at a flat wall; compare depth to a known distance and inspect the PLY.
3. Rotate/move the device; inspect pose axes and timestamp alignment.
4. Stop, background, relaunch, and export a previous session.
5. Test permission denial and a longer recording for storage/timing limits.

For an unsigned build check on a Mac:

```sh
xcodebuild -project RawLiDAR.xcodeproj -scheme RawLiDAR \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Apple references

- [ARFrame](https://developer.apple.com/documentation/arkit/arframe)
- [ARDepthData](https://developer.apple.com/documentation/arkit/ardepthdata)
- [Point cloud from scene depth](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth)
- [ARKit video formats](https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class)
- [Core Motion](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
- [Foundation ZIP snapshots](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading)
