import SwiftUI
import Foundation

/// The day drawn as terrain: one unbroken stroke edge to edge, elevation
/// following the meeting load. A calm day flattens to still water — this never
/// invents mountains.
///
/// No card, no fill, no border. Meeting dots sit *on* the line. Clay is rationed
/// to a single accent across the whole drawing.
struct TerrainView: View {
    let shape: DayShape
    let meetings: [MeetingDot]
    let motifs: [Motif?]

    /// Reference size from the printed page; only used for the stroke ratio.
    private let designWidth: CGFloat = 840
    private let canvasHeight: CGFloat = 168

    var body: some View {
        Canvas { context, size in
            // Line weights read as a ratio of the reference width, but every
            // vertical position is a fraction of the *actual* canvas — otherwise
            // the drawing bunches into the top of its frame on a phone.
            let scale = max(0.55, size.width / designWidth)
            let baseline = size.height * 0.78
            let amplitude = size.height * 0.52 * shape.terrainScale

            let elevation = elevationProfile()
            let points = (0...120).map { step -> CGPoint in
                let t = Double(step) / 120
                let x = t * size.width
                let y = baseline - amplitude * elevation(t)
                return CGPoint(x: x, y: y)
            }

            // One unbroken stroke.
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            context.stroke(
                line,
                with: .color(Theme.ink),
                style: StrokeStyle(lineWidth: 1.6 * max(1, scale), lineCap: .round, lineJoin: .round)
            )

            // A second ridge through a saddle, for depth on heavy days.
            if motifs.contains(where: { $0 == .ridge }) {
                var ridge = Path()
                let ridgePoints = (0...60).map { step -> CGPoint in
                    let t = Double(step) / 60
                    let x = t * size.width
                    let y = baseline - amplitude * elevation(t) * 0.42 + 9
                    return CGPoint(x: x, y: y)
                }
                ridge.move(to: ridgePoints[0])
                for point in ridgePoints.dropFirst() { ridge.addLine(to: point) }
                context.stroke(
                    ridge,
                    with: .color(Theme.inkGrey.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1.0 * max(1, scale), lineCap: .round)
                )
            }

            // Dots, on the line.
            for dot in meetings {
                let x = dot.position * size.width
                let y = baseline - amplitude * elevation(dot.position)
                // Dot radii are already in points — scaling them down would
                // make them invisible on a phone.
                let radius = CGFloat(dot.radius)
                let rect = CGRect(
                    x: x - radius, y: y - radius,
                    width: radius * 2, height: radius * 2
                )

                if dot.overlaps {
                    // Genuine overlap: two hollow circles intersecting — the
                    // only hollow dots on the page.
                    for offset in [-radius * 0.5, radius * 0.5] {
                        let circle = Path(ellipseIn: rect.offsetBy(dx: offset, dy: 0))
                        context.fill(circle, with: .color(Theme.background))
                        context.stroke(
                            circle,
                            with: .color(Theme.ink),
                            style: StrokeStyle(lineWidth: 1.3 * max(1, scale))
                        )
                    }
                } else {
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(dot.isTentative ? Theme.inkGrey : Theme.ink)
                    )
                }
            }

            drawMotifs(in: &context, size: size, baseline: baseline, scale: scale)
        }
        .frame(height: canvasHeight)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Elevation as a function of position across the day: the meeting load
    /// smoothed into hills, with a gentle base drift so a flat day still reads
    /// as a drawn line rather than a ruler.
    private func elevationProfile() -> (Double) -> Double {
        let confirmed = meetings.filter { !$0.isTentative }
        guard !confirmed.isEmpty else {
            return { t in 0.10 * sin(t * .pi) }
        }
        let peak = max(1.0, confirmed.map { Double($0.weight) }.max() ?? 1)

        return { t in
            var value = 0.0
            for dot in confirmed {
                let distance = t - dot.position
                // A bump per meeting, widened slightly by its length.
                let width = 0.055 + 0.05 * (Double(dot.weight) / peak)
                value += (Double(dot.weight) / peak) * exp(-(distance * distance) / (2 * width * width))
            }
            // Never let a busy day clip flat at the top.
            return min(1.0, value / 1.35) * 0.9 + 0.08 * sin(t * .pi)
        }
    }

