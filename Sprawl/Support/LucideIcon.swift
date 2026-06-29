import AppKit

/// Minimal renderer for [Lucide](https://lucide.dev) icons. Each icon is stored as its SVG
/// elements (verbatim path data + the occasional rect/circle) and drawn with `NSBezierPath` in
/// Lucide's house style: a 24×24 box, 2px stroke, round caps/joins, no fill. Supports the SVG
/// path subset Lucide uses (M/L/H/V/C/A and Z, absolute + relative).
enum LucideIcon {
    enum Shape {
        case path(String)
        case rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    }

    static let folderPlus: [Shape] = [
        .path("M12 10v6"),
        .path("M9 13h6"),
        .path("M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"),
    ]
    static let squareTerminal: [Shape] = [
        .path("m7 11 2-2-2-2"),
        .path("M11 13h4"),
        .rect(x: 3, y: 3, w: 18, h: 18, r: 2),
    ]
    static let fileText: [Shape] = [
        .path("M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"),
        .path("M14 2v5a1 1 0 0 0 1 1h5"),
        .path("M10 9H8"),
        .path("M16 13H8"),
        .path("M16 17H8"),
    ]
    static let globe: [Shape] = [
        .circle(cx: 12, cy: 12, r: 10),
        .path("M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"),
        .path("M2 12h20"),
    ]
    static let textWrap: [Shape] = [
        .path("M3 5h18"),
        .path("M3 12h14.5a1 1 0 0 1 0 7H13"),
        .path("m16 16-3 3 3 3"),
        .path("M3 19h6"),
    ]

    /// Render the icon to an `NSImage` of `size` points, stroked in `color`.
    static func image(_ shapes: [Shape], size: CGFloat, color: NSColor, strokeWidth: CGFloat = 2) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return true }
            context.cgContext.scaleBy(x: size / 24, y: size / 24)   // Lucide icons live in a 24×24 box
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for shape in shapes { append(shape, to: path) }
            color.setStroke()
            path.lineWidth = strokeWidth
            path.stroke()
            return true
        }
    }

    private static func append(_ shape: Shape, to path: NSBezierPath) {
        switch shape {
        case .path(let d):
            appendSVGPath(d, to: path)
        case .rect(let x, let y, let w, let h, let r):
            path.appendRoundedRect(NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
        case .circle(let cx, let cy, let r):
            path.appendOval(in: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
    }

    // MARK: - SVG path parsing

    private enum Token { case command(Character); case number(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        let commands = Set("MmLlHhVvCcSsQqTtAaZz")
        var tokens: [Token] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "," || c.isWhitespace { i += 1; continue }
            if commands.contains(c) { tokens.append(.command(c)); i += 1; continue }
            var s = ""
            if c == "+" || c == "-" { s.append(c); i += 1 }
            var seenDot = false, seenExp = false
            while i < chars.count {
                let ch = chars[i]
                if ch.isNumber { s.append(ch); i += 1 }
                else if ch == "." && !seenDot && !seenExp { seenDot = true; s.append(ch); i += 1 }
                else if (ch == "e" || ch == "E") && !seenExp {
                    seenExp = true; s.append(ch); i += 1
                    if i < chars.count, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                } else { break }
            }
            if let value = Double(s) { tokens.append(.number(CGFloat(value))) } else if s.isEmpty { i += 1 }
        }
        return tokens
    }

    private static func appendSVGPath(_ d: String, to path: NSBezierPath) {
        let tokens = tokenize(d)
        var i = 0
        func num() -> CGFloat? {
            guard i < tokens.count, case .number(let v) = tokens[i] else { return nil }
            i += 1; return v
        }
        var current = CGPoint.zero
        var subStart = CGPoint.zero
        var cmd: Character = " "
        while i < tokens.count {
            if case .command(let c) = tokens[i] { cmd = c; i += 1 }
            switch cmd {
            case "M", "m":
                guard let x = num(), let y = num() else { return }
                let p = cmd == "m" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: p); current = p; subStart = p
                cmd = cmd == "m" ? "l" : "L"   // subsequent implicit coordinate pairs are line-tos
            case "L", "l":
                guard let x = num(), let y = num() else { return }
                let p = cmd == "l" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.line(to: p); current = p
            case "H", "h":
                guard let x = num() else { return }
                let p = cmd == "h" ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.line(to: p); current = p
            case "V", "v":
                guard let y = num() else { return }
                let p = cmd == "v" ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.line(to: p); current = p
            case "C", "c":
                guard let a = num(), let b = num(), let c1 = num(), let c2 = num(), let e = num(), let f = num() else { return }
                let base = cmd == "c" ? current : .zero
                let cp1 = CGPoint(x: base.x + a, y: base.y + b)
                let cp2 = CGPoint(x: base.x + c1, y: base.y + c2)
                let end = CGPoint(x: base.x + e, y: base.y + f)
                path.curve(to: end, controlPoint1: cp1, controlPoint2: cp2); current = end
            case "A", "a":
                guard let rx = num(), let ry = num(), let rot = num(), let large = num(),
                      let sweep = num(), let ex = num(), let ey = num() else { return }
                let end = cmd == "a" ? CGPoint(x: current.x + ex, y: current.y + ey) : CGPoint(x: ex, y: ey)
                appendArc(to: path, from: current, to: end, rx: rx, ry: ry,
                          phiDeg: rot, largeArc: large != 0, sweep: sweep != 0)
                current = end
            case "Z", "z":
                path.close(); current = subStart; cmd = " "
            default:
                i += 1   // skip anything unsupported so the loop always makes progress
            }
        }
    }

    /// Append an SVG elliptical-arc command as cubic-bezier segments (W3C implementation notes F.6).
    private static func appendArc(to path: NSBezierPath, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat, phiDeg: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || (p0.x == p1.x && p0.y == p1.y) { path.line(to: p1); return }

        let phi = phiDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let rx2 = rx * rx, ry2 = ry * ry, x1p2 = x1p * x1p, y1p2 = y1p * y1p
        let numerator = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let denominator = rx2 * y1p2 + ry2 * x1p2
        var coef = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = length == 0 ? 0 : acos(max(-1, min(1, (ux * vx + uy * vy) / length)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var dTheta = angle(ux, uy, vx, vy)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = (4.0 / 3.0) * tan(delta / 4)
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                    y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                    y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        var a1 = theta1
        for _ in 0..<segments {
            let a2 = a1 + delta
            let start = point(a1), end = point(a2)
            let d1 = derivative(a1), d2 = derivative(a2)
            path.curve(to: end,
                       controlPoint1: CGPoint(x: start.x + t * d1.x, y: start.y + t * d1.y),
                       controlPoint2: CGPoint(x: end.x - t * d2.x, y: end.y - t * d2.y))
            a1 = a2
        }
    }
}
