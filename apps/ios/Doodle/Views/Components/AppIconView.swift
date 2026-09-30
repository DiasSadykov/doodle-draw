import SwiftUI

struct AppIconView: View {
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(DoodleTheme.pink)
            HeartStroke()
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.55, height: size * 0.55)
        }
        .frame(width: size, height: size)
    }
}

private struct HeartStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.88))
        path.addCurve(
            to: CGPoint(x: w * 0.12, y: h * 0.28),
            control1: CGPoint(x: w * 0.05, y: h * 0.62),
            control2: CGPoint(x: w * 0.02, y: h * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.38),
            control1: CGPoint(x: w * 0.22, y: h * 0.42),
            control2: CGPoint(x: w * 0.38, y: h * 0.38)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.88, y: h * 0.28),
            control1: CGPoint(x: w * 0.62, y: h * 0.38),
            control2: CGPoint(x: w * 0.78, y: h * 0.42)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.88),
            control1: CGPoint(x: w * 0.98, y: h * 0.18),
            control2: CGPoint(x: w * 0.95, y: h * 0.62)
        )
        return path
    }
}
