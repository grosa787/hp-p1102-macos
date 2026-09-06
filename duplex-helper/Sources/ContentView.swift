import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: DuplexModel
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.phase {
                    case .idle, .failed:
                        setupSection
                    case .preparing, .printingOdd, .printingEven:
                        progressSection
                    case .waitingForFlip:
                        flipSection
                    case .done:
                        doneSection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { model.load(url: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenPanel)) { _ in
            showImporter = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplex Helper").font(.title2.bold())
                Text("Two-sided printing on a one-sided printer")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: Idle / setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            dropZone

            if let err = model.loadError {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }

            GroupBox("Printer") {
                HStack {
                    Picker("", selection: $model.selectedPrinter) {
                        ForEach(model.printers) { p in
                            Text(p.name).tag(p.name)
                        }
                    }
                    .labelsHidden()
                    Button { model.refreshPrinters() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the printer list")
                }
                .padding(.top, 4)
            }

            GroupBox {
                DisclosureGroup(isExpanded: $showSettings) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Print even pages in reverse order", isOn: $model.settings.reverseEven)
                        Toggle("Reinsert with the printed side facing up", isOn: $model.settings.printedSideUp)
                        Toggle("Rotate the stack 180° before reinserting", isOn: $model.settings.rotate180)
                        Text("These describe how this printer stacks and feeds paper. The defaults are right for the HP LaserJet P1102 and most desktop lasers. If two-sided output comes out wrong, run the calibration once and answer two questions — it fixes the settings for you.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Print calibration test (2 sheets)…") { model.start(calibration: true) }
                            .disabled(model.selectedPrinter.isEmpty)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("How this printer handles paper", systemImage: "gearshape")
                }
            }

            if case .failed(let msg) = model.phase {
                Label(msg, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    model.start()
                } label: {
                    Label("Print two-sided", systemImage: "printer")
                        .frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.sourceURL == nil || model.selectedPrinter.isEmpty)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            if let url = model.sourceURL, let n = model.pageCount, let sheets = model.sheetCount {
                Image(systemName: "doc.richtext").font(.system(size: 36)).foregroundStyle(.tint)
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(n) page\(n == 1 ? "" : "s") → \(sheets) sheet\(sheets == 1 ? "" : "s")\(n % 2 == 1 ? " (last back left blank)" : "")")
                    .foregroundStyle(.secondary)
                Button("Choose another PDF…") { showImporter = true }
                    .buttonStyle(.link)
            } else {
                Image(systemName: "arrow.down.doc").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Drop a PDF here").font(.headline)
                Button("Choose PDF…") { showImporter = true }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let u = item as? URL { url = u }
                if let url { DispatchQueue.main.async { model.load(url: url) } }
            }
            return true
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIndicator
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 4) {
                    Text(progressTitle).font(.headline)
                    Text(progressDetail).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            Button("Cancel", role: .cancel) { model.cancel() }
        }
    }

    private var progressTitle: String {
        switch model.phase {
        case .preparing: return "Preparing pages…"
        case .printingOdd: return "Pass 1 of 2 — printing the odd pages"
        case .printingEven: return "Pass 2 of 2 — printing the even pages"
        default: return ""
        }
    }

    private var progressDetail: String {
        guard let p = model.passes else { return "Splitting the document into two passes." }
        switch model.phase {
        case .printingOdd:  return "\(p.sheetCount) sheet\(p.sheetCount == 1 ? "" : "s") going to \(model.selectedPrinter). Wait for the last one to come out."
        case .printingEven: return "Printing onto the backs of the \(p.sheetCount) sheet\(p.sheetCount == 1 ? "" : "s")."
        default: return ""
        }
    }

    // MARK: Flip

    private var flipSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIndicator
            Label("Pass 1 is done. Now turn the stack around.", systemImage: "checkmark.circle.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(model.settings.reinsertSteps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(i + 1)")
                            .font(.callout.bold()).frame(width: 24, height: 24)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))

            if let p = model.passes, p.paddedWithBlank {
                Label("The page count is odd, so the back of the last sheet will be left blank.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { model.cancel() }
                Spacer()
                Button {
                    model.continueAfterFlip()
                } label: {
                    Label("Continue — print the backs", systemImage: "printer")
                        .frame(minWidth: 200)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Done

    @State private var orderResult: DuplexModel.OrderResult = .correct
    @State private var orientationResult: DuplexModel.OrientationResult = .correct

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIndicator
            Label(model.isCalibrating ? "Calibration pages printed" : "Done — both sides printed",
                  systemImage: "checkmark.seal.fill")
                .font(.title3.bold()).foregroundStyle(.green)

            if model.isCalibrating {
                Text("Look at the two sheets and answer these:")
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Page order", selection: $orderResult) {
                            ForEach(DuplexModel.OrderResult.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        Divider()
                        Picker("Orientation (flip a sheet over like a book page)", selection: $orientationResult) {
                            ForEach(DuplexModel.OrientationResult.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                    }
                    .padding(.top, 4)
                }
                HStack {
                    Spacer()
                    Button("Save settings") {
                        model.applyCalibration(order: orderResult, orientation: orientationResult)
                        orderResult = .correct; orientationResult = .correct
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                if orderResult != .correct || orientationResult != .correct {
                    Text("After saving, run the calibration once more to confirm.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Print another") { model.reset() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Step indicator

    private var stepIndicator: some View {
        let current: Int = {
            switch model.phase {
            case .preparing, .printingOdd: return 1
            case .waitingForFlip: return 2
            case .printingEven: return 3
            case .done: return 4
            default: return 0
            }
        }()
        let names = ["Odd pages", "Turn stack", "Even pages"]
        return HStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                let n = i + 1
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(n < current ? Color.green : (n == current ? Color.accentColor : Color.secondary.opacity(0.25)))
                            .frame(width: 22, height: 22)
                        if n < current {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(n)").font(.caption.bold()).foregroundStyle(n == current ? .white : .secondary)
                        }
                    }
                    Text(name).font(.callout).foregroundStyle(n == current ? .primary : .secondary)
                }
                if i < names.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).padding(.horizontal, 8)
                }
            }
        }
    }
}
