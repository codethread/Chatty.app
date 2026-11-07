import AppKit

@MainActor
enum TranscriptLayout {
    static let font = NSFont.systemFont(ofSize: 15)
    static let defaultWidth: CGFloat = 672

    static func contextStart(in text: String, lines: Int, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var starts: [Int] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, range, _ in
            starts.append(manager.characterRange(forGlyphRange: range, actualGlyphRange: nil).location)
        }
        return starts.isEmpty ? 0 : starts[max(0, starts.count - lines)]
    }
}
