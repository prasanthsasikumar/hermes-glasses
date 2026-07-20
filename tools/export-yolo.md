# Exporting the Lens YOLO model

`HermesGlasses/Models/yolo11n.mlpackage` is a committed artifact so builds
are reproducible without Python. To regenerate (e.g. to bump model size):

    python3 -m venv yolo-env
    yolo-env/bin/pip install ultralytics coremltools
    yolo-env/bin/yolo export model=yolo11n.pt format=coreml nms=True imgsz=640

- `nms=True` matters: it wraps the model in a Vision-compatible pipeline
  (NMS included), so `VNCoreMLRequest` yields `VNRecognizedObjectObservation`
  with labels + bounding boxes directly.
- Copy the resulting `yolo11n.mlpackage` over
  `HermesGlasses/Models/yolo11n.mlpackage`.
- `ObjectDetector` loads the compiled model by name: keep the file name
  `yolo11n` or update `ObjectDetector.modelName` to match.
- Classes: COCO 80.
