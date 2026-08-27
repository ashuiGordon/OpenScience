import Darwin
import Foundation

struct BoundedProcessTermination: Sendable {
    let exitCode: Int32
    let timedOut: Bool
}

private final class ProcessTerminationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedProcessTermination, Error>?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var timedOut = false

    func run(
        _ process: Process,
        timeout: TimeInterval,
        afterLaunch: @escaping @Sendable () -> Void
    ) async throws -> BoundedProcessTermination {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            process.terminationHandler = { [weak self] completed in
                self?.finish(.success(completed.terminationStatus))
            }
            do {
                try process.run()
                afterLaunch()
                scheduleTimeout(for: process, seconds: timeout)
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func scheduleTimeout(for process: Process, seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.001, seconds))
        timer.setEventHandler { [weak self, weak process] in
            guard let self, let process else { return }
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            timedOut = true
            lock.unlock()

            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }

        lock.lock()
        if finished {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func finish(_ result: Result<Int32, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        let timedOut = self.timedOut
        lock.unlock()

        timer?.cancel()
        switch result {
        case let .success(exitCode):
            continuation?.resume(returning: BoundedProcessTermination(exitCode: exitCode, timedOut: timedOut))
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}

enum BoundedProcess {
    static func run(
        _ process: Process,
        timeout: TimeInterval,
        afterLaunch: @escaping @Sendable () -> Void = {}
    ) async throws -> BoundedProcessTermination {
        try await ProcessTerminationCoordinator().run(
            process,
            timeout: timeout,
            afterLaunch: afterLaunch
        )
    }

    /// Drain only bytes already available in the pipe. A forked descendant cannot keep this read
    /// blocked after the supervised process exits or times out.
    static func drainAvailable(from handle: FileHandle, maximumBytes: Int) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while result.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return result
    }
}

private final class PIDTerminationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedProcessTermination, Never>?
    private var source: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var timedOut = false

    func wait(pid: pid_t, timeout: TimeInterval) async -> BoundedProcessTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in self?.finish(pid: pid) }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + max(0.001, timeout))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                timedOut = true
                lock.unlock()
                Darwin.kill(pid, SIGTERM)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            lock.lock()
            self.source = source
            self.timer = timer
            lock.unlock()
            source.resume()
            timer.resume()
        }
    }

    private func finish(pid: pid_t) {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        let exitCode: Int32
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            exitCode = (status >> 8) & 0xff
        } else if terminationSignal != 0x7f {
            exitCode = 128 + terminationSignal
        } else {
            exitCode = 1
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let source = self.source
        self.source = nil
        let timer = self.timer
        self.timer = nil
        let timedOut = self.timedOut
        lock.unlock()
        source?.cancel()
        timer?.cancel()
        continuation?.resume(
            returning: BoundedProcessTermination(exitCode: exitCode, timedOut: timedOut)
        )
    }
}

enum BoundedPIDProcess {
    static func wait(pid: pid_t, timeout: TimeInterval) async -> BoundedProcessTermination {
        await PIDTerminationCoordinator().wait(pid: pid, timeout: timeout)
    }
}
