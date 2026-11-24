import Foundation
import AppKit

enum PaddingColor: String, CaseIterable, Identifiable {
    case none = "Kein Padding"
    case black = "Schwarz"
    case white = "Weiß"
    case blur = "Unscharf"
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
    var url: URL
    var status: JobStatus = .waiting
    var progress: Double = 0
    var errorMessage: String?
    var originalSize: Int64 = 0
    var outputSize: Int64? = nil
    var isMergeSource: Bool = false

    enum JobStatus {
        case pendingDownload, downloading, waiting, running, done, failed
    }

    var displayName: String {
        url.isFileURL ? url.lastPathComponent : url.absoluteString
    }
}

/// Locates command line tools installed via Homebrew, pip etc.
/// GUI apps don't inherit the shell PATH, so we search the usual places.
enum Tools {
    static let searchDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    static func find(_ name: String) -> String? {
        searchDirs
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpeg: String { find("ffmpeg") ?? "ffmpeg" }
    static var ffprobe: String { find("ffprobe") ?? "ffprobe" }
}

/// Thread-safe text accumulator for process output.
private final class OutputBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

private func processError(_ message: String, code: Int = 1, domain: String = "videoquetsche") -> NSError {
    NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

private func fileSize(_ url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
}

@MainActor
class VideoProcessor: ObservableObject {
    @Published var jobs: [VideoJob] = []
    @Published var isProcessing = false

    private var activeProcess: Process?
    private var processingTask: Task<Void, Never>?

    private var downloadTask: Task<Void, Never>?
    private var activeDownload: (id: UUID, process: Process)?

    static let supportedExtensions = ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "3gp"]

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }

    func addFiles(_ urls: [URL]) {
        // Skip files that are already queued (not yet processed) to avoid duplicates.
        let queued = Set(jobs
            .filter { $0.status == .waiting || $0.status == .running }
            .map { $0.url.standardizedFileURL })
        var seen = queued
        let newJobs = urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { seen.insert($0.standardizedFileURL).inserted }
            .map(makeLocalJob)
        jobs.append(contentsOf: newJobs)
    }

    private func makeLocalJob(_ url: URL) -> VideoJob {
        var job = VideoJob(url: url)
        job.originalSize = fileSize(url) ?? 0
        return job
    }

    func removeJob(id: UUID) {
        if let download = activeDownload, download.id == id {
            download.process.terminate()
            activeDownload = nil
        }
        jobs.removeAll { $0.id == id }
    }

    func clearAll() {
        guard !isProcessing else { return }
        activeDownload?.process.terminate()
        activeDownload = nil
        jobs.removeAll()
    }

