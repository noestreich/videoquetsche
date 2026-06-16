import Foundation
import AppKit

enum PaddingColor: String, CaseIterable, Identifiable {
    case none = "Kein Padding"
    case black = "Schwarz"
    case white = "Weiß"
    var id: String { rawValue }
}

enum Resolution: String, CaseIterable, Identifiable {
    case original = "Original"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"
    var id: String { rawValue }
    var height: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

struct CompressionSettings {
    var crf: Int = 28
    var resolution: Resolution = .p720
    var removeAudio: Bool = false
    var paddingColor: PaddingColor = .none
}

struct VideoJob: Identifiable {
    let id = UUID()
    let url: URL
    var status: JobStatus = .waiting
    var progress: Double = 0
    var errorMessage: String?
    var originalSize: Int64 = 0
    var outputSize: Int64? = nil

    enum JobStatus {
        case waiting, running, done, failed
    }
}

@MainActor
class VideoProcessor: ObservableObject {
    @Published var jobs: [VideoJob] = []
    @Published var isProcessing = false

    private var activeProcess: Process?

    func addFiles(_ urls: [URL]) {
        let supported = ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "3gp"]
        let filtered = urls.filter { supported.contains($0.pathExtension.lowercased()) }
        let newJobs = filtered.map { url -> VideoJob in
            var job = VideoJob(url: url)
            job.originalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return job
        }
        jobs.append(contentsOf: newJobs)
    }

    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    func clearAll() {
        guard !isProcessing else { return }
        jobs.removeAll()
    }

    func startProcessing(settings: CompressionSettings) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            await processQueue(settings: settings)
            isProcessing = false
        }
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
        for i in jobs.indices where jobs[i].status == .running {
            jobs[i].status = .waiting
            jobs[i].progress = 0
        }
        isProcessing = false
    }

    private func processQueue(settings: CompressionSettings) async {
        for i in jobs.indices {
            guard jobs[i].status == .waiting else { continue }
            jobs[i].status = .running
            jobs[i].progress = 0

            let url = jobs[i].url
            let outputURL = outputURL(for: url)

            do {
                try await runFFmpeg(input: url, output: outputURL, settings: settings, jobIndex: i)
                jobs[i].outputSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? nil
                jobs[i].status = .done
                jobs[i].progress = 1.0
            } catch {
                jobs[i].status = .failed
                jobs[i].errorMessage = error.localizedDescription
            }
        }
    }

    private func outputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let name = input.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name)-small.mp4")
    }

    private func ffmpegPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "ffmpeg"
    }

    private func runFFmpeg(input: URL, output: URL, settings: CompressionSettings, jobIndex: Int) async throws {
        // Get duration for progress tracking
        let duration = await getVideoDuration(url: input)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath())

            var args: [String] = ["-y", "-i", input.path]

            // Build video filter chain
            var vfilters: [String] = []

            if settings.paddingColor != .none {
                let color = settings.paddingColor == .black ? "black" : "white"
                if let targetSize = settings.resolution.height {
                    // Analog zur fish-Funktion:
                    //   scale=-2:H  →  hier: in Square-Modus auf T×T skalieren
                    //   pad=T:T:(ow-iw)/2:(oh-ih)/2:COLOR
                    // force_original_aspect_ratio=decrease stellt sicher, dass
                    // das Video immer vollständig ins Quadrat passt (kein Cropping).
                    vfilters.append("scale=\(targetSize):\(targetSize):force_original_aspect_ratio=decrease")
                    vfilters.append("pad=\(targetSize):\(targetSize):(ow-iw)/2:(oh-ih)/2:\(color)")
                } else {
                    // Originalgröße: sicherstellen, dass Dimensionen gerade sind,
                    // dann auf die längere Seite aufpadden.
                    vfilters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
                    vfilters.append("pad=max(iw\\,ih):max(iw\\,ih):(ow-iw)/2:(oh-ih)/2:\(color)")
                }
            } else if let height = settings.resolution.height {
                // Normaler Modus ohne Square: nur Höhe skalieren, Breite automatisch
                vfilters.append("scale=-2:\(height)")
            }

            if !vfilters.isEmpty {
                args += ["-vf", vfilters.joined(separator: ",")]
            }

            // Video codec
            args += ["-c:v", "libx264", "-crf", "\(settings.crf)", "-preset", "medium"]

            // Audio
            if settings.removeAudio {
                args += ["-an"]
            } else {
                args += ["-c:a", "aac", "-b:a", "96k"]
            }

            args += ["-movflags", "+faststart", output.path]

            process.arguments = args

            // Capture stderr for progress
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice

            var buffer = ""

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                buffer += str

                // Parse time= from ffmpeg output for progress
                if let duration = duration, duration > 0 {
                    let pattern = #"time=(\d+):(\d+):([\d.]+)"#
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.lastMatch(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)) {
                        let h = Double((buffer as NSString).substring(with: match.range(at: 1))) ?? 0
                        let m = Double((buffer as NSString).substring(with: match.range(at: 2))) ?? 0
                        let s = Double((buffer as NSString).substring(with: match.range(at: 3))) ?? 0
                        let elapsed = h * 3600 + m * 60 + s
                        let progress = min(elapsed / duration, 0.99)
                        Task { @MainActor in
                            self?.jobs[jobIndex].progress = progress
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let msg = buffer.components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? "ffmpeg error"
                    continuation.resume(throwing: NSError(domain: "ffmpeg", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }

            do {
                try process.run()
                self.activeProcess = process
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func getVideoDuration(url: URL) async -> Double? {
        return await withCheckedContinuation { continuation in
            let process = Process()
            let ffprobeCandidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
            let ffprobe = ffprobeCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "ffprobe"
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "quiet", "-print_format", "json", "-show_format", url.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let format = json["format"] as? [String: Any],
                   let durationStr = format["duration"] as? String,
                   let duration = Double(durationStr) {
                    continuation.resume(returning: duration)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            try? process.run()
        }
    }
}

extension NSRegularExpression {
    func lastMatch(in string: String, range: NSRange) -> NSTextCheckingResult? {
        let matches = self.matches(in: string, range: range)
        return matches.last
    }
}
