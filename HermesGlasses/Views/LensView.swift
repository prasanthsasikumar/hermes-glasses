//
// LensView.swift
//
// Object Snap: live glasses-camera feed with YOLO boxes, a center
// reticle that fills while you hold an object under it, and a strip of
// the crops it has snapped. Stream runs only while this view is on
// screen. Snaps are session-only.
//

import SwiftUI

struct LensView: View {
    @State private var model: LensViewModel
    @State private var selectedSnap: LensSnap?
    @Environment(\.dismiss) private var dismiss

    init(hermesVM: HermesSessionViewModel) {
        _model = State(initialValue: LensViewModel(hermesVM: hermesVM))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            feed
            snapStrip
            Spacer(minLength: 0)
        }
        .background(Color(.systemBackground))
        .task { await model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $selectedSnap) { snap in
            snapDetail(snap)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lens")
                    .font(.system(size: 24, weight: .bold))
                Text(model.errorBanner ?? model.statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(model.errorBanner == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            if model.isStreaming {
                Text("\(model.fps) fps")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Live feed + overlay

    @ViewBuilder
    private var feed: some View {
        if let image = model.feedImage {
            GeometryReader { geo in
                let fitted = fittedRect(
                    imageSize: image.size, in: geo.size
                )
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    detectionOverlay(in: fitted)
                    reticle
                        .position(x: fitted.midX, y: fitted.midY)
                    captureOverlay
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 14)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(HermesTheme.chipFill)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
        }
    }

    /// Where the aspect-fit image actually lands inside the container -
    /// detection rects are normalized to the IMAGE, so boxes must map
    /// into this rect, not the container.
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

    private func detectionOverlay(in fitted: CGRect) -> some View {
        Canvas { context, _ in
            for detection in model.detections {
                let r = detection.rect
                let box = CGRect(
                    x: fitted.minX + r.minX * fitted.width,
                    y: fitted.minY + r.minY * fitted.height,
                    width: r.width * fitted.width,
                    height: r.height * fitted.height
                )
                let isTarget = detection.label == model.targetLabel
                let color: Color = isTarget ? HermesTheme.accent : .white
                context.stroke(
                    Path(roundedRect: box, cornerRadius: 4),
                    with: .color(color.opacity(isTarget ? 0.95 : 0.6)),
                    lineWidth: isTarget ? 2.5 : 1.5
                )
                let label = Text(" \(detection.label) ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                context.draw(
                    label,
                    at: CGPoint(x: box.minX + 4, y: max(box.minY - 9, 8)),
                    anchor: .leading
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Shutter flash + status pill for the snap moment ("Taking a pic…"
    /// then "Cropping…"), driven by the model's capture stage.
    @ViewBuilder
    private var captureOverlay: some View {
        if let stage = model.captureStage {
            ZStack {
                if stage == .flash {
                    Rectangle()
                        .fill(.white)
                        .opacity(0.65)
                        .transition(.opacity)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: stage == .flash
                            ? "camera.fill" : "scissors")
                        Text(stage == .flash ? "Taking a pic…" : "Cropping…")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 14)
                }
            }
            .animation(.easeOut(duration: 0.3), value: stage)
            .allowsHitTesting(false)
        }
    }

    /// Center reticle: a ring that fills clockwise as dwell accumulates.
    private var reticle: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.7), lineWidth: 2)
                .frame(width: 30, height: 30)
            Circle()
                .trim(from: 0, to: model.dwellProgress)
                .stroke(
                    HermesTheme.accent,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 40, height: 40)
                .animation(.linear(duration: 0.1), value: model.dwellProgress)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
    }

    // MARK: - Snap strip

    @ViewBuilder
    private var snapStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.snaps.isEmpty
                ? "Hold the ring on an object for 2 seconds to snap it"
                : "SNAPS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.snaps) { snap in
                        Button {
                            selectedSnap = snap
                        } label: {
                            VStack(spacing: 4) {
                                Image(uiImage: snap.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 92, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(snap.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: model.snaps.isEmpty ? 0 : 116)
        }
        .padding(.top, 14)
        .animation(.snappy, value: model.snaps.count)
    }

    private func snapDetail(_ snap: LensSnap) -> some View {
        VStack(spacing: 14) {
            Image(uiImage: snap.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
            VStack(spacing: 3) {
                Text(snap.label)
                    .font(.system(size: 20, weight: .bold))
                Text(snap.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
        .presentationDetents([.medium, .large])
    }
}
