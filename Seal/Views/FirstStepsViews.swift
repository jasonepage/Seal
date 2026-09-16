// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  FirstStepsViews.swift
//  Seal
//
//  THE PIECES "WHAT TO DO FIRST" IS DRAWN WITH, shared by the owner's
//  editor, the owner's envelope card and the recipient's screen, so the
//  three cannot drift apart. A step is always a brass number in a circle,
//  a line down to the next one, the title beside it, the note under it,
//  and a small lock chip when it points at a secret.

/// The number in the circle and the line below it.
struct StepMarker: View {
    let number: Int
    let isLast: Bool
    var done = false
    var current = false
    var size: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(done ? SealTheme.brass : (current ? SealTheme.brass.opacity(0.18) : .white.opacity(0.08)))
                    .frame(width: size, height: size)
                Circle()
                    .strokeBorder(done || current ? SealTheme.brass : .white.opacity(0.25), lineWidth: 1.5)
                    .frame(width: size, height: size)
                if done {
                    Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(SealTheme.ink)
                } else {
                    Text("\(number)")
                        .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                        .foregroundStyle(current ? SealTheme.brass : .white.opacity(0.85))
                }
            }
            if !isLast {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// The small read-only timeline on the envelope card. Titles only, the
/// first note, and "and 2 more".
struct StepsTimelineMini: View {
    let steps: [FirstStep]
    let secrets: [SealedCard]
    var limit = 4

    var body: some View {
        let shown = Array(steps.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    StepMarker(number: index + 1, isLast: index == shown.count - 1 && steps.count <= limit, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.trimmedTitle)
                            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        if !step.trimmedNote.isEmpty {
                            Text(step.trimmedNote).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        if let s = step.secretIndex, secrets.indices.contains(s) {
                            SecretChip(title: secrets[s].title)
                        }
                    }
                    .padding(.bottom, 12)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if steps.count > limit {
                HStack(spacing: 12) {
                    StepMarker(number: steps.count, isLast: true, size: 24).opacity(0.5)
                    Text(steps.count - limit == 1 ? "and one more" : "and \(steps.count - limit) more")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

/// "Uses: Credit union" with a lock. Names the secret, never shows it.
struct SecretChip: View {
    let title: String
    var body: some View {
        Label(title, systemImage: "lock.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(SealTheme.brass)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(SealTheme.brass.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

/// One of the common steps, as a tappable chip. Tapping adds it.
struct StarterChip: View {
    let starter: FirstStep.Starter
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.caption.weight(.bold))
                Text(starter.title).font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .parentTapTarget(48)
    }
}

// MARK: - The recipient's checklist

/// What Karen sees. A checklist with the next step lit and a count at the
/// top. Ticks are the reader's own (FirstStepsDone) and change nothing
/// anywhere else. A step that needs a secret names it; the secret stays
/// below, behind the Face ID check.
struct StepsChecklist: View {
    let steps: [FirstStep]
    let secrets: [SealedCard]
    let ownerName: String
    @Binding var done: Set<String>

    private var doneCount: Int { steps.filter { done.contains($0.id) }.count }
    private var nextID: String? { steps.first { !done.contains($0.id) }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("What to do first").font(.headline).foregroundStyle(.white)
                Spacer()
                Text(doneCount == steps.count ? "All done" : "\(doneCount) of \(steps.count) done")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(doneCount == steps.count ? SealTheme.brass : .white.opacity(0.55))
            }
            Text("\(ownerName) wrote these for you, in this order. Tap a step when it is done. The marks stay on this phone.")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    let isDone = done.contains(step.id)
                    let isNext = step.id == nextID
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isDone { done.remove(step.id) } else { done.insert(step.id) }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            StepMarker(number: index + 1, isLast: index == steps.count - 1, done: isDone, current: isNext)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white.opacity(isDone ? 0.45 : 0.95))
                                    .strikethrough(isDone, color: .white.opacity(0.4))
                                    .fixedSize(horizontal: false, vertical: true)
                                if !step.note.isEmpty {
                                    Text(step.note)
                                        .font(.callout).foregroundStyle(.white.opacity(isDone ? 0.35 : 0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let s = step.secretIndex, secrets.indices.contains(s) {
                                    SecretChip(title: "Uses \(secrets[s].title), below")
                                }
                                if isNext {
                                    Text("Next").font(.caption2.weight(.bold)).foregroundStyle(SealTheme.brass)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.bottom, index == steps.count - 1 ? 0 : 14)
                            Spacer(minLength: 0)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isDone ? "Done: \(step.title)" : "Not done: \(step.title)")
                }
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
