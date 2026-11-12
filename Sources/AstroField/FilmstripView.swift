import SwiftUI
import AstroFieldKit

struct FilmstripView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.groupModeActive {
                    Text("分组累计")
                        .font(CinemaFont.micro(8))
                        .tracking(0.6)
                        .foregroundStyle(palette.textDim)
                    separator
                }
                counter("曝光", model.displayedExposed)
                separator
                counter("保存", model.displayedSaved)
                separator
                counter("失败", model.displayedFailed,
                        color: model.displayedFailed > 0 ? palette.red : nil)
                separator
                counter("合格", model.quality.qualified)
                if let target = model.quality.qualifiedTarget {
                    Text("/\(target)")
                        .font(CinemaFont.micro(9))
                        .monospacedDigit()
                        .foregroundStyle(palette.textDim)
                        .padding(.leading, 4)
                }

                Spacer(minLength: 12)

                if model.isRunning, let end = model.progress.expectedEnd {
                    Text("结束 \(timeString(end))")
                        .font(CinemaFont.micro(8.5))
                        .tracking(0.6)
                        .monospacedDigit()
                        .foregroundStyle(palette.textDim)
                        .padding(.trailing, 14)
                }
                Text(model.countdownText)
                    .font(CinemaFont.smallValue(10.5))
                    .foregroundStyle(counterColor)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(palette.divider).frame(height: 1)
                    Rectangle().fill(palette.textSecondary.opacity(0.5))
                        .frame(width: geo.size.width * progressFraction, height: 1)
                }
            }
            .frame(height: 1)

            if model.records.isEmpty {
                HStack {
                    Text("无素材")
                        .font(CinemaFont.micro(9))
                        .tracking(1.2)
                        .foregroundStyle(palette.textDim)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 62)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.records.reversed()) { record in
                            thumbnail(record)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 62)
            }
        }
        .background(palette.panel)
    }

    private var progressFraction: Double {
        if case .count(let count) = model.plan.end, count > 0 {
            return min(1, Double(model.progress.saved) / Double(count))
        }
        if let end = model.progress.expectedEnd, let start = model.progress.startedAt,
           end > start {
            return min(1, max(0, model.now.timeIntervalSince(start) / end.timeIntervalSince(start)))
        }
        return 0
    }

    private var counterColor: Color {
        switch model.progress.phase {
        case .exposing: return palette.red
        case .waitingToStart, .waitingInterval, .paused, .stopping: return palette.amber
        default: return palette.textSecondary
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(width: 0.6, height: 9)
            .padding(.horizontal, 10)
    }

    private func counter(_ label: String, _ value: Int, color: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(CinemaFont.micro(8.5))
                .tracking(0.9)
                .foregroundStyle(palette.textDim)
            Text("\(value)")
                .font(CinemaFont.smallValue(11))
                .foregroundStyle(color ?? palette.text)
                .monospacedDigit()
        }
    }

    private func thumbnail(_ record: ImageRecord) -> some View {
        let selected = model.selectedID == record.id
        return Button {
            model.selectRecord(record)
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let preview = record.thumbnail ?? record.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 58)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(palette.monitorBackground)
                        .frame(width: 96, height: 58)
                        .overlay(ProgressView().controlSize(.mini).scaleEffect(0.45))
                }
                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                               startPoint: .center, endPoint: .bottom)
                    .frame(width: 96, height: 58)

                HStack(spacing: 3) {
                    QualityDot(verdict: record.verdict)
                    Text(String(format: "%04d", record.sequence))
                        .font(CinemaFont.micro(8))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
                .padding(4)
            }
            .frame(width: 96, height: 58)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? palette.selected : Color.clear)
                    .frame(height: 1.5)
            }
            .opacity(selected ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .help(record.displayName)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
