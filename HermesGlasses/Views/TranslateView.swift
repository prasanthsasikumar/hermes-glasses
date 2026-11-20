//
// TranslateView.swift
//
// The Translate app's screen: live camera with a centre reticle, a
// language picker, and the word. Hold the reticle on a thing the detector
// knows and the word is spoken; tap the picture to ask the AI about
// anything else.
//
// Full screen with an explicit Done, like Lens and Lookup - it holds a
// live stream, and a stray drag-dismiss would tear it down.
//

import SwiftUI

struct TranslateView: View {
    @State private var model: TranslateViewModel
    @Environment(\.dismiss) private var dismiss

    init(hermesVM: HermesSessionViewModel) {
        _model = State(initialValue: TranslateViewModel(hermesVM: hermesVM))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            languagePicker
            feed
            resultArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensChrome.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HermesScreenTitle(text: "TRANSLATE")
                Text(model.errorBanner ?? model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(model.errorBanner == nil
                        ? HermesTheme.cream.opacity(0.5)
                        : HermesTheme.destructive)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if model.aiState == .looking {
                ProgressView()
                    .tint(HermesTheme.accentLight)
                    .scaleEffect(0.8)
            }

            if model.fingerAvailable {
                Button {
                    model.fingerEnabled.toggle()
                } label: {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.fingerEnabled ? .white : HermesTheme.cream.opacity(0.55))
                        .frame(width: 36, height: 32)
                        .background(
                            model.fingerEnabled ? HermesTheme.accent : HermesTheme.cream.opacity(0.08),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Point with a finger")
                .accessibilityValue(model.fingerEnabled ? "On" : "Off")
            }

            HermesChromePill(title: "Done", prominent: true) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var languagePicker: some View {
        HStack(spacing: 8) {
            ForEach(TranslateLanguage.allCases) { language in
                let selected = language == model.language
                Button {
                    model.language = language
                } label: {
                    Text(language.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .white : HermesTheme.cream.opacity(0.75))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            selected ? HermesTheme.accent : HermesTheme.cream.opacity(0.08),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.englishName)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Feed

    @ViewBuilder
    private var feed: some View {
        Group {
            if let image = model.feedImage {
                GeometryReader { geo in
                    let fitted = fittedRect(imageSize: image.size, in: geo.size)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        boxOverlay(in: fitted)

                        // With Finger on only the finger names things;
                        // there is no centre point to aim.
                        if !model.fingerActive {
                            reticle
                                .position(x: fitted.midX, y: fitted.midY)
                        }

                        if let pointing = model.pointing {
                            fingerMarks(pointing, in: fitted)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapped() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Camera")
                    .accessibilityHint("Double tap to name what is in the centre")
                }
            } else if model.needsGlassesCameraGrant {
                VStack(spacing: 14) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 34))
                        .foregroundStyle(HermesTheme.cream.opacity(0.4))
                    Text("The glasses camera isn't allowed yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HermesTheme.cream)
                    Text("Meta AI grants this separately from iOS. It only has to be done once.")
                        .font(.system(size: 13))
                        .foregroundStyle(HermesTheme.cream.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        Task { await model.grantGlassesCamera() }
                    } label: {
                        Text("Allow camera")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(HermesTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(HermesTheme.accentLight)
                            Text(model.statusText)
                                .font(.system(size: 13))
                                .foregroundStyle(HermesTheme.cream.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensStage)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale,
                          height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// Only the box under the reticle is drawn. Translate is about the one
    /// thing you are aiming at; outlining everything else in view is noise.
    private func boxOverlay(in fitted: CGRect) -> some View {
        Canvas { context, _ in
            guard let rect = model.targetBox else { return }
            let box = CGRect(
                x: fitted.minX + rect.minX * fitted.width,
                y: fitted.minY + rect.minY * fitted.height,
                width: rect.width * fitted.width,
                height: rect.height * fitted.height
            )
            context.stroke(
                Path(roundedRect: box, cornerRadius: 8),
                with: .color(HermesTheme.accent),
                lineWidth: 2.5
            )
        }
        .allowsHitTesting(false)
    }

    /// Where the finger is taken to point: a dot on the fingertip and a
    /// ring just past it that fills while the finger holds still.
    private func fingerMarks(_ pointing: Pointing, in fitted: CGRect) -> some View {
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: fitted.minX + p.x * fitted.width,
                    y: fitted.minY + p.y * fitted.height)
        }
        return ZStack {
            Circle()
                .fill(HermesTheme.accentLight)
                .frame(width: 8, height: 8)
                .position(place(pointing.tip))
            ZStack {
                Circle()
                    .stroke(HermesTheme.cream.opacity(0.45), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: model.pointProgress)
                    .stroke(
                        HermesTheme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: model.pointProgress)
            }
            .frame(width: 36, height: 36)
            .position(place(pointing.probe))
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .allowsHitTesting(false)
    }

    /// The aim point, with the hold filling round it.
    private var reticle: some View {
        ZStack {
            Circle()
                .stroke(HermesTheme.cream.opacity(0.35), lineWidth: 3)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0, to: model.holdProgress)
                .stroke(
                    HermesTheme.accent,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 44, height: 44)
                .animation(.linear(duration: 0.1), value: model.holdProgress)
            Circle()
                .fill(HermesTheme.cream.opacity(0.9))
                .frame(width: 5, height: 5)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .allowsHitTesting(false)
    }

    // MARK: - Result

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.voiceMissing, let current = model.shown {
                Text("No \(current.language.englishName) voice on this iPhone. Add one in Settings → Accessibility → Spoken Content → Voices.")
                    .font(.system(size: 12))
                    .foregroundStyle(HermesTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            card

            if !model.phrases.isEmpty, model.isStreaming {
                phraseRow
            }

            if model.recent.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.recent.dropFirst().enumerated()), id: \.offset) { _, term in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(term.word)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(HermesTheme.cream.opacity(0.8))
                                Text(term.english)
                                    .font(.system(size: 10))
                                    .foregroundStyle(HermesTheme.cream.opacity(0.45))
                            }
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                HermesTheme.cream.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: model.shown)
    }

    /// Things to say to the person behind the counter. Labelled in
    /// English - they are for the user to choose from, not to read out.
    private var phraseRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.phrases) { phrase in
                    Button {
                        model.speakPhrase(phrase)
                    } label: {
                        Text(phrase.english)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HermesTheme.cream.opacity(0.9))
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(
                                HermesTheme.accent.opacity(0.35),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Says it in \(model.language.englishName)")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let term = model.shown {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(term.word)
                            .font(.system(size: model.pinnedPhrase == nil ? 30 : 34, weight: .bold))
                            .foregroundStyle(HermesTheme.cream)
                            .minimumScaleFactor(0.5)
                            .lineLimit(2)
                        if let romanized = term.romanized {
                            Text(romanized)
                                .font(.system(size: 15))
                                .foregroundStyle(HermesTheme.accentLight)
                        }
                        Text(term.english)
                            .font(.system(size: 13))
                            .foregroundStyle(HermesTheme.cream.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.replay()
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(HermesTheme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Say it again")

                    if model.pinnedPhrase != nil {
                        Button {
                            model.unpinPhrase()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(HermesTheme.cream)
                                .frame(width: 44, height: 44)
                                .background(HermesTheme.cream.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close phrase")
                    }
                }
            } else if model.aiState == .idle {
                Text(model.fingerActive
                     ? "Point your index finger at something and hold still - the AI names it. Nothing is said until you point. Turn the hand icon off to aim with the circle instead."
                     : "Aim the circle at something and hold still - you'll hear what it's called. Tap the picture to ask about anything it doesn't pick up.")
                    .font(.system(size: 12))
                    .foregroundStyle(HermesTheme.cream.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch model.pinnedPhrase == nil ? model.aiState : .idle {
            case .idle:
                EmptyView()
            case .looking:
                Text("Looking…")
                    .font(.system(size: 13))
                    .foregroundStyle(HermesTheme.cream.opacity(0.6))
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(HermesTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            HermesTheme.cream.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.horizontal, 16)
    }
}