    /// Called when the app quits: don't leave orphaned ffmpeg / yt-dlp processes behind.
    func stopAll() {
        cancel()
        downloadTask?.cancel()
        activeDownload?.process.terminate()
        activeDownload = nil
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
        // Picks up jobs that are added while processing (e.g. finished downloads).
        while !Task.isCancelled, let next = jobs.first(where: { $0.status == .waiting }) {
            let id = next.id
            guard let i = index(of: id) else { continue }
            jobs[i].status = .running
            jobs[i].progress = 0

            let url = jobs[i].url
            let outputURL = singleOutputURL(for: url)

            do {
                try await runFFmpeg(input: url, output: outputURL, settings: settings, jobID: id)
                guard let i = index(of: id) else { continue }
                jobs[i].outputSize = fileSize(outputURL)
                jobs[i].status = .done
                jobs[i].progress = 1.0
            } catch {
                guard let i = index(of: id) else { continue }
                if jobs[i].status == .waiting { break } // cancelled
                jobs[i].status = .failed
                jobs[i].errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Merge processing

    private func processMerge(settings: CompressionSettings) async {
        let ids = jobs.filter { $0.status == .waiting }.map(\.id)
        guard ids.count >= 2 else {
            await processQueue(settings: settings)
            return
        }

        func update(_ body: (inout VideoJob) -> Void) {
            for id in ids {
                if let i = index(of: id) { body(&jobs[i]) }
            }
        }

        update {
            $0.status = .running
            $0.isMergeSource = true
            $0.progress = 0
        }

        let urls = ids.compactMap { id in index(of: id).map { jobs[$0].url } }
        let tempList = FileManager.default.temporaryDirectory
            .appendingPathComponent("vq-\(UUID().uuidString).txt")
        let fileList = urls
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")

        guard (try? fileList.write(to: tempList, atomically: true, encoding: .utf8)) != nil else {
            update {
                $0.status = .failed
                $0.errorMessage = "Dateiliste konnte nicht erstellt werden"
            }
            return
        }
        defer { try? FileManager.default.removeItem(at: tempList) }

        let firstURL = urls[0]
        let outputURL = firstURL.deletingLastPathComponent()
            .appendingPathComponent(firstURL.deletingPathExtension().lastPathComponent + "-merged.mp4")

        var totalDuration: Double = 0
        for url in urls {
            if let d = await getVideoDuration(url: url) { totalDuration += d }
        }

        do {
            try await runFFmpegConcat(
                listFile: tempList,
                output: outputURL,
                settings: settings,
                jobIDs: ids,
                totalDuration: totalDuration > 0 ? totalDuration : nil
            )
            let outSize = fileSize(outputURL)
            update {
                $0.outputSize = outSize
                $0.status = .done
                $0.progress = 1.0
            }
        } catch {
            update {
                if $0.status != .waiting {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
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

    private func buildVideoFilter(settings: CompressionSettings) -> String? {
        switch settings.paddingColor {
        case .none:
            if let height = settings.resolution.height {
                return "scale=-2:\(height)"
            }
            return nil

        case .black, .white:
            let color = settings.paddingColor == .black ? "black" : "white"
            if let size = settings.resolution.height {
                return "scale=\(size):\(size):force_original_aspect_ratio=decrease,"
                    + "pad=\(size):\(size):(ow-iw)/2:(oh-ih)/2:\(color)"
            }
            return "scale=trunc(iw/2)*2:trunc(ih/2)*2,"
                + "pad=max(iw\\,ih):max(iw\\,ih):(ow-iw)/2:(oh-ih)/2:\(color)"

        case .blur:
            // Background: the video itself, scaled to fill the square, cropped and blurred.
            // Foreground: the video scaled to fit, centered on top.
            let background: String
            let foreground: String
            if let size = settings.resolution.height {
                background = "scale=\(size):\(size):force_original_aspect_ratio=increase,crop=\(size):\(size)"
                foreground = "scale=\(size):\(size):force_original_aspect_ratio=decrease"
            } else {
                let side = "trunc(max(iw\\,ih)/2)*2"
                let crop = "trunc(min(iw\\,ih)/2)*2"
                background = "scale=\(side):\(side):force_original_aspect_ratio=increase,crop=\(crop):\(crop)"
                foreground = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            }
            return "split=2[vqbg][vqfg];"
                + "[vqbg]\(background),gblur=sigma=40[vqbgb];"
                + "[vqfg]\(foreground)[vqfgs];"
                + "[vqbgb][vqfgs]overlay=(W-w)/2:(H-h)/2,setsar=1"
        }
    }

    private func buildEncodeArgs(settings: CompressionSettings, outputPath: String) -> [String] {
        var args: [String] = []
        if let filter = buildVideoFilter(settings: settings) { args += ["-vf", filter] }
        args += ["-c:v", "libx264", "-crf", "\(settings.crf)", "-preset", "medium", "-pix_fmt", "yuv420p"]
        args += settings.removeAudio ? ["-an"] : ["-c:a", "aac", "-b:a", "96k"]
        args += ["-movflags", "+faststart", outputPath]
        return args
    }

    private func setProgress(_ progress: Double, for ids: [UUID]) {
        for id in ids {
            if let i = index(of: id) { jobs[i].progress = progress }
        }
    }

    private func runFFmpeg(input: URL, output: URL, settings: CompressionSettings, jobID: UUID) async throws {
        let duration = await getVideoDuration(url: input)
        try await runFFmpegProcess(
            arguments: ["-y", "-i", input.path] + buildEncodeArgs(settings: settings, outputPath: output.path),
            jobIDs: [jobID],
            duration: duration
        )
    }

    private func runFFmpegConcat(listFile: URL, output: URL, settings: CompressionSettings, jobIDs: [UUID], totalDuration: Double?) async throws {
        try await runFFmpegProcess(
            arguments: ["-y", "-f", "concat", "-safe", "0", "-i", listFile.path]
                + buildEncodeArgs(settings: settings, outputPath: output.path),
            jobIDs: jobIDs,
            duration: totalDuration
        )
    }

    private func runFFmpegProcess(arguments: [String], jobIDs: [UUID], duration: Double?) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Tools.ffmpeg)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            let buffer = OutputBuffer()

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                buffer.append(str)
                if let duration, duration > 0, let progress = parseProgress(from: str, duration: duration) {
                    Task { @MainActor in self?.setProgress(progress, for: jobIDs) }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let msg = buffer.value.components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? "ffmpeg error"
                    continuation.resume(throwing: processError(msg, code: Int(proc.terminationStatus), domain: "ffmpeg"))
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
            process.executableURL = URL(fileURLWithPath: Tools.ffprobe)
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
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Downloads (yt-dlp)

    /// Folder downloaded videos are saved to (compressed output lands next to them).
    static var downloadDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("Videoquetsche", isDirectory: true)
    }

    /// Parses web links (separated by whitespace / newlines) and queues them for download.
    /// Returns the number of links that were accepted.
    @discardableResult
    func addRemoteURLs(from text: String) -> Int {
        let urls = text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { URL(string: String($0)) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
        for url in urls {
            var job = VideoJob(url: url)
            job.status = .pendingDownload
            jobs.append(job)
        }
        if !urls.isEmpty { startDownloadWorkerIfNeeded() }
        return urls.count
    }

    /// Downloads run one after another in the background, independent of compression.
    private func startDownloadWorkerIfNeeded() {
        guard downloadTask == nil else { return }
        downloadTask = Task {
            while !Task.isCancelled, let next = jobs.first(where: { $0.status == .pendingDownload }) {
                await download(jobID: next.id)
            }
            downloadTask = nil
        }
    }

    private func download(jobID: UUID) async {
        guard let i = index(of: jobID) else { return }
        jobs[i].status = .downloading
        jobs[i].progress = 0
        var source = jobs[i].url

        // Plain m3u playlists (a list of video links) are expanded into one job per entry.
        // HLS streams (.m3u8 with #EXT-X- tags) are handed to yt-dlp as they are.
        if ["m3u", "m3u8"].contains(source.pathExtension.lowercased()),
           let entries = await fetchPlaylistEntries(source), let first = entries.first {
            guard let i = index(of: jobID) else { return }
            source = first
            jobs[i].url = first
            let extra = entries.dropFirst().map { url -> VideoJob in
                var job = VideoJob(url: url)
                job.status = .pendingDownload
                return job
            }
            jobs.insert(contentsOf: extra, at: i + 1)
        }

        do {
            let files = try await runYtDlp(url: source, jobID: jobID)
            guard let i = index(of: jobID) else { return } // removed meanwhile
            guard let first = files.first else {
                throw processError("Download lieferte keine Datei")
            }
            jobs[i].url = first
            jobs[i].status = .waiting
            jobs[i].progress = 0
            jobs[i].originalSize = fileSize(first) ?? 0
            jobs.insert(contentsOf: files.dropFirst().map(makeLocalJob), at: i + 1)
        } catch {
            guard let i = index(of: jobID) else { return }
            jobs[i].status = .failed
            jobs[i].errorMessage = error.localizedDescription
        }
    }

    private func fetchPlaylistEntries(_ url: URL) async -> [URL]? {
        guard let response = try? await URLSession.shared.data(from: url) else { return nil }
        let data = response.0
        guard data.count < 5_000_000,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.contains("#EXT-X-") // HLS stream → yt-dlp handles it
        else { return nil }

        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))
        let entries = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        return entries.isEmpty ? nil : entries
    }

    private func runYtDlp(url: URL, jobID: UUID) async throws -> [URL] {
        guard let ytdlp = Tools.find("yt-dlp") else {
            throw processError("yt-dlp nicht gefunden – installieren mit: brew install yt-dlp")
        }

        let outputDir = Self.downloadDirectory
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // yt-dlp writes the final file path(s) here – more reliable than parsing stdout.
        let pathsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vq-dl-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: pathsFile) }

        var args = [
            "--newline",
            "--no-mtime",
            "--progress-template", "download:VQPROGRESS %(progress._percent_str)s",
            "--merge-output-format", "mp4",
            "-P", outputDir.path,
            "-o", "%(title).150B.%(ext)s",
            "--print-to-file", "after_move:filepath", pathsFile.path,
        ]
        if let ffmpeg = Tools.find("ffmpeg") {
            args += ["--ffmpeg-location", ffmpeg]
        }
        args += ["--", url.absoluteString]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Tools.searchDirs + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = OutputBuffer()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            buffer.append(str)
            if let progress = parseDownloadProgress(from: str) {
                Task { @MainActor in self?.setProgress(progress, for: [jobID]) }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let lines = buffer.value.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    let msg = lines.last(where: { $0.contains("ERROR") }) ?? lines.last ?? "yt-dlp Fehler"
                    continuation.resume(throwing: processError(msg, code: Int(proc.terminationStatus), domain: "yt-dlp"))
                }
            }
            do {
                try process.run()
                self.activeDownload = (jobID, process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if activeDownload?.id == jobID { activeDownload = nil }

        let written = (try? String(contentsOf: pathsFile, encoding: .utf8)) ?? ""
        var seen = Set<String>()
        return written.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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

private func parseDownloadProgress(from buffer: String) -> Double? {
    let pattern = #"VQPROGRESS\s+(?:\x1B\[[0-9;]*m)?\s*([\d.]+)%"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.lastMatch(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)),
          let percent = Double((buffer as NSString).substring(with: match.range(at: 1))) else { return nil }
    return min(max(percent / 100, 0), 0.99)
}

extension NSRegularExpression {
    func lastMatch(in string: String, range: NSRange) -> NSTextCheckingResult? {
        matches(in: string, range: range).last
    }
}
