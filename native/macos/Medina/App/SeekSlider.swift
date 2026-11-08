import AppKit
import SwiftUI

/// Native slider tracking preserves click/drag and keyboard accessibility while
/// exposing hover positions in the cell's actual usable track coordinates.
struct SeekSlider: NSViewRepresentable {
    @Binding var value: Double
    let duration: Double
    let enabled: Bool
    let bufferedRanges: [ClosedRange<Double>]
    let onHover: (Double?) -> Void
    let onEditingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverSeekSlider {
        let slider = HoverSeekSlider(frame: .zero)
        slider.cell = BufferedSliderCell()
        slider.minValue = 0
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(HoverSeekSlider.valueChanged)
        slider.setAccessibilityLabel("Playback position")
        return slider
    }

    func updateNSView(_ slider: HoverSeekSlider, context: Context) {
        slider.maxValue = max(duration, 1)
        slider.doubleValue = min(slider.maxValue, max(0, value))
        slider.isEnabled = enabled
        slider.onValue = { value = $0 }
        slider.bufferedRanges = bufferedRanges
        slider.onHover = onHover
        slider.onEditingChanged = onEditingChanged
    }
}

final class BufferedSliderCell: NSSliderCell {
    var bufferedRanges: [ClosedRange<Double>] = []

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        super.drawBar(inside: rect, flipped: flipped)
        let duration = maxValue - minValue
        guard duration > 0 else { return }
        let bar = barRect(flipped: flipped)
        let inset = knobRect(flipped: flipped).width / 2
        let trackWidth = max(1, bar.width - inset * 2)
        let position = min(max(doubleValue, minValue), maxValue)
        let playedFraction = (position - minValue) / duration
        let originX = bar.minX + inset
        let played = NSRect(x: originX, y: bar.minY,
                            width: max(0, playedFraction * trackWidth), height: max(2, bar.height))
        NSColor(calibratedRed: 0.90, green: 0.52, blue: 0.18, alpha: 1).setFill()
        if played.width > 0 {
            NSBezierPath(roundedRect: played, xRadius: played.height / 2, yRadius: played.height / 2).fill()
        }
        NSColor.systemBlue.withAlphaComponent(0.55).setFill()
        for range in bufferedRanges {
            let start = max(playedFraction, (range.lowerBound - minValue) / duration)
            let end = min(1, (range.upperBound - minValue) / duration)
            guard end > start else { continue }
            let segment = NSRect(x: originX + start * trackWidth,
                                 y: bar.minY,
                                 width: max(1, (end - start) * trackWidth),
                                 height: max(2, bar.height))
            NSBezierPath(roundedRect: segment, xRadius: segment.height / 2, yRadius: segment.height / 2).fill()
        }
    }
}

final class HoverSeekSlider: NSSlider {
    var onValue: ((Double) -> Void)?
    var bufferedRanges: [ClosedRange<Double>] = [] {
        didSet { (cell as? BufferedSliderCell)?.bufferedRanges = bufferedRanges }
    }
    var onHover: ((Double?) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var editing = false

    @objc func valueChanged() {
        // Outside mouse tracking, native keyboard/accessibility actions are
        // committed immediately by the owning view's binding.
        onValue?(doubleValue)
        if editing { onHover?(doubleValue) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        editing = true
        onEditingChanged?(true)
        // NSSlider runs its own tracking loop; actions update only the local
        // scrub position. Commit the real seek after the loop returns.
        super.mouseDown(with: event)
        onValue?(doubleValue)
        editing = false
        onEditingChanged?(false)
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !bounds.contains(point) { onHover?(nil) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled, !editing, let cell = cell as? NSSliderCell else { return }
        let point = convert(event.locationInWindow, from: nil)
        let bar = cell.barRect(flipped: isFlipped)
        let inset = cell.knobRect(flipped: isFlipped).width / 2
        let width = max(1, bar.width - inset * 2)
        let fraction = min(1, max(0, (point.x - bar.minX - inset) / width))
        onHover?(fraction * maxValue)
    }

    override func mouseExited(with event: NSEvent) {
        if !editing { onHover?(nil) }
    }
}
