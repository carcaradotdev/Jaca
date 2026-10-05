import SwiftUI
import Lemonade

/// Time axis of captured requests. Each request is a mark positioned by start
/// time, colored by status. Drag horizontally to select a time window that
/// filters the list; click to clear.
struct NetworkTimelineView: View {
    @Bindable var session: NetworkSession
    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?

    private let height: CGFloat = 56
    private let lanes = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let domain = timeDomain()
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(in: ctx, size: size, domain: domain)
                }
                selectionOverlay(width: width, domain: domain)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, domain: domain))
            .overlay(alignment: .topTrailing) { clearButton }
        }
        .frame(height: height)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    // MARK: Drawing

    /// Read from the session, which maintains it as rows land. Deriving it here meant three
    /// full passes over every captured transaction on every redraw — and a redraw happens on
    /// every captured transaction.
    private func timeDomain() -> ClosedRange<Date> {
        guard let span = session.timeSpan else {
            let now = Date(); return now...now.addingTimeInterval(1)
        }
        return span
    }

    private func x(for date: Date, width: CGFloat, domain: ClosedRange<Date>) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return 0 }
        let frac = date.timeIntervalSince(domain.lowerBound) / span
        return CGFloat(frac) * width
    }

    /// Marks are collapsed to one per lane per horizontal pixel before anything is filled.
    ///
    /// Two marks a fraction of a pixel apart are indistinguishable, so a long capture was paying
    /// tens of thousands of `ctx.fill` calls per frame to draw the same few hundred visible
    /// pixels — the timeline alone got slower with every request. Bucketing keeps the picture and
    /// caps the drawing at `lanes × width`. Severity wins ties, so a failure is never hidden by a
    /// success that happened to land on the same pixel.
    private func draw(in ctx: GraphicsContext, size: CGSize, domain: ClosedRange<Date>) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, size.width >= 1 else { return }
        let laneHeight = (size.height - 8) / CGFloat(lanes)
        let columns = max(1, Int(size.width.rounded(.up)))
        // -1 = empty; otherwise the severity of the worst mark in that cell.
        var grid = [Int8](repeating: -1, count: lanes * columns)

        for (index, txn) in session.transactions.enumerated() {
            let startX = x(for: txn.startedAt, width: size.width, domain: domain)
            let end = txn.finishedAt ?? txn.startedAt
            let endX = max(startX + 2, x(for: end, width: size.width, domain: domain))
            let lane = index % lanes
            let from = min(max(0, Int(startX)), columns - 1)
            let to = min(max(from, Int(endX.rounded(.up)) - 1), columns - 1)
            let severity = NetworkTimelineView.severity(txn)
            for column in from...to {
                let cell = lane * columns + column
                if grid[cell] < severity { grid[cell] = severity }
            }
        }

        // One fill per run of same-severity cells, so a long bar stays a single rounded rect.
        for lane in 0..<lanes {
            var column = 0
            while column < columns {
                let severity = grid[lane * columns + column]
                guard severity >= 0 else { column += 1; continue }
                var runEnd = column + 1
                while runEnd < columns, grid[lane * columns + runEnd] == severity { runEnd += 1 }
                let rect = CGRect(x: CGFloat(column), y: 4 + CGFloat(lane) * laneHeight,
                                  width: max(2, CGFloat(runEnd - column)),
                                  height: max(3, laneHeight - 3))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(NetworkTimelineView.color(forSeverity: severity).opacity(0.85)))
                column = runEnd
            }
        }
    }

    /// Pure ordering of what a mark means, worst last — so bucketing can keep the worst one.
    static func severity(_ txn: NetworkTransaction) -> Int8 {
        if txn.error != nil { return 4 }
        guard let code = txn.statusCode else { return 0 }
        switch code {
        case 200..<300: return 1
        case 300..<400: return 2
        case 400..<500: return 3
        default:        return 4
        }
    }

    private static func color(forSeverity severity: Int8) -> Color {
        let c = LemonadeTheme.colors.content
        switch severity {
        case 1:  return c.contentPositive
        case 2:  return c.contentInfo
        case 3:  return c.contentCaution
        case 4:  return c.contentCritical
        default: return c.contentTertiary
        }
    }

    // MARK: Selection

    @ViewBuilder
    private func selectionOverlay(width: CGFloat, domain: ClosedRange<Date>) -> some View {
        if let lo = dragStartX, let hi = dragCurrentX {
            let minX = min(lo, hi), maxX = max(lo, hi)
            Rectangle()
                .fill(LemonadeTheme.colors.content.contentBrand.opacity(0.15))
                .overlay(Rectangle().stroke(LemonadeTheme.colors.content.contentBrand, lineWidth: 1))
                .frame(width: max(1, maxX - minX), height: height)
                .offset(x: minX)
                .allowsHitTesting(false)
        } else if let range = session.selectedTimeRange {
            let minX = x(for: range.lowerBound, width: width, domain: domain)
            let maxX = x(for: range.upperBound, width: width, domain: domain)
            Rectangle()
                .fill(LemonadeTheme.colors.content.contentBrand.opacity(0.12))
                .overlay(Rectangle().stroke(LemonadeTheme.colors.content.contentBrand.opacity(0.6), lineWidth: 1))
                .frame(width: max(1, maxX - minX), height: height)
                .offset(x: minX)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(width: CGFloat, domain: ClosedRange<Date>) -> some Gesture {
        // minimumDistance 0 so a plain click (no drag) also reaches onEnded and
        // clears the current selection.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartX == nil { dragStartX = value.startLocation.x }
                dragCurrentX = value.location.x
            }
            .onEnded { value in
                defer { dragStartX = nil; dragCurrentX = nil }
                let lo = dragStartX ?? value.startLocation.x
                let minX = min(lo, value.location.x), maxX = max(lo, value.location.x)
                guard maxX - minX > 3 else { session.selectedTimeRange = nil; return }
                let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                let start = domain.lowerBound.addingTimeInterval(Double(minX / max(width, 1)) * span)
                let end = domain.lowerBound.addingTimeInterval(Double(maxX / max(width, 1)) * span)
                session.selectedTimeRange = start...end
            }
    }

    @ViewBuilder
    private var clearButton: some View {
        if session.selectedTimeRange != nil {
            Button(action: { session.selectedTimeRange = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .help("Clear time selection")
        }
    }
}
