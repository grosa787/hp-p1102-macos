import Foundation
import SwiftUI

/// How this particular printer stacks and feeds paper. Persisted per queue.
struct DuplexSettings: Codable, Equatable {
    /// Print even pages last-to-first. Correct for printers that stack output
    /// face-down and feed from the top of the input stack (most desktop lasers).
    var reverseEven = true
    /// Reinsert the stack with the printed side facing up (rare).
    var printedSideUp = false
    /// Rotate the stack 180° before reinserting so backs are the right way up
    /// for book-style (long-edge) reading.
    var rotate180 = false

    static func load(for printer: String) -> DuplexSettings {
        guard let data = UserDefaults.standard.data(forKey: key(printer)),
              let s = try? JSONDecoder().decode(DuplexSettings.self, from: data) else {
            return DuplexSettings()
        }
        return s
    }

    func save(for printer: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(printer))
        }
    }

    private static func key(_ printer: String) -> String { "duplex.settings.\(printer)" }

    /// Step-by-step reinsertion instructions for these settings.
    var reinsertSteps: [String] {
        var steps = [
            "Take the whole stack out of the output tray. Keep the sheets exactly in the order they came out — don't shuffle them and don't turn the stack over.",
        ]
        if rotate180 {
            steps.append("Rotate the stack 180° flat on the table, so the top edge now points the opposite way.")
        }
        if printedSideUp {
            steps.append("Put the stack in the input tray with the printed side facing UP.")
        } else {
            steps.append("Put the stack in the input tray with the printed side facing DOWN — the same way it was lying in the output tray.")
        }
        steps.append("Make sure the printer's Ready light is on, then press Continue.")
        return steps
    }
}

@MainActor
final class DuplexModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case printingOdd(job: String)
        case waitingForFlip
        case printingEven(job: String)
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .printingOdd, .printingEven: return true
            default: return false
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var sourceURL: URL?
    @Published var pageCount: Int?
    @Published var loadError: String?

    @Published var printers: [Printer] = []
    @Published var selectedPrinter: String = "" {
        didSet {
            guard oldValue != selectedPrinter else { return }
            settings = DuplexSettings.load(for: selectedPrinter)
            UserDefaults.standard.set(selectedPrinter, forKey: "duplex.lastPrinter")
        }
    }
    @Published var settings = DuplexSettings() {
        didSet { if !selectedPrinter.isEmpty { settings.save(for: selectedPrinter) } }
    }

    @Published private(set) var passes: DuplexPasses?
    @Published private(set) var isCalibrating = false

    private var task: Task<Void, Never>?

    init() {
        refreshPrinters()
    }

    // MARK: Document

    func load(url: URL) {
        loadError = nil
        guard url.pathExtension.lowercased() == "pdf",
              let doc = PDFKitDocument(url: url) else {
            sourceURL = nil; pageCount = nil
            loadError = "\(url.lastPathComponent) is not a PDF I can open."
            return
        }
        sourceURL = url
        pageCount = doc.pageCount
        if case .done = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    var sheetCount: Int? {
        guard let n = pageCount else { return nil }
        return (n + 1) / 2
    }

    // MARK: Printers

    func refreshPrinters() {
        let found = CUPS.printers()
        printers = found
        let remembered = UserDefaults.standard.string(forKey: "duplex.lastPrinter")
        let preferred = [remembered, "HP_LaserJet_P1102", CUPS.defaultPrinter()]
            .compactMap { $0 }
            .first { name in found.contains { $0.name == name } }
        let chosen = preferred ?? found.first?.name ?? ""
        if selectedPrinter != chosen {
            selectedPrinter = chosen
        } else if settings == DuplexSettings() {
            settings = DuplexSettings.load(for: chosen)
        }
    }

    // MARK: Flow

    func start(calibration: Bool = false) {
        guard !selectedPrinter.isEmpty else {
            phase = .failed("No printer selected."); return
        }
        let printer = selectedPrinter
        let reverse = settings.reverseEven
        let source = sourceURL
        isCalibrating = calibration
        phase = .preparing

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let src: URL
                if calibration {
                    src = try Splitter.calibrationDocument()
                } else {
                    guard let s = source else { throw DuplexError.cannotOpen(URL(fileURLWithPath: "/")) }
                    src = s
                }
                let p = try Splitter.split(source: src, reverseEven: reverse)
                await MainActor.run { self.passes = p }

                let title = "\(src.deletingPathExtension().lastPathComponent) (odd pages)"
                let job = try CUPS.submit(file: p.oddPagesFile, printer: printer, title: title)
                await MainActor.run { self.phase = .printingOdd(job: job) }
                try await self.waitForJob(job, printer: printer)
                await MainActor.run { self.phase = .waitingForFlip }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    func continueAfterFlip() {
        guard case .waitingForFlip = phase, let p = passes else { return }
        let printer = selectedPrinter
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let base = p.oddPagesFile.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: " - pass 1 (odd)", with: "")
                let job = try CUPS.submit(file: p.evenPagesFile, printer: printer,
                                          title: "\(base) (even pages)")
                await MainActor.run { self.phase = .printingEven(job: job) }
                try await self.waitForJob(job, printer: printer)
                await MainActor.run { self.phase = .done }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        switch phase {
        case .printingOdd(let job), .printingEven(let job): CUPS.cancel(job: job)
        default: break
        }
        phase = .idle
        isCalibrating = false
    }

    func reset() {
        phase = .idle
        isCalibrating = false
        passes = nil
    }

    /// Used only by `--snapshot` to render each screen without a printer.
    func debugSet(phase: Phase, calibrating: Bool = false) {
        self.phase = phase
        self.isCalibrating = calibrating
    }

    private func fail(_ error: Error) {
        if error is CancellationError { phase = .idle; return }
        phase = .failed(error.localizedDescription)
    }

    /// Poll CUPS until the job leaves the queue. Surfaces a stopped queue.
    private func waitForJob(_ job: String, printer: String) async throws {
        var ticks = 0
        while CUPS.isPending(job: job, printer: printer) {
            try Task.checkCancellation()
            ticks += 1
            if ticks % 4 == 0 {
                let status = CUPS.printerStatus(printer).lowercased()
                if status.contains("disabled") || status.contains("stopped") || status.contains("paused") {
                    CUPS.cancel(job: job)
                    throw DuplexError.printerStopped(CUPS.printerStatus(printer))
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // The queue empties when the data has been handed to the printer, which
        // is a moment or two before the last sheet actually lands in the tray.
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: Calibration outcome

    enum OrderResult: String, CaseIterable, Identifiable {
        case correct = "Page 2 is on the back of page 1"
        case swapped = "Page 4 is on the back of page 1"
        case overprinted = "Backs are blank, or pages printed on top of each other"
        var id: String { rawValue }
    }
    enum OrientationResult: String, CaseIterable, Identifiable {
        case correct = "Page 2 is the right way up"
        case upsideDown = "Page 2 is upside down"
        var id: String { rawValue }
    }

    func applyCalibration(order: OrderResult, orientation: OrientationResult) {
        var s = settings
        switch order {
        case .correct: break
        case .swapped: s.reverseEven.toggle()
        case .overprinted:
            // Turning the stack over also reverses the sheet order.
            s.printedSideUp.toggle()
            s.reverseEven.toggle()
        }
        if orientation == .upsideDown { s.rotate180.toggle() }
        settings = s
        reset()
    }
}

// Small indirection so Model.swift does not need to import PDFKit directly.
import PDFKit
typealias PDFKitDocument = PDFDocument
