import SwiftUI
import UIKit

/// Native scroll view: pinch to zoom, TWO fingers to pan; one finger edits.
/// Gesture locations are read in the unzoomed image view, so drawing and labels stay aligned.
@MainActor
struct LayerDrawingCanvas: UIViewRepresentable {
    let image: UIImage
    let overlay: UIImage?
    let tool: LayerTool
    let layer: SceneLayer
    let radius: Double
    let polygon: [UnitPoint2D]
    let enabled: Bool
    let onTap: (UnitPoint2D) -> Void
    let onStroke: ([UnitPoint2D]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> LayerScrollView {
        let view = LayerScrollView(imageSize: image.size)
        view.delegate = context.coordinator
        view.base.image = image
        view.tint.image = overlay
        view.panGestureRecognizer.minimumNumberOfTouches = 2
        view.delaysContentTouches = false
        view.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let draw = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dragged(_:)))
        draw.minimumNumberOfTouches = 1; draw.maximumNumberOfTouches = 1
        draw.delegate = context.coordinator
        view.canvas.addGestureRecognizer(tap); view.canvas.addGestureRecognizer(draw)
        context.coordinator.view = view; context.coordinator.draw = draw
        return view
    }
    func updateUIView(_ view: LayerScrollView, context: Context) {
        context.coordinator.owner = self
        view.base.image = image; view.tint.image = overlay
        context.coordinator.draw?.isEnabled = enabled && tool == .brush
        view.canvas.isUserInteractionEnabled = enabled
        context.coordinator.showPolygon()
    }
    static func color(_ layer: SceneLayer) -> UIColor {
        switch layer {
        case .near: return UIColor(red: 1,green: 0.32,blue: 0.14,alpha: 1)
        case .middle: return UIColor(red: 0.09,green: 0.86,blue: 0.55,alpha: 1)
        case .far: return UIColor(red: 0.22,green: 0.56,blue: 1,alpha: 1)
        case .unknown: return .white
        }
    }
    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var owner: LayerDrawingCanvas
        weak var view: LayerScrollView?
        weak var draw: UIPanGestureRecognizer?
        private var points: [UnitPoint2D] = []
        init(_ owner: LayerDrawingCanvas) { self.owner = owner }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { view?.centerCanvas() }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            owner.enabled && owner.tool == .brush
        }
        private func unit(_ location: CGPoint) -> UnitPoint2D? {
            guard let canvas = view?.canvas, canvas.bounds.width > 0, canvas.bounds.height > 0,
                  canvas.bounds.contains(location) else { return nil }
            return .init(x: Double(location.x / canvas.bounds.width), y: Double(location.y / canvas.bounds.height))
        }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard owner.enabled, let canvas = view?.canvas, let p = unit(recognizer.location(in: canvas)) else { return }
            owner.onTap(p)
        }
        @objc func dragged(_ recognizer: UIPanGestureRecognizer) {
            guard owner.enabled, owner.tool == .brush, let view else { return }
            if recognizer.state == .began { points = [] }
            if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
                if let p = unit(recognizer.location(in: view.canvas)), points.count < 20000 {
                    if let last = points.last, abs(p.x-last.x)+abs(p.y-last.y) < 0.0005 {} else { points.append(p) }
                }
                showPath(points, closed: false, brush: true)
            }
            if recognizer.state == .ended {
                let stroke = points; points = []; view.path.path = nil
                if !stroke.isEmpty { owner.onStroke(stroke) }
            } else if recognizer.state == .cancelled || recognizer.state == .failed {
                points = []; view.path.path = nil
            }
        }
        func showPolygon() {
            if owner.tool == .polygon { showPath(owner.polygon, closed: false, brush: false) }
            else if points.isEmpty { view?.path.path = nil }
        }
        private func showPath(_ points: [UnitPoint2D], closed: Bool, brush: Bool) {
            guard let view else { return }
            let path = UIBezierPath()
            for (index,p) in points.enumerated() {
                let point = CGPoint(x: p.x * view.canvas.bounds.width, y: p.y * view.canvas.bounds.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if closed { path.close() }
            view.path.path = path.cgPath
            view.path.fillColor = UIColor.clear.cgColor
            view.path.strokeColor = LayerDrawingCanvas.color(owner.layer).withAlphaComponent(brush ? 0.6 : 1).cgColor
            view.path.lineWidth = brush ? CGFloat(owner.radius*2) * min(view.canvas.bounds.width,view.canvas.bounds.height) : 2 / max(view.zoomScale,0.01)
            view.path.lineCap = .round; view.path.lineJoin = .round
        }
    }
}

@MainActor
final class LayerScrollView: UIScrollView {
    let canvas = UIView(), base = UIImageView(), tint = UIImageView(), path = CAShapeLayer()
    private var lastSize = CGSize.zero
    init(imageSize: CGSize) {
        super.init(frame: .zero)
        canvas.frame = CGRect(origin: .zero,size: imageSize)
        base.frame = canvas.bounds; tint.frame = canvas.bounds
        base.contentMode = .scaleToFill; tint.contentMode = .scaleToFill
        canvas.addSubview(base); canvas.addSubview(tint); path.frame = canvas.bounds; canvas.layer.addSublayer(path)
        addSubview(canvas); contentSize = imageSize
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        bouncesZoom = true; clipsToBounds = true
        accessibilityLabel = "分层编辑画布，双指缩放移动，单指编辑"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        if lastSize != bounds.size {
            lastSize = bounds.size
            let fit = min(bounds.width/canvas.bounds.width,bounds.height/canvas.bounds.height)
            minimumZoomScale = fit; maximumZoomScale = fit*8; zoomScale = fit
            centerCanvas()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
        centerCanvas()
    }
    func centerCanvas() {
        let horizontal = max(0,(bounds.width-canvas.frame.width)/2)
        let vertical = max(0,(bounds.height-canvas.frame.height)/2)
        let desired = UIEdgeInsets(top: vertical,left: horizontal,bottom: vertical,right: horizontal)
        if contentInset != desired { contentInset = desired }
    }
}
