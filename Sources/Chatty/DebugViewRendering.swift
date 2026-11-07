#if CHATTY_DEBUG_PANEL
import AppKit

/// Renders this app's own view tree for layout verification. This is not a
/// desktop screenshot: window chrome and the background blur are not captured.
@MainActor
enum DebugViewRendering {
    static func writePNG(of view: NSView, background: NSColor? = nil, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DebugInputError.injected("Could not allocate the view render")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output: NSBitmapImageRep
        if let background {
            let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            context.setFillColor(background.usingColorSpace(.deviceRGB)!.cgColor)
            context.fill(rect)
            context.draw(bitmap.cgImage!, in: rect)
            output = NSBitmapImageRep(cgImage: context.makeImage()!)
        } else { output = bitmap }
        guard let data = output.representation(using: .png, properties: [:]) else {
            throw DebugInputError.injected("Could not encode the view render")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
#endif
