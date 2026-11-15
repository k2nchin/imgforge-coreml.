import UIKit
import Observation

@Observable
@MainActor
final class BatchQueue {

    struct Job: Identifiable {
        let id = UUID()
        let name: String
        let image: UIImage
        var state: State = .pending
        var output: URL?
        var message: String?

        enum State: Equatable {
            case pending, running, done, failed
        }
    }

    private(set) var jobs: [Job] = []
    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    var progress: Double {
        guard !jobs.isEmpty else { return 0 }
        let done = jobs.filter { $0.state == .done || $0.state == .failed }.count
        return Double(done) / Double(jobs.count)
    }

    var summary: String {
        let ok = jobs.filter { $0.state == .done }.count
        let bad = jobs.filter { $0.state == .failed }.count
        return bad == 0 ? "\(ok) de \(jobs.count)" : "\(ok) listas · \(bad) con error"
    }

    var outputs: [URL] { jobs.compactMap(\.output) }

    func enqueue(_ images: [(String, UIImage)]) {
        jobs.append(contentsOf: images.map { Job(name: $0.0, image: $0.1) })
    }

    func clear() {
        cancel()
        jobs.removeAll()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        for i in jobs.indices where jobs[i].state == .running {
            jobs[i].state = .pending
        }
    }

    func start(preset: Preset) {
        guard !isRunning, !jobs.isEmpty else { return }
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            let pending = self.jobs.indices.filter { self.jobs[$0].state != .done }

            for index in pending {
                if Task.isCancelled { break }
                guard index < self.jobs.count else { break }

                self.jobs[index].state = .running
                let image = self.jobs[index].image
                let name = self.jobs[index].name

                do {
                    let url = try await Self.work(image, name: name, preset: preset)
                    guard !Task.isCancelled, index < self.jobs.count else { break }
                    self.jobs[index].output = url
                    self.jobs[index].state = .done
                } catch {
                    guard index < self.jobs.count else { break }
                    self.jobs[index].message = error.localizedDescription
                    self.jobs[index].state = .failed
                }
            }
            self.isRunning = false
        }
    }

    private nonisolated static func work(_ image: UIImage,
                                         name: String,
                                         preset: Preset) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let stem = (name as NSString).deletingPathExtension
            return try ForgeRunner.process(image, preset: preset, stem: stem)
        }.value
    }
}