    private func drawMotifs(
        in context: inout GraphicsContext,
        size: CGSize,
        baseline: CGFloat,
        scale: CGFloat
    ) {
        // Focal points sit above their column centres.
        let centres: [CGFloat] = [140.0 / 840, 420.0 / 840, 700.0 / 840]
        // Clay is rationed: the first motif that wants it gets it.
        var clayUsed = false

        for (index, motif) in motifs.enumerated() where motif != nil {
            guard index < centres.count, let motif else { continue }
            let x = centres[index] * size.width
            let y = baseline - size.height * 0.42
            let wantsClay = (motif == .sun || motif == .dawn || motif == .flag)
            let colour: Color
            if wantsClay && !clayUsed {
                colour = Theme.clay
                clayUsed = true
            } else {
                colour = Theme.inkGrey
            }
            draw(motif, at: CGPoint(x: x, y: y), scale: scale, colour: colour, in: &context)
        }

        // Always include at least one clay item.
        if !clayUsed {
            draw(
                .sun,
                at: CGPoint(x: size.width * 0.5, y: baseline - size.height * 0.42),
                scale: scale,
                colour: Theme.clay,
                in: &context
            )
        }
    }

    private func draw(
        _ motif: Motif,
        at point: CGPoint,
        scale: CGFloat,
        colour: Color,
        in context: inout GraphicsContext
    ) {
        let radius: CGFloat = 10
        let stroke = StrokeStyle(lineWidth: 1.3 * max(1, scale), lineCap: .round)

        switch motif {
        case .sun:
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(colour), style: stroke)
            for step in 0..<8 {
                let angle = Double(step) / 8 * 2 * .pi
                var ray = Path()
                ray.move(to: CGPoint(
                    x: point.x + Darwin.cos(angle) * radius * 1.45,
                    y: point.y + sin(angle) * radius * 1.45
                ))
                ray.addLine(to: CGPoint(
                    x: point.x + Darwin.cos(angle) * radius * 1.95,
                    y: point.y + sin(angle) * radius * 1.95
                ))
                context.stroke(ray, with: .color(colour), style: stroke)
            }

        case .dawn:
            // Half-risen sun on a horizon.
            var arc = Path()
            arc.addArc(
                center: point, radius: radius,
                startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false
            )
            context.stroke(arc, with: .color(colour), style: stroke)
            var horizon = Path()
            horizon.move(to: CGPoint(x: point.x - radius * 2.1, y: point.y))
            horizon.addLine(to: CGPoint(x: point.x + radius * 2.1, y: point.y))
            context.stroke(horizon, with: .color(colour), style: stroke)

        case .moon:
            var crescent = Path()
            crescent.addArc(
                center: point, radius: radius,
                startAngle: .degrees(60), endAngle: .degrees(300), clockwise: false
            )
            crescent.addArc(
                center: CGPoint(x: point.x + radius * 0.55, y: point.y), radius: radius,
                startAngle: .degrees(300), endAngle: .degrees(60), clockwise: true
            )
            context.stroke(crescent, with: .color(colour), style: stroke)

        case .birds:
            for offset in [-radius * 1.6, 0, radius * 1.6] {
                var bird = Path()
                let origin = CGPoint(x: point.x + offset, y: point.y + (offset == 0 ? -radius * 0.5 : 0))
                bird.move(to: CGPoint(x: origin.x - radius * 0.5, y: origin.y))
                bird.addQuadCurve(
                    to: CGPoint(x: origin.x, y: origin.y),
                    control: CGPoint(x: origin.x - radius * 0.25, y: origin.y - radius * 0.5)
                )
                bird.addQuadCurve(
                    to: CGPoint(x: origin.x + radius * 0.5, y: origin.y),
                    control: CGPoint(x: origin.x + radius * 0.25, y: origin.y - radius * 0.5)
                )
                context.stroke(bird, with: .color(colour), style: stroke)
            }

        case .flag:
            var pole = Path()
            pole.move(to: CGPoint(x: point.x, y: point.y - radius))
            pole.addLine(to: CGPoint(x: point.x, y: point.y + radius))
            context.stroke(pole, with: .color(colour), style: stroke)
            var cloth = Path()
            cloth.move(to: CGPoint(x: point.x, y: point.y - radius))
            cloth.addLine(to: CGPoint(x: point.x + radius, y: point.y - radius * 0.55))
            cloth.addLine(to: CGPoint(x: point.x, y: point.y - radius * 0.1))
            context.stroke(cloth, with: .color(colour), style: stroke)

        case .ridge:
            break  // drawn with the terrain, not as a focal point
        }
    }

    private var accessibilityDescription: String {
        let confirmed = meetings.filter { !$0.isTentative }.count
        switch shape {
        case .heavy:
            return "A heavy day drawn as terrain, with \(confirmed) meetings."
        case .normal:
            return "A normal day drawn as terrain, with \(confirmed) meetings."
        case .open:
            return confirmed == 0
                ? "An open day, drawn as still water."
                : "An open day drawn as terrain, with \(confirmed) meeting."
        }
    }
}
