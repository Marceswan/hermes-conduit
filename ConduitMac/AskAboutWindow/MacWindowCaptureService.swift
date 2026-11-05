import AppKit
import CoreGraphics
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum MacWindowCaptureOutcome: Equatable {
    case captured(data: Data, isJPEG: Bool, suggestedName: String)
    case tooLarge(suggestedName: String)
    case cancelled
    case failed(MacWindowCaptureMath.Failure)
}

/// Drives the system window picker (`SCContentSharingPicker`, single-window
/// mode) and captures the chosen window. The picker grants per-window access,
/// so no Screen Recording prompt and no new entitlement.
@MainActor
final class MacWindowCaptureService: NSObject, SCContentSharingPickerObserver {
    static let shared = MacWindowCaptureService()

    enum Classification: Equatable {
        case proceed
        case cancelled
        case failed(MacWindowCaptureMath.Failure)
    }

    private enum PickerResult {
        case filter(SCContentFilter)
        case cancelled
        case failed(Error)
    }

    private var inFlight = false
    private var continuation: CheckedContinuation<PickerResult, Never>?

    // MARK: Pure

    /// Cancel wins only when no error is present; an error is never a cancel.
    nonisolated static func classify(cancelled: Bool, pickerError: Error?, captureError: Error?, hasImage: Bool) -> Classification {
        if pickerError != nil { return .failed(.pickerFailed) }
        if cancelled { return .cancelled }
        if captureError != nil || !hasImage { return .failed(.noPicture) }
        return .proceed
    }

    /// PNG first; if it is over 80% of the limit, the JPEG ladder. Returns nil when no rung fits.
    nonisolated static func encode(_ image: CGImage, limitBytes: Int64) -> (data: Data, isJPEG: Bool)? {
        let target = MacWindowCaptureMath.targetPixelSize(width: image.width, height: image.height)
        guard let base = resample(image, width: target.width, height: target.height),
              let png = encodeData(base, type: .png, quality: nil) else { return nil }
        let plan = MacWindowCaptureMath.encodePlan(pngByteCount: png.count, limitBytes: limitBytes)
        for step in plan {
            switch step {
            case .png:
                if Int64(png.count) <= limitBytes { return (png, false) }
            case .jpeg(let quality, let scale):
                let w = max(Int((Double(target.width) * scale).rounded()), 1)
                let h = max(Int((Double(target.height) * scale).rounded()), 1)
                guard let scaled = resample(base, width: w, height: h),
                      let jpeg = encodeData(scaled, type: .jpeg, quality: quality) else { continue }
                if Int64(jpeg.count) <= limitBytes { return (jpeg, true) }
            }
        }
        return nil
    }

    private nonisolated static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width && image.height == height { return image }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private nonisolated static func encodeData(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Picker

    /// One call in flight; a concurrent call returns `.cancelled` immediately.
    func capture(limitBytes: Int64) async -> MacWindowCaptureOutcome {
        guard !inFlight else { return .cancelled }
        inFlight = true
        defer { inFlight = false }

        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        // Unrealized windows report a number of 0 or -1; only real ids go to the picker.
        config.excludedWindowIDs = NSApp.windows.map { Int($0.windowNumber) }.filter { $0 > 0 }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        defer {
            picker.remove(self)
            picker.isActive = false
        }

        let result: PickerResult = await withCheckedContinuation { cont in
            continuation = cont
            picker.present()
        }

        var pickerError: Error?
        var captureError: Error?
        var cancelled = false
        var image: CGImage?
        var name = MacWindowCaptureMath.filename(windowTitle: nil, appName: nil)

        switch result {
        case .cancelled:
            cancelled = true
        case .failed(let error):
            pickerError = error
        case .filter(let filter):
            name = Self.suggestedName(for: filter)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let px = MacWindowCaptureMath.targetPixelSize(width: Int(filter.contentRect.width * scale),
                                                          height: Int(filter.contentRect.height * scale))
            cfg.width = px.width
            cfg.height = px.height
            cfg.showsCursor = false
            // Default framing adds the window shadow, which makes the image larger than
            // `contentRect` and squeezes it into the contentRect-sized buffer.
            cfg.ignoreShadowsSingleWindow = true
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            } catch {
                captureError = error
            }
        }

        switch Self.classify(cancelled: cancelled, pickerError: pickerError, captureError: captureError, hasImage: image != nil) {
        case .cancelled: return .cancelled
        case .failed(let failure): return .failed(failure)
        case .proceed:
            guard let image else { return .failed(.noPicture) }
            // PNG and JPEG encoding of a window-sized image takes long enough to hitch the UI.
            let encoded = await Task.detached(priority: .userInitiated) {
                Self.encode(image, limitBytes: limitBytes)
            }.value
            guard let encoded else { return .tooLarge(suggestedName: name) }
            return .captured(data: encoded.data, isJPEG: encoded.isJPEG, suggestedName: name)
        }
    }

    private static func suggestedName(for filter: SCContentFilter) -> String {
        if #available(macOS 15.2, *) {
            let window = filter.includedWindows.first
            return MacWindowCaptureMath.filename(windowTitle: window?.title,
                                                 appName: window?.owningApplication?.applicationName)
        }
        return MacWindowCaptureMath.filename(windowTitle: nil, appName: nil)
    }

    private func resume(_ result: PickerResult) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: result)
    }

    // MARK: SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.resume(.cancelled) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.resume(.failed(error)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.resume(.filter(filter)) }
    }
}
