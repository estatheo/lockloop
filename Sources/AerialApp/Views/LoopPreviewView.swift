import AerialKit
import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// Plays the dropped file on a background in the sampled colour, placed exactly as the encode will place it.
struct LoopPreviewView: NSViewRepresentable {
    let file: LoadedFile
    var playing: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.configure(media: file.media)
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        if view.mediaURL != file.media.url { view.configure(media: file.media) }
        view.fit = file.fit
        view.displayAspect = file.displayAspect
        view.background = file.background.cgColor
        view.setPlaying(playing)
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: PreviewNSView, coordinator: ()) {
        view.tearDown()
    }
}

final class PreviewNSView: NSView {
    private(set) var mediaURL: URL?
    private var mediaSize = CGSize(width: 16, height: 9)
    private let content = CALayer()
    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    var fit: FitMode = .fit
    var displayAspect = CanvasGeometry.sixteenNine
    var background: CGColor = .black { didSet { layer?.backgroundColor = background } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.addSublayer(content)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(media: SourceMedia) {
        tearDown()
        mediaURL = media.url
        mediaSize = media.displaySize
        switch media.kind {
        case .video:
            let item = AVPlayerItem(url: media.url)
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: item)
            let pl = AVPlayerLayer(player: player)
            pl.videoGravity = .resize
            content.addSublayer(pl)
            self.player = player
            self.playerLayer = pl
        case .gif:
            guard let source = CGImageSourceCreateWithURL(media.url as CFURL, nil) else { return }
            let count = CGImageSourceGetCount(source)
            var images: [CGImage] = []
            for i in 0..<count { if let image = CGImageSourceCreateImageAtIndex(source, i, nil) { images.append(image) } }
            content.contents = images.first
            content.contentsGravity = .resize
            guard images.count > 1 else { return }
            let total = media.frameDelays.reduce(0, +)
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.keyTimes = FrameTiming.startTimes(delays: media.frameDelays).map { NSNumber(value: $0 / total) }
            animation.calculationMode = .discrete
            animation.duration = total
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            content.add(animation, forKey: "frames")
        }
        needsLayout = true
    }

    func setPlaying(_ playing: Bool) {
        if let player {
            if playing { player.play() } else { player.pause() }
        } else if playing, content.speed == 0 {
            let paused = content.timeOffset
            content.speed = 1
            content.timeOffset = 0
            content.beginTime = 0
            content.beginTime = content.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !playing, content.speed != 0 {
            let now = content.convertTime(CACurrentMediaTime(), from: nil)
            content.speed = 0
            content.timeOffset = now
        }
    }

    func tearDown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        content.removeAllAnimations()
        content.contents = nil
        content.speed = 1
        content.timeOffset = 0
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CanvasGeometry.destination(source: mediaSize, canvas: bounds.size, fit: fit, displayAspect: displayAspect)
        // CanvasGeometry rounds to whole pixels of the canvas; in a small view that is close enough.
        content.frame = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        playerLayer?.frame = content.bounds
        layer?.backgroundColor = background
        CATransaction.commit()
    }
}
