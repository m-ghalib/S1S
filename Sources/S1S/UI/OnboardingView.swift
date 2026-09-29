import Combine
import SwiftUI

struct OnboardingView: View {
    let requiresProfile: Bool
    let onGrant: () -> Void
    let onGrantScreen: () -> Void
    let onDone: (OnboardingProfile?) -> Void

    @State private var trusted = AccessibilityBridge.isTrusted()
    @State private var screenOK = ScreenContextProvider.shared.hasPermission()
    @State private var showChoices = false
    @State private var profileFinished = false
    @State private var flow = OnboardingFlow()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var needsProfile: Bool { requiresProfile && !profileFinished }

    var body: some View {
        VStack(spacing: 16) {
            if !showChoices {
                welcome
            } else if flow.isPicking {
                pickPage
            } else {
                choicesPage
            }
        }
        .frame(width: 580, height: 530)
        .padding()
        .onReceive(poll) { _ in
            trusted = AccessibilityBridge.isTrusted()
            screenOK = ScreenContextProvider.shared.hasPermission()
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.cursor")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.top, 4)

            Text("Welcome to S1S").font(.title).bold()

            Text("Free, on-device autocomplete for macOS. As you type, S1S suggests your next words — press Tab to accept. Nothing leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            Divider().padding(.horizontal)

            permissionRow(
                ok: trusted,
                title: "Accessibility (required)",
                detail: "Lets S1S read the field you're typing in and insert accepted suggestions.",
                buttonTitle: "Grant Accessibility",
                action: onGrant)

            permissionRow(
                ok: screenOK,
                title: "Screen Recording (recommended)",
                detail: "Lets S1S read what's on screen (via on-device OCR) so suggestions match what you're looking at. Fully local.",
                buttonTitle: "Grant Screen Recording",
                action: onGrantScreen)

            if profileFinished && !trusted {
                Text("Personalization complete. Grant Accessibility to start suggestions.")
                    .font(.callout)
            }
            Spacer(minLength: 0)
            Button(needsProfile ? "Personalize S1S" : "Get Started") {
                if needsProfile { showChoices = true }
                else { onDone(nil) }
            }
            .keyboardShortcut(.defaultAction)
            // Let first-run personalization finish even while macOS permission
            // is pending. AppDelegate still gates the engine on both steps.
            .disabled(!trusted && !needsProfile)
            .padding(.bottom, 8)
        }
    }

    private var choicesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make suggestions sound like you").font(.title2).bold()
            Text("Choose a few things you write, your role, and a tone. Then pick the endings you prefer. No typing needed; about two minutes.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    chipSection("What do you write? Select any.", columns: 3) {
                        ForEach(WritingType.allCases) { type in
                            chip(type.rawValue, selected: flow.writingTypes.contains(type)) {
                                flow.toggle(type)
                            }
                        }
                    }
                    chipSection("Your profession or role", columns: 4) {
                        ForEach(Profession.allCases) { role in
                            chip(role.rawValue, selected: flow.profession == role) {
                                flow.profession = role
                            }
                        }
                    }
                    chipSection("Preferred tone", columns: 3) {
                        ForEach(WritingTone.allCases) { tone in
                            chip(tone.rawValue, selected: flow.tone == tone) {
                                flow.tone = tone
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Back") { showChoices = false }
                Spacer()
                Button("Start quick picks") { flow.begin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canBegin)
            }
        }
        .padding(.horizontal, 12)
    }

    private var pickPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose how you'd finish this").font(.title2).bold()
            Text("Pick \(flow.roundIndex + 1) of \(flow.rounds.count)")
                .font(.callout).foregroundStyle(.secondary)
            ProgressView(value: Double(flow.roundIndex), total: Double(flow.rounds.count))

            if let round = flow.currentRound {
                Text("“\(round.prefix)…”")
                    .font(.title3).fontWeight(.medium)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("onboardingPrefix")

                VStack(spacing: 10) {
                    ForEach(round.endings.indices, id: \.self) { index in
                        Button {
                            if let profile = flow.choose(index) {
                                profileFinished = true
                                showChoices = false
                                onDone(profile)
                            }
                        } label: {
                            HStack {
                                Text(round.endings[index])
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("onboardingEnding\(index)")
                    }
                }
            }
            Spacer()
            Button("Back") { flow.back() }
        }
        .padding(.horizontal, 12)
    }

    private func chipSection<Chips: View>(_ title: String, columns: Int,
                                          @ViewBuilder chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                      spacing: 8, content: chips)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        // macOS ignores .tint on a plain .bordered button, so draw the selection ourselves.
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark") }
                Text(title)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func permissionRow(ok: Bool, title: String, detail: String,
                               buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !ok {
                    Button(buttonTitle, action: action).padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
    }
}
