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
    static let code: [Shape] = [
        .path("m16 18 6-6-6-6"),
        .path("m8 6-6 6 6 6"),
    ]
    static let diff: [Shape] = [
        .path("M12 3v14"),
        .path("M5 10h14"),
        .path("M5 21h14"),
    ]
    static let figma: [Shape] = [
        .path("M5 5.5A3.5 3.5 0 0 1 8.5 2H12v7H8.5A3.5 3.5 0 0 1 5 5.5z"),
        .path("M12 2h3.5a3.5 3.5 0 1 1 0 7H12V2z"),
        .path("M12 12.5a3.5 3.5 0 1 1 7 0 3.5 3.5 0 1 1-7 0z"),
        .path("M5 19.5A3.5 3.5 0 0 1 8.5 16H12v3.5a3.5 3.5 0 1 1-7 0z"),
        .path("M5 12.5A3.5 3.5 0 0 1 8.5 9H12v7H8.5A3.5 3.5 0 0 1 5 12.5z"),
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
    static let gitCommit: [Shape] = [
        .circle(cx: 12, cy: 12, r: 3),
        .path("M3 12h6"),
        .path("M15 12h6"),
    ]
    static let layoutGrid: [Shape] = [
        .rect(x: 3, y: 3, w: 7, h: 7, r: 1),
        .rect(x: 14, y: 3, w: 7, h: 7, r: 1),
        .rect(x: 14, y: 14, w: 7, h: 7, r: 1),
        .rect(x: 3, y: 14, w: 7, h: 7, r: 1),
    ]
    static let gitBranch: [Shape] = [
        .path("M6 3v12"),
        .circle(cx: 18, cy: 6, r: 3),
        .circle(cx: 6, cy: 18, r: 3),
        .path("M18 9a9 9 0 0 1-9 9"),
    ]
    static let chartColumn: [Shape] = [
        .path("M3 3v16a2 2 0 0 0 2 2h16"),
        .path("M18 17V9"),
        .path("M13 17V5"),
        .path("M8 17v-3"),
    ]
    static let gitGraph: [Shape] = [
        .circle(cx: 5, cy: 6, r: 3),
        .circle(cx: 5, cy: 18, r: 3),
        .circle(cx: 19, cy: 12, r: 3),
        .path("M5 9v6"),
        .path("M8 18h5a3 3 0 0 0 3-3v-1"),
        .path("M16 9V8a3 3 0 0 0-3-3H8"),
    ]
    static let gauge: [Shape] = [
        .path("m12 14 4-4"),
        .path("M3.34 19a10 10 0 1 1 17.32 0"),
    ]
    static let chevronDown: [Shape] = [
        .path("m6 9 6 6 6-6"),
    ]
    static let stickyNote: [Shape] = [
        .path("M20 4H4v16h10l6-6z"),
        .path("M14 20v-6h6"),
    ]
    static let type: [Shape] = [
        .path("M4 7V4h16v3"),
        .path("M9 20h6"),
        .path("M12 4v16"),
    ]
    static let spline: [Shape] = [   // a curved line with end nodes — for the Lines tool (future)
        .circle(cx: 5, cy: 19, r: 2),
        .circle(cx: 19, cy: 5, r: 2),
        .path("M5 17A12 12 0 0 1 17 5"),
    ]
    static let importIcon: [Shape] = [
        .path("M12 3v12"),
        .path("m8 11 4 4 4-4"),
        .path("M8 5H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-4"),
    ]
    static let sparkles: [Shape] = [
        .path("M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"),
        .path("M20 3v4"),
        .path("M22 5h-4"),
        .path("M4 17v2"),
        .path("M5 18H3"),
    ]

    /// The Anthropic "burst" glyph from the Claude logo (the cream mark only), as a filled SVG path
    /// in a 512 viewBox. Rendered via `filledImage` so it can match the faded empty-state icons.
    static let anthropicGlyphPath = "M142.27 316.619l73.655-41.326 1.238-3.589-1.238-1.996-3.589-.001-12.31-.759-42.084-1.138-36.498-1.516-35.361-1.896-8.897-1.895-8.34-10.995.859-5.484 7.482-5.03 10.717.935 23.683 1.617 35.537 2.452 25.782 1.517 38.193 3.968h6.064l.86-2.451-2.073-1.517-1.618-1.517-36.776-24.922-39.81-26.338-20.852-15.166-11.273-7.683-5.687-7.204-2.451-15.721 10.237-11.273 13.75.935 3.513.936 13.928 10.716 29.749 23.027 38.848 28.612 5.687 4.727 2.275-1.617.278-1.138-2.553-4.271-21.13-38.193-22.546-38.848-10.035-16.101-2.654-9.655c-.935-3.968-1.617-7.304-1.617-11.374l11.652-15.823 6.445-2.073 15.545 2.073 6.547 5.687 9.655 22.092 15.646 34.78 24.265 47.291 7.103 14.028 3.791 12.992 1.416 3.968 2.449-.001v-2.275l1.997-26.641 3.69-32.707 3.589-42.084 1.239-11.854 5.863-14.206 11.652-7.683 9.099 4.348 7.482 10.716-1.036 6.926-4.449 28.915-8.72 45.294-5.687 30.331h3.313l3.792-3.791 15.342-20.372 25.782-32.227 11.374-12.789 13.27-14.129 8.517-6.724 16.1-.001 11.854 17.617-5.307 18.199-16.581 21.029-13.75 17.819-19.716 26.54-12.309 21.231 1.138 1.694 2.932-.278 44.536-9.479 24.062-4.347 28.714-4.928 12.992 6.066 1.416 6.167-5.106 12.613-30.71 7.583-36.018 7.204-53.636 12.689-.657.48.758.935 24.164 2.275 10.337.556h25.301l47.114 3.514 12.309 8.139 7.381 9.959-1.238 7.583-18.957 9.655-25.579-6.066-59.702-14.205-20.474-5.106-2.83-.001v1.694l17.061 16.682 31.266 28.233 39.152 36.397 1.997 8.999-5.03 7.102-5.307-.758-34.401-25.883-13.27-11.651-30.053-25.302-1.996-.001v2.654l6.926 10.136 36.574 54.975 1.895 16.859-2.653 5.485-9.479 3.311-10.414-1.895-21.408-30.054-22.092-33.844-17.819-30.331-2.173 1.238-10.515 113.261-4.929 5.788-11.374 4.348-9.478-7.204-5.03-11.652 5.03-23.027 6.066-30.052 4.928-23.886 4.449-29.674 2.654-9.858-.177-.657-2.173.278-22.37 30.71-34.021 45.977-26.919 28.815-6.445 2.553-11.173-5.789 1.037-10.337 6.243-9.2 37.257-47.392 22.47-29.371 14.508-16.961-.101-2.451h-.859l-98.954 64.251-17.618 2.275-7.583-7.103.936-11.652 3.589-3.791 29.749-20.474-.101.102.024.101z"

    /// Render filled SVG path(s) (a `viewBox`-square logo) to an `NSImage`, filled in `color`.
    static func filledImage(_ paths: [String], size: CGFloat, color: NSColor, viewBox: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return true }
            context.cgContext.scaleBy(x: size / viewBox, y: size / viewBox)
            let path = NSBezierPath()
            path.windingRule = .nonZero
            for d in paths { appendSVGPath(d, to: path) }
            color.setFill()
            path.fill()
            return true
        }
    }

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
