import SwiftUI
import ScarfCore
import ScarfDesign

/// Compact grid of status cells. The cells are inline JSON, so this is
/// the one v2.7 widget that can render on iPhone without a file watch,
/// cron job, or Kanban tenant.
struct StatusGridWidgetView: View {
    let widget: DashboardWidget

    private var cells: [StatusGridCell] { widget.cells ?? [] }

    private var columnCount: Int {
        if let n = widget.gridColumns, n > 0 { return min(20, n) }
        let count = cells.count
        if count <= 4 { return max(1, count) }
        if count <= 12 { return 6 }
        if count <= 24 { return 8 }
        return 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .font(.caption)
                Text(widget.title)
                    .font(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer()
                Text("\(cells.count)")
                    .font(.caption2)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            if cells.isEmpty {
                Text("No cells.")
                    .font(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount),
                    spacing: 4
                ) {
                    ForEach(cells) { cell in
                        StatusGridCellView(cell: cell)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }
}

private struct StatusGridCellView: View {
    let cell: StatusGridCell

    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var swatchHeight: CGFloat = 18

    private var typedStatus: ListItemStatus { ListItemStatus(raw: cell.status) ?? .neutral }

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(0.85))
                .frame(height: swatchHeight)
            Text(cell.label)
                .font(.system(size: labelSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: cell.label))
        .accessibilityValue(Text(verbatim: cell.status ?? String(localized: "unknown")))
        .accessibilityHint(cell.tooltip.map { Text(verbatim: $0) } ?? Text(""))
    }

    private var tint: Color {
        switch typedStatus {
        case .success, .done: return ScarfColor.success
        case .warning: return ScarfColor.warning
        case .danger: return ScarfColor.danger
        case .info: return ScarfColor.info
        case .pending, .neutral: return .secondary
        }
    }
}
