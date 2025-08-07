import AVFoundation
import ScreenCaptureKit

public enum ScreenCaptureRecorderError: Error, LocalizedError {
    case noContentFilter
    case other(Error)

    public var errorDescription: String? {
        switch self {
        case .noContentFilter:
            "No content was selected for recording. Please choose a window, application, or display."
        case let .other(err):
            String(format: "An error occurred: %@", err.localizedDescription)
        }
    }
}

public enum ScreenCaptureRecorderState {
    case idle
    case pickingContent
    case started
    case recording(CMSampleBuffer)
    case stopped
    case error(ScreenCaptureRecorderError)
}

public class ScreenCaptureRecorder: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private var stateStreamContinuation: AsyncThrowingStream<ScreenCaptureRecorderState, Error>.Continuation?

    private let videoQueue = DispatchQueue(label: "dev.ScreenCaptureRecorder.StreamVideoOutputQueue")
    private let audioQueue = DispatchQueue(label: "dev.ScreenCaptureRecorder.StreamAudioOutputQueue")
    private let screenRecorderPicker = SCContentSharingPicker.shared
    private let streamConfiguration: SCStreamConfiguration

    private var contentFilter: SCContentFilter?

    public private(set) var stream: SCStream?

    public init(streamConfiguration: SCStreamConfiguration) {
        self.streamConfiguration = streamConfiguration

        super.init()
    }

    deinit {
        removePickerObserver()
    }

    public func pickStream() -> AsyncThrowingStream<ScreenCaptureRecorderState, Error> {
        let stream = AsyncThrowingStream<ScreenCaptureRecorderState, Error> { continuation in
            self.stateStreamContinuation = continuation
            continuation.yield(.pickingContent)
        }

        initializePickerConfiguration()
        registerPickerObserver()
        screenRecorderPicker.present()

        return stream
    }

    public func stopStream() async throws {
        do {
            try await stream?.stopCapture()

            stateStreamContinuation?.yield(.stopped)
            stateStreamContinuation?.finish()
            stateStreamContinuation = nil
        } catch {
            stateStreamContinuation?.yield(.error(ScreenCaptureRecorderError.other(error)))
            stateStreamContinuation?.finish(throwing: error)
            stateStreamContinuation = nil

            throw error
        }
    }

    func registerPickerObserver() {
        screenRecorderPicker.isActive = true
        screenRecorderPicker.add(self)
    }

    func removePickerObserver() {
        screenRecorderPicker.remove(self)
        screenRecorderPicker.isActive = false
    }

    public func contentSharingPicker(_: SCContentSharingPicker, didCancelFor _: SCStream?) {
        stateStreamContinuation?.finish()
        stateStreamContinuation = nil

        removePickerObserver()
    }

    public func contentSharingPicker(_: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for _: SCStream?) {
        contentFilter = filter

        startRecord()

        removePickerObserver()
    }

    public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        stateStreamContinuation?.yield(.error(ScreenCaptureRecorderError.other(error)))
        stateStreamContinuation?.finish()
        stateStreamContinuation = nil
        removePickerObserver()
    }

    func initializePickerConfiguration() {
        var initialConfiguration = SCContentSharingPickerConfiguration()
        initialConfiguration.allowedPickerModes = [
            .singleWindow,
            .singleApplication,
            .singleDisplay,
        ]

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            initialConfiguration.excludedBundleIDs = [bundleIdentifier]
        }

        screenRecorderPicker.defaultConfiguration = initialConfiguration
    }

    private func startRecord() {
        guard let contentFilter else {
            stateStreamContinuation?.yield(.error(ScreenCaptureRecorderError.noContentFilter))
            return
        }

        stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)

        do {
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

            Task {
                try await stream?.startCapture()
                stateStreamContinuation?.yield(.started)
            }

        } catch {
            stateStreamContinuation?.yield(.error(ScreenCaptureRecorderError.other(error)))
        }
    }

    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        if type == .audio {
            stateStreamContinuation?.yield(.recording(sampleBuffer))
        }
    }
}
