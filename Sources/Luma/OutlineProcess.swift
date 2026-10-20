import AppKit
import Foundation
import LumaCore
import PDFKit

/// Works out an outline from a document's text in a process of its own.
///
/// Reading a whole document's text makes the system engine keep about a megabyte a page that it does
/// not give back. A helper process — this same program, started with `flag` — reads the file, writes
/// the outline to its output and exits, and everything it read goes with it. One helper runs at a
/// time; the others wait their turn, and a job whose tab is closed is dropped or stopped.
enum OutlineProcess {
    static let flag = "--work-out-outline"
    /// A helper that has not answered by then is stopped, and the document goes without. The helper
    /// keeps a slightly shorter limit of its own, in case the reader is gone and cannot stop it.
    static let timeLimit: TimeInterval = 30
    static let helperTimeLimit: TimeInterval = 25

    /// In the helper: when started with `flag` and a file, writes that file's outline out and exits.
    /// Returns when the program was started normally.
    static func runIfAsked() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == flag else { return }
        // No icon in the Dock or the app switcher, no menu: a worker, not a second copy of the reader.
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Gone when the reader is gone, and never longer than its limit.
        let parent = getppid()
        if parent <= 1 { exit(3) }
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        watch.setEventHandler { exit(3) }
        watch.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + helperTimeLimit) { exit(2) }

        var entries: [OutlineEntry] = []
        if let document = PDFDocument(url: URL(fileURLWithPath: arguments[2])), !document.isLocked,
           DocumentOutline.entries(of: document).isEmpty {
            entries = OutlineDecoder.entries(of: document)
        }
        FileHandle.standardOutput.write(DocumentOutline.encoded(entries))
        exit(0)
    }

    /// A request for an outline; `cancel()` drops it if it is waiting, or stops its helper if running.
    final class Job {
        fileprivate let url: URL
        fileprivate let pageCount: Int
        fileprivate let completion: ([OutlineEntry]) -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?

        fileprivate init(url: URL, pageCount: Int, completion: @escaping ([OutlineEntry]) -> Void) {
            self.url = url
            self.pageCount = pageCount
            self.completion = completion
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if let running, running.isRunning { running.terminate() }
        }

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// Keeps hold of the helper while it runs; false when the job was cancelled first.
        fileprivate func attach(_ process: Process?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            return !cancelled
        }
    }

    /// Helpers run one after another on this queue.
    private static let queue = DispatchQueue(label: "outline helpers", qos: .utility)

    /// Asks for the outline of the file at `url`; `completion` is called on the main thread with it,
    /// empty when none could be worked out, and not at all when the job is cancelled.
    static func start(for url: URL, pageCount: Int, completion: @escaping ([OutlineEntry]) -> Void) -> Job {
        let job = Job(url: url, pageCount: pageCount, completion: completion)
        queue.async { run(job) }
        return job
    }

    private static func run(_ job: Job) {
        guard !job.isCancelled, let program = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = program
        process.arguments = [flag, job.url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var entries: [OutlineEntry] = []
        do {
            guard job.attach(process) else { return }
            try process.run()
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit, execute: timer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            if process.terminationReason == .exit, process.terminationStatus == 0 {
                entries = DocumentOutline.decoded(data, pageCount: job.pageCount) ?? []
            }
        } catch {
            entries = []
        }
        _ = job.attach(nil)
        guard !job.isCancelled else { return }
        DispatchQueue.main.async { if !job.isCancelled { job.completion(entries) } }
    }
}
