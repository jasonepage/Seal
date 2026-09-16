// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import WidgetKit

//  CheckInWidget.swift
//  SealWidget
//
//  "LAST CHECK-IN: 12 DAYS AGO."
//
//  One widget, on the Lock Screen and the Home Screen, that shows how long
//  it has been since the owner opened Seal, and how long the rule allows.
//  Tapping it opens the app, and opening the app is the check-in.
//
//  It knows two numbers (CheckInShared) and nothing else. No names, no
//  envelopes, no secrets, no claim state. If the app has not sealed yet it
//  says so and nothing more.
//
//  The timeline is one entry per day for the next week, each at local
//  midnight, so "days ago" ticks over without the app running. The app
//  also asks for a reload after every heartbeat.

struct CheckInEntry: TimelineEntry {
    let date: Date
    let reading: CheckInShared.Reading?

    /// Whole days between the last check-in and this entry's date.
    var daysAgo: Int {
        guard let r = reading else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: r.lastCheckIn, to: date).day ?? 0)
    }

    /// Days left before the quiet period ends, never negative.
    var daysLeft: Int {
        guard let r = reading else { return 0 }
        return max(0, r.silenceDays - daysAgo)
    }

    /// The plain line. "Today" for a same day check-in, then real numbers.
    var agoLine: String {
        switch daysAgo {
        case 0: return "Checked in today"
        case 1: return "Last check-in: yesterday"
        default: return "Last check-in: \(daysAgo) days ago"
        }
    }

    var leftLine: String {
        guard let r = reading else { return "" }
        if daysLeft == 0 { return "Your quiet period has ended. Open Seal." }
        if daysLeft <= 7 { return "\(daysLeft) days left. Open Seal soon." }
        return "\(daysLeft) of \(r.silenceDays) quiet days left"
    }
}

struct CheckInProvider: TimelineProvider {
    func placeholder(in context: Context) -> CheckInEntry {
        CheckInEntry(date: Date(), reading: .init(lastCheckIn: Date().addingTimeInterval(-12 * 86_400), silenceDays: 90))
    }

    func getSnapshot(in context: Context, completion: @escaping (CheckInEntry) -> Void) {
        completion(CheckInEntry(date: Date(), reading: context.isPreview ? placeholder(in: context).reading : CheckInShared.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CheckInEntry>) -> Void) {
        let reading = CheckInShared.read()
        let now = Date()
        var entries = [CheckInEntry(date: now, reading: reading)]
        let calendar = Calendar.current
        var next = calendar.startOfDay(for: now)
        for _ in 0..<7 {
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86_400)
            entries.append(CheckInEntry(date: next, reading: reading))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct CheckInWidgetView: View {
    let entry: CheckInEntry
    @Environment(\.widgetFamily) private var family

    private let brass = Color(red: 0.851, green: 0.643, blue: 0.255)

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(entry.reading == nil ? "Seal: not sealed yet" : entry.agoLine, systemImage: "checkmark.seal.fill")
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        default:
            home
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "checkmark.seal.fill").font(.caption)
                if entry.reading == nil {
                    Text("Seal").font(.caption2)
                } else {
                    Text("\(entry.daysAgo)").font(.title3.weight(.semibold))
                    Text(entry.daysAgo == 1 ? "day" : "days").font(.caption2)
                }
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Seal", systemImage: "checkmark.seal.fill").font(.headline)
            if entry.reading == nil {
                Text("Not sealed yet. Open Seal.").font(.caption)
            } else {
                Text(entry.agoLine).font(.caption)
                Text(entry.leftLine).font(.caption2).opacity(0.8)
            }
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(brass)
                Text("Seal").font(.headline).foregroundStyle(.white)
                Spacer()
            }
            Spacer(minLength: 0)
            if entry.reading == nil {
                Text("Not sealed yet.").font(.subheadline).foregroundStyle(.white)
                Text("Open Seal to finish.").font(.caption).foregroundStyle(.white.opacity(0.6))
            } else {
                Text(entry.agoLine)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(entry.leftLine).font(.caption).foregroundStyle(.white.opacity(0.65))
                Text("Tap to check in.").font(.caption2).foregroundStyle(brass)
            }
        }
        .padding(2)
        .containerBackground(for: .widget) {
            Color(red: 0.047, green: 0.055, blue: 0.071)
        }
    }
}

struct CheckInWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CheckInShared.widgetKind, provider: CheckInProvider()) { entry in
            CheckInWidgetView(entry: entry)
        }
        .configurationDisplayName("Check in with Seal")
        .description("How long since you last opened Seal. Tap to check in.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
