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
    var mergeFiles: Bool = false
}

struct VideoJob: Identifiable {
    let id = UUID()
    let url: URL
    var status: JobStatus = .waiting
    var progress: Double = 0
    var errorMessage: String?
    var originalSize: Int64 = 0
    var outputSize: Int64? = nil
    var isMergeSource: Bool = false

    enum JobStatus {
        case waiting, running, done, failed
    }
}

@MainActor
class VideoProcessor: ObservableObject {
    @Published var jobs: [VideoJob] = []
    @Published var isProcessing = false

    private var activeProcess: Process?
    private var processingTask: Task<Void, Never>?

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
        processingTask = Task {
            defer {
                isProcessing = false
                activeProcess = nil
                processingTask = nil
            }
            if settings.mergeFiles {
                await processMerge(settings: settings)
            } else {
                await processQueue(settings: settings)
            }
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        activeProcess?.terminate()
        activeProcess = nil
        for i in jobs.indices where jobs[i].status == .running {
            jobs[i].status = .waiting
            jobs[i].progress = 0
            jobs[i].isMergeSource = false
        }
        isProcessing = false
    }

    // MARK: - Individual processing

    private func processQueue(settings: CompressionSettings) async {
        let indices = jobs.indices.filter { jobs[$0].status == .waiting }
        for i in indices {
            guard !Task.isCancelled else { break }
            guard i < jobs.count, jobs[i].status == .waiting else { continue }
            jobs[i].status = .running
            jobs[i].progress = 0

            let url = jobs[i].url
            let outputURL = singleOutputURL(for: url)

            do {
                try await runFFmpeg(input: url, output: outputURL, settings: settings, jobIndex: i)
                jobs[i].outputSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? nil
                jobs[i].status = .done
                jobs[i].progress = 1.0
            } catch {
                if jobs[i].status == .waiting { break } // cancelled
                jobs[i].status = .failed
                jobs[i].errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Merge processing

    private func processMerge(settings: CompressionSettings) async {
        let indices = jobs.indices.filter { jobs[$0].status == .waiting }
        guard indices.count >= 2 else {
            await processQueue(settings: settings)
            return
        }

        for i in indices {
            jobs[i].status = .running
            jobs[i].isMergeSource = true
            jobs[i].progress = 0
        }

        let tempList = FileManager.default.temporaryDirectory
            .appendingPathComponent("vq-\(UUID().uuidString).txt")
        let fileList = indices.map { "file '\(jobs[$0].url.path)'" }.joined(separator: "\n")

        guard (try? fileList.write(to: tempList, atomically: true, encoding: .utf8)) != nil else {
            for i in indices {
                jobs[i].status = .failed
                jobs[i].errorMessage = "Dateiliste konnte nicht erstellt werden"
            }
            return
        }
        defer { try? FileManager.default.removeItem(at: tempList) }

        let firstURL = jobs[indices[0]].url
        let outputURL = firstURL.deletingLastPathComponent()
            .appendingPathComponent(firstURL.deletingPathExtension().lastPathComponent + "-merged.mp4")

        var totalDuration: Double = 0
        for i in indices {
            if let d = await getVideoDuration(url: jobs[i].url) { totalDuration += d }
        }

        do {
            try await runFFmpegConcat(
                listFile: tempList,
                output: outputURL,
                settings: settings,
                jobIndices: indices,
                totalDuration: totalDuration > 0 ? totalDuration : nil
            )
            let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? nil
            for i in indices {
                jobs[i].outputSize = outSize
                jobs[i].status = .done
                jobs[i].progress = 1.0
            }
        } catch {
            for i in indices {
                if jobs[i].status != .waiting {
                    jobs[i].status = .failed
                    jobs[i].errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - ffmpeg helpers

    private func singleOutputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let name = input.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name)-small.mp4")
    }

    private func ffmpegPath() -> String {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "ffmpeg"
    }

    private func buildVideoFilters(settings: CompressionSettings) -> [String] {
        var vfilters: [String] = []
        if settings.paddingColor != .none {
            let color = settings.paddingColor == .black ? "black" : "white"
            if let targetSize = settings.resolution.height {
                vfilters.append("scale=\(targetSize):\(targetSize):force_original_aspect_ratio=decrease")
                vfilters.append("pad=\(targetSize):\(targetSize):(ow-iw)/2:(oh-ih)/2:\(color)")
            } else {
                vfilters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
                vfilters.append("pad=max(iw\\,ih):max(iw\\,ih):(ow-iw)/2:(oh-ih)/2:\(color)")
            }
        } else if let height = settings.resolution.height {
            vfilters.append("scale=-2:\(height)")
        }
        return vfilters
    }

    private func buildEncodeArgs(settings: CompressionSettings, outputPath: String) -> [String] {
        var args: [String] = []
        let vfilters = buildVideoFilters(settings: settings)
        if !vfilters.isEmpty { args += ["-vf", vfilters.joined(separator: ",")] }
        args += ["-c:v", "libx264", "-crf", "\(settings.crf)", "-preset", "medium"]
        args += settings.removeAudio ? ["-an"] : ["-c:a", "aac", "-b:a", "96k"]
        args += ["-movflags", "+faststart", outputPath]
        return args
    }

    private func runFFmpeg(input: URL, output: URL, settings: CompressionSettings, jobIndex: Int) async throws {
        let duration = await getVideoDuration(url: input)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath())
            process.arguments = ["-y", "-i", input.path] + buildEncodeArgs(settings: settings, outputPath: output.path)

            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            var buffer = ""

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                buffer += str
                if let duration, duration > 0, let progress = parseProgress(from: buffer, duration: duration) {
                    Task { @MainActor in self?.jobs[jobIndex].progress = progress }
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

    private func runFFmpegConcat(listFile: URL, output: URL, settings: CompressionSettings, jobIndices: [Int], totalDuration: Double?) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath())
            process.arguments = ["-y", "-f", "concat", "-safe", "0", "-i", listFile.path]
                + buildEncodeArgs(settings: settings, outputPath: output.path)

            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            var buffer = ""

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                buffer += str
                if let total = totalDuration, total > 0, let progress = parseProgress(from: buffer, duration: total) {
                    Task { @MainActor in
                        for i in jobIndices { self?.jobs[i].progress = progress }
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
            let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
            process.executableURL = URL(fileURLWithPath: candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "ffprobe")
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

private func parseProgress(from buffer: String, duration: Double) -> Double? {
    let pattern = #"time=(\d+):(\d+):([\d.]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.lastMatch(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)) else { return nil }
    let h = Double((buffer as NSString).substring(with: match.range(at: 1))) ?? 0
    let m = Double((buffer as NSString).substring(with: match.range(at: 2))) ?? 0
    let s = Double((buffer as NSString).substring(with: match.range(at: 3))) ?? 0
    return min((h * 3600 + m * 60 + s) / duration, 0.99)
}

extension NSRegularExpression {
    func lastMatch(in string: String, range: NSRange) -> NSTextCheckingResult? {
        matches(in: string, range: range).last
    }
}
