//  FrequencyResponseGraph.swift
//  Interactive 20 Hz - 20 kHz logarithmic parametric frequency response Canvas with Preamp line.

import SwiftUI

public struct FrequencyResponseGraph: View {
    public let profile: EQProfile?
    public let sampleRate: Double
    public let isMasterEnabled: Bool
    public let stackedProfileCount: Int

    @Environment(\.colorScheme) private var colorScheme

    private let minFreq: Double = 20.0
    private let maxFreq: Double = 20000.0
    private let minDB: Double = -18.0
    private let maxDB: Double = 18.0
    private let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    private let gridDecibels: [Double] = [12, 6, 0, -6, -12]

    public init(
        profile: EQProfile?,
        sampleRate: Double,
        isMasterEnabled: Bool,
        stackedProfileCount: Int = 1
    ) {
        self.profile = profile
        self.sampleRate = sampleRate
        self.isMasterEnabled = isMasterEnabled
        self.stackedProfileCount = stackedProfileCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            Canvas { context, size in
                let plotRect = CGRect(
                    x: 36,
                    y: 10,
                    width: max(size.width - 44, 40),
                    height: max(size.height - 32, 40)
                )

                drawGrid(in: &context, plotRect: plotRect)
                drawPreampLine(in: &context, plotRect: plotRect)
                drawResponseCurve(in: &context, plotRect: plotRect)
                drawBandNodes(in: &context, plotRect: plotRect)
                drawAxisLabels(in: &context, plotRect: plotRect)
            }
            .frame(height: 196)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Label("Frequency Response", systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let profile {
                if isMasterEnabled {
                    HStack(spacing: 6) {
                        if stackedProfileCount > 1 {
                            Text("\(stackedProfileCount) Stacked")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }

                        Text(String(format: "Preamp %+.1f dB", profile.preampDB))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .lineLimit(1)
                } else {
                    Label("Bypassed (0.0 dB)", systemImage: "pause.circle")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Flat Reference")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var accessibilitySummary: String {
        guard let profile else {
            return "Frequency response graph showing flat zero decibel response."
        }
        if !isMasterEnabled {
            return "Frequency response graph. Master EQ is bypassed, effective output is 0.0 dB."
        }
        return String(
            format: "Frequency response graph for %@, Preamp %.1f decibels, %d active filters.",
            profile.name,
            profile.preampDB,
            profile.enabledBandCount
        )
    }

    private func xPosition(for freq: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(freq, minFreq), maxFreq)
        let norm = (log10(clamped) - log10(minFreq)) / (log10(maxFreq) - log10(minFreq))
        return rect.minX + CGFloat(norm) * rect.width
    }

    private func yPosition(for db: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(db, minDB), maxDB)
        let norm = (clamped - minDB) / (maxDB - minDB)
        return rect.maxY - CGFloat(norm) * rect.height
    }

    private func drawGrid(in context: inout GraphicsContext, plotRect: CGRect) {
        let minorLineColor = Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.07)
        let zeroLineColor = Color.primary.opacity(colorScheme == .dark ? 0.28 : 0.22)

        for freq in gridFrequencies {
            let x = xPosition(for: freq, in: plotRect)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.stroke(path, with: .color(minorLineColor), lineWidth: 0.75)
        }

        for db in gridDecibels {
            let y = yPosition(for: db, in: plotRect)
            var path = Path()
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            let isZero = db == 0
            context.stroke(
                path,
                with: .color(isZero ? zeroLineColor : minorLineColor),
                lineWidth: isZero ? 1.1 : 0.75
            )
        }
    }

    private func drawPreampLine(in context: inout GraphicsContext, plotRect: CGRect) {
        let preampDB = isMasterEnabled ? Double(profile?.preampDB ?? 0.0) : 0.0
        guard abs(preampDB) >= 0.05 || !isMasterEnabled else { return }

        let y = yPosition(for: preampDB, in: plotRect)
        var path = Path()
        path.move(to: CGPoint(x: plotRect.minX, y: y))
        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))

