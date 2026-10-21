import AVFoundation

enum CameraError: LocalizedError {
    case notAuthorized
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access was denied. Enable it in Settings › CatWatch."
        case .noCamera: return "No suitable back camera found."
        case .cannotAddInput: return "Could not attach the camera to the capture session."
        case .cannotAddOutput: return "Could not attach the video output."
        }
    }
}

/// Owns the capture session and delivers portrait-oriented BGRA frames on a background queue.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Called on the video queue for every frame. Keep it fast or drop frames.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "catwatch.camera.session")
    private let videoQueue = DispatchQueue(label: "catwatch.camera.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var configuredUltraWide: Bool?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(useUltraWide: Bool, completion: @escaping (Error?) -> Void) {
        sessionQueue.async { [self] in
            do {
                if configuredUltraWide != useUltraWide {
                    try configure(useUltraWide: useUltraWide)
                }
                if !session.isRunning { session.startRunning() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(useUltraWide: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.sessionPreset = .hd1920x1080

        let device = (useUltraWide ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : nil)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device else { throw CameraError.noCamera }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        try device.lockForConfiguration()
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        // 15 fps is plenty for a slow scene and keeps the phone cool.
        let supports15 = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= 15 && 15 <= $0.maxFrameRate
        }
        if supports15 {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        }
        device.unlockForConfiguration()

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
        }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait
        }
        configuredUltraWide = useUltraWide
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
