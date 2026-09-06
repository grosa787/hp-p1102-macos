import Foundation
import PDFKit
import AppKit

// MARK: - Shell helpers

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    /// Run a command with an argument array. No shell is involved, so there is
    /// no quoting or word-splitting to get wrong.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CommandResult(status: p.terminationStatus,
                             stdout: String(decoding: o, as: UTF8.self),
                             stderr: String(decoding: e, as: UTF8.self))
    }
}

// MARK: - CUPS queue discovery

struct Printer: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

enum CUPS {
    static func printers() -> [Printer] {
        let r = Shell.run("/usr/bin/lpstat", ["-p"])
        // lines look like: "printer HP_LaserJet_P1102 is idle.  enabled since ..."
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "printer" else { return nil }
            return Printer(name: String(parts[1]))
        }
    }

    static func defaultPrinter() -> String? {
        let r = Shell.run("/usr/bin/lpstat", ["-d"])
        // "system default destination: NAME"
        guard let colon = r.stdout.firstIndex(of: ":") else { return nil }
        let name = r.stdout[r.stdout.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Submit a file; returns the CUPS job id (e.g. "HP_LaserJet_P1102-512").
    static func submit(file: URL, printer: String, title: String) throws -> String {
        let r = Shell.run("/usr/bin/lp", ["-d", printer, "-t", title, file.path])
        guard r.status == 0 else {
            throw DuplexError.printFailed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // "request id is HP_LaserJet_P1102-512 (1 file(s))"
        let words = r.stdout.split(separator: " ")
        guard let idx = words.firstIndex(of: "is"), idx + 1 < words.count else {
            throw DuplexError.printFailed("Unexpected response from lp: \(r.stdout)")
        }
        return String(words[idx + 1])
    }

    /// True while the job is still queued or printing.
    static func isPending(job: String, printer: String) -> Bool {
        let r = Shell.run("/usr/bin/lpstat", ["-o", printer])
        return r.stdout.split(separator: "\n").contains { $0.hasPrefix(job + " ") || $0.hasPrefix(job + "\t") }
    }

    /// The queue's current state line, for surfacing "stopped" / errors.
    static func printerStatus(_ printer: String) -> String {
        let r = Shell.run("/usr/bin/lpstat", ["-p", printer])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cancel(job: String) {
        Shell.run("/usr/bin/cancel", [job])
    }
}

// MARK: - Errors

enum DuplexError: LocalizedError {
    case cannotOpen(URL)
    case emptyDocument
    case printFailed(String)
    case cancelled
    case printerStopped(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let u):  return "Could not open \(u.lastPathComponent) as a PDF."
        case .emptyDocument:      return "The PDF has no pages."
        case .printFailed(let s): return "Printing failed: \(s)"
        case .cancelled:          return "Cancelled."
        case .printerStopped(let s): return "The printer queue reports a problem:\n\(s)"
        }
    }
}

// MARK: - Splitting the document into the two passes

struct DuplexPasses {
    let oddPagesFile: URL       // pass 1
    let evenPagesFile: URL      // pass 2
    let pageCount: Int          // original page count
    let sheetCount: Int         // physical sheets
    let paddedWithBlank: Bool   // true when pageCount was odd
}

enum Splitter {
    /// Build the two pass files.
    ///
    /// Pass 1 is every odd page in reading order. Pass 2 is every even page,
    /// optionally in reverse order — reverse is right for printers that stack
    /// output face-down and feed from the top of the input stack (most desktop
    /// lasers, including the HP P1102). If the page count is odd, a blank page
    /// is appended first so that the last sheet's back is "printed" (blank)
    /// rather than receiving the wrong page.
    static func split(source: URL, reverseEven: Bool) throws -> DuplexPasses {
        guard let doc = PDFDocument(url: source) else { throw DuplexError.cannotOpen(source) }
        let n = doc.pageCount
        guard n > 0 else { throw DuplexError.emptyDocument }

        var pages: [PDFPage] = (0..<n).compactMap { doc.page(at: $0) }
        var padded = false
        if pages.count % 2 == 1 {
            pages.append(blankPage(like: pages.last!))
            padded = true
        }

        let odd  = PDFDocument()
        let even = PDFDocument()
        var evenIndices = Array(stride(from: 1, to: pages.count, by: 2))
        if reverseEven { evenIndices.reverse() }

        for (k, i) in stride(from: 0, to: pages.count, by: 2).enumerated() {
            odd.insert(copy(pages[i]), at: k)
        }
        for (k, i) in evenIndices.enumerated() {
            even.insert(copy(pages[i]), at: k)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplexHelper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let oddURL  = dir.appendingPathComponent("\(base) - pass 1 (odd).pdf")
        let evenURL = dir.appendingPathComponent("\(base) - pass 2 (even).pdf")
        guard odd.write(to: oddURL), even.write(to: evenURL) else {
            throw DuplexError.printFailed("Could not write the temporary pass files.")
        }
        return DuplexPasses(oddPagesFile: oddURL, evenPagesFile: evenURL,
                            pageCount: n, sheetCount: pages.count / 2,
                            paddedWithBlank: padded)
    }

    private static func copy(_ page: PDFPage) -> PDFPage {
        (page.copy() as? PDFPage) ?? page
    }

    private static func blankPage(like page: PDFPage) -> PDFPage {
        let size = page.bounds(for: .mediaBox).size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return PDFPage(image: image) ?? PDFPage()
    }

    /// A 4-page test document used by calibration: big page numbers, an
    /// arrow marking the top edge, and FRONT/BACK labels.
    static func calibrationDocument() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Duplex Helper calibration.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 points; scales to Letter fine
        // Draw straight into a PDF context so the text stays vector and prints
        // crisply, rather than as a 72-dpi bitmap.
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw DuplexError.printFailed("Could not create the calibration file.")
        }
        for i in 1...4 {
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc

            let para = NSMutableParagraphStyle(); para.alignment = .center
            func draw(_ s: String, _ pt: CGFloat, y: CGFloat, weight: NSFont.Weight = .bold) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: pt, weight: weight),
                    .paragraphStyle: para, .foregroundColor: NSColor.black]
                let r = NSRect(x: 40, y: y, width: box.width - 80, height: pt * 1.3)
                (s as NSString).draw(in: r, withAttributes: attrs)
            }
            draw("▲ TOP EDGE", 22, y: box.height - 80, weight: .semibold)
            draw("\(i)", 300, y: box.height / 2 - 150)
            draw(i % 2 == 1 ? "FRONT of sheet \((i + 1) / 2)" : "BACK of sheet \(i / 2)", 28, y: 130)
            draw("Duplex Helper calibration page", 14, y: 60, weight: .regular)

            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
