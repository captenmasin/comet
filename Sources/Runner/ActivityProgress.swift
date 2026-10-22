import Foundation
import SwiftUI
import RunnerCore

struct ActivityStatus {
    let status: String
    let conclusion: String?

    var label: String {
        switch conclusion ?? status {
        case "success": "Succeeded"
        case "failure": "Failed"
        case "timed_out": "Timed out"
        case "cancelled": "Cancelled"
        case "skipped": "Skipped"
        case "in_progress": "Running"
        case "queued", "pending", "waiting": "Pending"
        case "completed": "Completed"
        default: conclusion ?? status
        }
    }

    var symbol: String {
        switch conclusion ?? status {
        case "success": "checkmark.circle.fill"
        case "failure", "timed_out": "xmark.circle.fill"
        case "cancelled": "minus.circle"
        case "skipped": "arrow.right.circle"
        case "in_progress": "circle.inset.filled"
        default: "circle"
        }
    }

    var color: Color {
        switch conclusion ?? status {
        case "success": .green
        case "failure", "timed_out": .red
        case "in_progress": runnerAccent
        default: .secondary
        }
    }
}

struct ActivityDuration: View {
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    var isLive = true

    enum Timing: Equatable {
        case running(Date), elapsed(TimeInterval), unavailable
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }

    func timing(at now: Date) -> Timing {
        guard let start = Self.date(startedAt) else { return .unavailable }
        if let completedAt {
            guard let end = Self.date(completedAt), end >= start else { return .unavailable }
            return .elapsed(end.timeIntervalSince(start))
        }
        guard status == "in_progress", conclusion == nil, isLive, start <= now else { return .unavailable }
        return .running(start)
    }

    var body: some View {
        Group {
            switch timing(at: Date()) {
            case .running(let start): Text(start, style: .timer)
            case .elapsed(let seconds): Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
            case .unavailable: Text("—").accessibilityLabel("Duration unavailable")
            }
        }.monospacedDigit()
    }
}

struct StepProgressView: View {
    let steps: [JobStep]
    var isLive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps.sorted { $0.number < $1.number }, id: \.number) { step in
                let outcome = ActivityStatus(status: step.status, conclusion: step.conclusion)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: outcome.symbol).foregroundStyle(outcome.color)
                        .frame(width: 16).accessibilityHidden(true)
                    Text(step.name).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(outcome.label).foregroundStyle(.secondary)
                    ActivityDuration(status: step.status, conclusion: step.conclusion,
                                     startedAt: step.started_at, completedAt: step.completed_at, isLive: isLive)
                        .foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
        }.font(.caption).padding(.leading, 28)
    }
}