        let lineColor = isMasterEnabled ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.55)
        context.stroke(
            path,
            with: .color(lineColor),
            style: StrokeStyle(lineWidth: 1.25, dash: [5, 4])
        )
    }

    private func drawResponseCurve(in context: inout GraphicsContext, plotRect: CGRect) {
        let samples = 180
        var curvePath = Path()
        var points: [CGPoint] = []
        points.reserveCapacity(samples + 1)

        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        for step in 0...samples {
            let t = Double(step) / Double(samples)
            let freq = pow(10.0, logMin + t * (logMax - logMin))
            let db: Double
            if let profile, isMasterEnabled {
                db = APOParser.magnitudeResponseDB(
                    profile: profile,
                    atFrequency: freq,
                    sampleRate: sampleRate,
                    includePreamp: true
                )
            } else {
                db = 0.0
            }

            let pt = CGPoint(
                x: plotRect.minX + CGFloat(t) * plotRect.width,
                y: yPosition(for: db, in: plotRect)
            )
            points.append(pt)
            if step == 0 {
                curvePath.move(to: pt)
            } else {
                curvePath.addLine(to: pt)
            }
        }

        let baselineY = yPosition(for: 0.0, in: plotRect)
        if let first = points.first, let last = points.last, isMasterEnabled {
            var fillPath = curvePath
            fillPath.addLine(to: CGPoint(x: last.x, y: baselineY))
            fillPath.addLine(to: CGPoint(x: first.x, y: baselineY))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.30 : 0.22),
                        Color.accentColor.opacity(0.03)
                    ]),
                    startPoint: CGPoint(x: plotRect.midX, y: plotRect.minY),
                    endPoint: CGPoint(x: plotRect.midX, y: plotRect.maxY)
                )
            )
        }

        let strokeColor = isMasterEnabled ? Color.accentColor : Color.secondary.opacity(0.6)
        let strokeStyle = isMasterEnabled
            ? StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
            : StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: [4, 4])
        context.stroke(curvePath, with: .color(strokeColor), style: strokeStyle)
    }

    private func drawBandNodes(in context: inout GraphicsContext, plotRect: CGRect) {
        guard isMasterEnabled, let profile else { return }

        for band in profile.bands.prefix(APOParser.maxHardwareBands) where band.isEnabled {
            let x = xPosition(for: Double(band.frequency), in: plotRect)
            let db = APOParser.magnitudeResponseDB(
                profile: profile,
                atFrequency: Double(band.frequency),
                sampleRate: sampleRate,
                includePreamp: true
            )
            let y = yPosition(for: db, in: plotRect)
            let dotRect = CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
            let dotColor: Color = band.gain >= 0 ? .accentColor : .cyan
            context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
            context.stroke(Path(ellipseIn: dotRect), with: .color(Color(.systemBackground)), lineWidth: 1.0)
        }
    }

    private func drawAxisLabels(in context: inout GraphicsContext, plotRect: CGRect) {
        let labelFont = Font.caption2.monospacedDigit()
        let labelColor = Color.secondary

        for db in [12.0, 0.0, -12.0] {
            let y = yPosition(for: db, in: plotRect)
            let label = db == 0 ? "0" : String(format: "%+.0f", db)
            let resolved = context.resolve(Text(label).font(labelFont).foregroundStyle(labelColor))
            context.draw(resolved, at: CGPoint(x: plotRect.minX - 6, y: y), anchor: .trailing)
        }

        let freqLabels: [(Double, String)] = [
            (20, "20"),
            (100, "100"),
            (500, "500"),
            (1000, "1k"),
            (5000, "5k"),
            (20000, "20k")
        ]
        for (freq, title) in freqLabels {
            let x = xPosition(for: freq, in: plotRect)
            let resolved = context.resolve(Text(title).font(labelFont).foregroundStyle(labelColor))
            let anchor: UnitPoint = freq <= 25 ? .topLeading : (freq >= 18000 ? .topTrailing : .top)
            context.draw(resolved, at: CGPoint(x: x, y: plotRect.maxY + 5), anchor: anchor)
        }
    }
}
