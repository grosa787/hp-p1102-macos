// Exercises Splitter against a real PDF and prints the page order of each
// pass, read back from the generated files. Build & run with:
//   swiftc -swift-version 5 Sources/Printing.swift Tests/main.swift -o /tmp/splittest
//   /tmp/splittest five.pdf
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: splittest file.pdf"); exit(2) }
let src = URL(fileURLWithPath: args[1])

func labels(_ url: URL) -> [String] {
    guard let d = PDFDocument(url: url) else { return ["<unreadable>"] }
    return (0..<d.pageCount).map { i in
        let t = d.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "blank" : t
    }
}

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print((cond ? "  ok   " : "  FAIL ") + msg)
    if !cond { failures += 1 }
}

for reverse in [true, false] {
    let p = try Splitter.split(source: src, reverseEven: reverse)
    let odd = labels(p.oddPagesFile), even = labels(p.evenPagesFile)
    print("reverseEven=\(reverse): pages=\(p.pageCount) sheets=\(p.sheetCount) padded=\(p.paddedWithBlank)")
    print("  pass 1 (odd):  \(odd)")
    print("  pass 2 (even): \(even)")
    check(p.pageCount == 5 && p.sheetCount == 3 && p.paddedWithBlank, "5 pages -> 3 sheets, padded")
    check(odd == ["1", "3", "5"], "odd pass is 1,3,5")
    check(even == (reverse ? ["blank", "4", "2"] : ["2", "4", "blank"]),
          reverse ? "even pass is blank,4,2 (reversed)" : "even pass is 2,4,blank")
    // Every sheet's back must pair with its front.
    let evenInOrder = reverse ? Array(even.reversed()) : even
    check(evenInOrder.count == odd.count, "one back per front")
}

let cal = try Splitter.calibrationDocument()
let calPages = labels(cal).map { $0.split(separator: "\n").first.map(String.init) ?? "" }
print("calibration doc: \(PDFDocument(url: cal)?.pageCount ?? -1) pages, first lines: \(calPages)")
check(PDFDocument(url: cal)?.pageCount == 4, "calibration doc has 4 pages")

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
