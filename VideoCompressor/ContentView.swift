import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var processor: VideoProcessor
    @State private var settings = CompressionSettings()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "film.stack")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Videoquetsche")
                    .font(.headline)
                Spacer()
                if !processor.jobs.isEmpty && !processor.isProcessing {
                    Button("Alles löschen") {
                        processor.clearAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.background)

            Divider()

            // Drop zone + job list
            ZStack {
                if processor.jobs.isEmpty {
                    DropZoneView(isTargeted: isTargeted)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(processor.jobs) { job in
                                JobRowView(job: job) {
                                    processor.removeJob(id: job.id)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if isTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .padding(4)
                        }
                    }
                }
            }
            .frame(minHeight: 200)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            Divider()

            // Settings
            SettingsView(settings: $settings)
                .padding(16)

            Divider()

            // Action bar
            HStack {
                if processor.isProcessing {
                    Button("Abbrechen") {
                        processor.cancel()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                } else {
                    Spacer()
                }

                Spacer()

                let waiting = processor.jobs.filter { $0.status == .waiting }.count
                let mergeEnabled = settings.mergeFiles
                let buttonDisabled = mergeEnabled ? (waiting < 2 || processor.isProcessing) : (waiting == 0 || processor.isProcessing)

                Button(action: {
                    processor.startProcessing(settings: settings)
                }) {
                    HStack(spacing: 6) {
                        if processor.isProcessing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Text(buttonLabel(waiting: waiting, mergeEnabled: mergeEnabled))
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .disabled(buttonDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
    }

    private func buttonLabel(waiting: Int, mergeEnabled: Bool) -> String {
        if processor.isProcessing {
            return mergeEnabled ? "Verbinde..." : "Verarbeite..."
        }
        return mergeEnabled ? "Verbinden (\(waiting))" : "Komprimieren (\(waiting))"
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            processor.addFiles(urls)
        }
        return true
    }
}

struct DropZoneView: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            Text("Videos hier ablegen")
                .font(.headline)
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            Text("MP4, MOV, AVI, MKV, WebM und mehr")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .padding(16)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}

struct JobRowView: View {
    let job: VideoJob
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if job.status == .running {
                    ProgressView(value: job.progress)
                        .frame(height: 4)
                } else if job.status == .failed, let msg = job.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if job.status == .done, let outSize = job.outputSize {
                    if job.isMergeSource {
                        MergeSummaryView(outputSize: outSize)
                    } else {
                        SizeSummaryView(originalSize: job.originalSize, outputSize: outSize)
                    }
                } else if job.originalSize > 0 {
                    Text(formatBytes(job.originalSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if job.status != .running {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(rowBackground)
    }

    @ViewBuilder
    var statusIcon: some View {
        switch job.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .running:
            Image(systemName: job.isMergeSource ? "link" : "gear")
                .foregroundColor(.accentColor)
                .rotationEffect(.degrees(job.isMergeSource ? 0 : job.progress * 360 * 4))
                .animation(job.isMergeSource ? .none : .linear(duration: 2).repeatForever(autoreverses: false), value: job.progress)
        case .done:
            Image(systemName: job.isMergeSource ? "checkmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    var rowBackground: some View {
        Color.secondary.opacity(job.status == .running ? 0.08 : 0.0)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1000 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

struct SizeSummaryView: View {
    let originalSize: Int64
    let outputSize: Int64

    var savings: Double {
        guard originalSize > 0 else { return 0 }
        return (1 - Double(outputSize) / Double(originalSize)) * 100
    }

    var savingsColor: Color {
        savings >= 40 ? .green : savings >= 10 ? .orange : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(formatBytes(originalSize))
            Image(systemName: "arrow.right")
                .font(.caption2)
            Text(formatBytes(outputSize))
            Text("(\(savings >= 0 ? "-" : "+")\(String(format: "%.0f", abs(savings)))%)")
                .foregroundColor(savingsColor)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

struct MergeSummaryView: View {
    let outputSize: Int64

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.caption2)
            Text("In Ausgabedatei verbunden · \(formatBytes(outputSize))")
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

struct SettingsView: View {
    @Binding var settings: CompressionSettings

    var qualityLabel: String {
        switch settings.crf {
        case ..<22: return "Hohe Qualität"
        case 22..<27: return "Gut"
        case 27..<31: return "Standard"
        case 31..<35: return "Klein"
        default: return "Sehr klein"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // Quality
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Qualität")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(qualityLabel) (CRF \(settings.crf))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Groß")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Slider(value: Binding(
                        get: { Double(settings.crf) },
                        set: { settings.crf = Int($0) }
                    ), in: 18...35, step: 1)
                    Text("Klein")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Resolution + Padding
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auflösung")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $settings.resolution) {
                        ForEach(Resolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quadratisches Format")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $settings.paddingColor) {
                        ForEach(PaddingColor.allCases) { color in
                            Text(color.rawValue).tag(color)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            // Audio toggle
            Toggle(isOn: $settings.removeAudio) {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.slash")
                        .foregroundColor(.secondary)
                    Text("Tonspur entfernen")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)

            // Merge toggle
            Toggle(isOn: $settings.mergeFiles) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                    Text("Dateien verbinden")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)

            Divider()

            FFmpegStatusView()
        }
    }
}

struct FFmpegStatusView: View {
    private let candidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    var ffmpegFound: Bool {
        candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: ffmpegFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(ffmpegFound ? .green : .red)
                Text(ffmpegFound ? "ffmpeg vorhanden" : "ffmpeg nicht gefunden")
                    .font(.caption.weight(.medium))
                    .foregroundColor(ffmpegFound ? .green : .red)
            }
            ForEach(candidates, id: \.self) { path in
                let found = FileManager.default.fileExists(atPath: path)
                HStack(spacing: 6) {
                    Image(systemName: found ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundColor(found ? .green : Color.secondary.opacity(0.35))
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(found ? .primary : Color.secondary.opacity(0.45))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
