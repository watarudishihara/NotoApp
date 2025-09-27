import SwiftUI
import PhotosUI
import PencilKit
import WebKit
import UIKit

struct Notebook: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var created: Date
}

struct HomeView: View {
    @EnvironmentObject var store: NotebookStore
    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: {
            if #available(iOS 17.0, *) { return .topBarTrailing } else { return .navigationBarTrailing }
        }()) {
            Button {
                guard let id = store.folders.first?.id else { return }
                _ = store.createNotebook(in: id, title: "New Notebook")
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(store.folders.isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            if let folder = store.folders.first {
                List {
                    ForEach(folder.notebooks) { nb in          // <- use `folder`, not `current`
                        NavigationLink {
                            ContentView(folderID: folder.id, notebookID: nb.id)
                                .navigationTitle(nb.title)
                        } label: {
                            NotebookCard(
                                title: nb.title,
                                updated: nb.updated,
                                cover: store.coverImage(folderID: folder.id, notebookID: nb.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        let ids = idx.map { folder.notebooks[$0].id }
                        ids.forEach { store.deleteNotebook(folderID: folder.id, notebookID: $0) }
                    }
                }
                .navigationTitle("Noto Notebooks")
            } else {
                // First run: create a default folder
                VStack {
                    Text("No folders yet")
                    Button("Create ‘My Notes’") { store.createFolder(name: "My Notes") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar { homeToolbar }
        
    }
}
//struct NotebookTile: View {
//    let title: String
//    let updated: Date
//    let cover: UIImage?
//
//    static let cardWidth: CGFloat = 240
//    static let coverAspect: CGFloat = 4.0/3.0
//    static let textBlockHeight: CGFloat = 48
//    private let aspect: CGFloat = 4.0/5.0
//    
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 8) {
//            // COVER (no background rect here)
//            ZStack {
//                if let cover {
//                    Image(uiImage: cover)
//                        .resizable()
//                        .scaledToFill()
//                } else {
//                    Image(systemName: "pencil.and.outline")
//                        .imageScale(.large)
//                        .foregroundStyle(.secondary)
//                }
//            }
//            .frame(
//                width: Self.cardWidth/aspect,
//                height: Self.cardWidth / Self.coverAspect / aspect
//            )
//            .clipped() // trim any overflow from scaledToFill
//
//            // TEXT (fixed height so all cards match)
//            VStack(alignment: .leading, spacing: 2) {
//                Text(title).font(.headline).lineLimit(2)
//                Text(updated, style: .date)
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//            }
//            .frame(height: Self.textBlockHeight, alignment: .topLeading)
//            .padding(.horizontal, 12)     // ← inset from left/right
//            .padding(.vertical, 2)       // ← breathing room top/bottom
//        }
//        .frame(width: Self.cardWidth)                 // lock width
//        .background(
//            RoundedRectangle(cornerRadius: 16)
//                .fill(Color(UIColor.secondarySystemBackground))
//        )
//        .overlay(
//            RoundedRectangle(cornerRadius: 16)
//                .stroke(.black.opacity(0.08), lineWidth: 0.5)
//        )
//        .clipShape(RoundedRectangle(cornerRadius: 16)) // clip bg + image together
//        .compositingGroup()                            // make shadow clean
//        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
//        .contentShape(Rectangle())
//    }
//}
// MARK: - ContentView
enum ToolType: Equatable {
    case pen
    case marker
    case eraser
    case lasso
    case shape
    case text
}
enum EraseMode: String, CaseIterable, Identifiable {
    case object, pixel
    var id: String { rawValue }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, ellipse
    var id: String { rawValue }
}

struct ContentView: View {
    // NOTE TARGETS
    let folderID: UUID
    let notebookID: UUID

    // Store for load/save
    @EnvironmentObject private var store: NotebookStore

    // Base URL persisted. Simulator uses localhost; device starts empty.
    @AppStorage("baseURL") private var baseURL: String = {
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:8000"
        #else
        return ""
        #endif
    }()
    
    @AppStorage("conversionBackend") private var conversionBackend: String = "server" // "server" | "ondevice"
    
    //Paper Style
    @State var paper: PaperStyle = .plain
    
    //tools
    @State private var strokeWidth: CGFloat = 5

    // Last-picked width per tool
    @State private var penWidth: CGFloat = 5
    @State private var markerWidth: CGFloat = 10   // a bit thicker by default
    
    //eraser
    @State private var eraseMode: EraseMode = .pixel
    @State private var eraserRadius: CGFloat = 12
    @State private var eraserWidthFavorites: [CGFloat] = [8, 20, 50]

    // Viewport from PKCanvasView so we can convert overlay points -> canvas content coords
    @State private var canvasViewport = EraserOverlay.CanvasViewport()

    // 3 quick-swap width presets per tool
    @State private var penWidthFavorites:    [CGFloat] = [3, 5, 8]
    @State private var markerWidthFavorites: [CGFloat] = [8, 12, 18]
    

    // shapes
    @State private var currentShape: ShapeKind = .rectangle
    @State private var shapes: [ShapeItem] = []
    @State private var dragStart: CGPoint? = nil
    @State private var dragRect: CGRect? = nil
    
    @State private var showToolOptions = false  // popover for colors/width/shape

    // canvas undo
    @State private var canvasUndo: UndoManager? = nil
    @State private var currentColor: Color = .black
    @State private var penColor: Color = .black
    @State private var markerColor: Color = .pink
    @State private var penFavorites:    [Color] = [.black, .blue, .red]
    @State private var markerFavorites: [Color] = [.yellow, .pink, .blue]
    
    //textbox
    @State private var textBoxes: [TextBox] = []           // <-- NEW
    @State private var selectedTextBoxID: UUID? = nil      // <-- NEW
    @State private var isTyping = false
    @State private var stackWorkItem: DispatchWorkItem?
    
    // --- UI / note state ---
    @State private var drawing = PKDrawing()
    @State private var pickedImage: UIImage? = nil
    @State private var showCropper = false
    @State private var isConverting = false
    @State private var showSettings = false
    @State private var errorMessage: String? = nil
    @State private var showRightPanel = true
    @State private var panelMode: PanelMode = .preview
    @State private var showShare = false
    @State private var shareURL: URL? = nil
    @State private var currentTool: ToolType = .pen
    @State private var latexText: String = ""      // editor text
    @State private var previewLatex: String = ""   // rendered text
    
    //saves
    @State private var saveWorkItem: DispatchWorkItem?

    // Camera / photos
    @State private var showCamera = false
    @State private var photosItem: PhotosPickerItem?

    // Right panel width
    @State private var panelWidth: CGFloat = 360
    
    //Exporting
    @State private var showExportMenu = false
    @State private var typesetExporter = TypesetExporter() // keep a strong ref
    
    //saving
    @State private var didLoad = false
    
    private var katexBaseURL: URL? {
        Bundle.main.url(forResource: "katex", withExtension: nil) ?? Bundle.main.resourceURL
    }
    // Keep the heavy layout out of `body` so the compiler is happy
    @ViewBuilder
    private var layout: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(UIColor.systemBackground))

            if showRightPanel {
                rightPane
                    .frame(width: panelWidth)
                    .overlay(resizeHandle, alignment: .leading)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // iOS 16/17-safe placements
    private var leadingPlacement: ToolbarItemPlacement {
        if #available(iOS 17.0, *) { return .topBarLeading } else { return .navigationBarLeading }
    }
    private var trailingPlacement: ToolbarItemPlacement {
        if #available(iOS 17.0, *) { return .topBarTrailing } else { return .navigationBarTrailing }
    }

    // Your toolbar, expressed as ToolbarContent (no ambiguity)
    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: leadingPlacement) {
            // Settings
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }

        ToolbarItemGroup(placement: trailingPlacement) {
            Menu {
                Picker("Paper", selection: $paper) {
                    ForEach(PaperStyle.allCases) { style in
                        Text(style.rawValue.capitalized).tag(style)
                    }
                }
            } label: {
                Label("Paper", systemImage: "doc.plaintext")
            }
            .help("Change paper style")
            Button {
                withAnimation(.easeInOut) { showRightPanel.toggle() }
            } label: {
                // pick the icon you like:
                // "sidebar.trailing" / "sidebar.leading" (your original)
                // or "sidebar.right" / "sidebar.left" on iOS 17+
                Image(systemName: showRightPanel ? "sidebar.trailing" : "sidebar.leading")
            }
            .help(showRightPanel ? "Hide LaTeX panel" : "Show LaTeX panel")
            // .keyboardShortcut("[", modifiers: [.command, .shift]) // optional

            // Undo / Redo (these stay as-is)

            // Tool options (colors, thickness, shape picker)
            .popover(isPresented: $showToolOptions, arrowEdge: .top) {
                ToolOptionsPopover(
                    currentTool: $currentTool,
                    currentShape: $currentShape,
                    color: $currentColor,          // <- pass ACTIVE color
                    strokeWidth: $strokeWidth
                )
                .padding()
                .frame(width: 340)
            }

            // Export .tex
            Button {
                showExportMenu = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(latexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }



    // Small helpers so the onChange/.task lines stay tidy
    private func loadNoteAsync() async {
        // show an immediately-writable blank canvas first
        withTransaction(Transaction(animation: nil)) {
            didLoad = false
            drawing = PKDrawing()
            latexText = ""
            previewLatex = ""
            pickedImage = nil
            textBoxes = []
        }

        // load heavy stuff off-main
        let payload = await store.loadNotebookAsync(folderID: folderID, notebookID: notebookID)

        // apply on main without animations to avoid PencilKit jank
        withTransaction(Transaction(animation: nil)) {
            drawing = payload.drawing
            latexText = payload.latexText
            pickedImage = payload.pickedImage
            textBoxes = payload.textBoxes
            didLoad = true
        }
    }

    private func save(updateCover: Bool = false) {
        store.saveContent(folderID: folderID, notebookID: notebookID,
                          drawing: drawing, latexText: latexText, pickedImage: pickedImage,
                          updateCover: updateCover)
        store.saveTextBoxes(folderID: folderID, notebookID: notebookID, boxes: textBoxes)
    }
    
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 20, height: 200) // 200pt tall instead of full height
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newWidth = max(280, min(600, panelWidth - value.translation.width))
                        panelWidth = newWidth
                    }
            )
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(0.4)) // thin line
                    .frame(width: 2, height: 50)       // same shorter height
                    .padding(.leading, -3),              // inset from edge
                alignment: .center
            )
    }


    var body: some View {
        layout                                   // only the big HStack lives here
        // Attach ALL modifiers to the NavigationStack (not the HStack)
            .sheet(isPresented: $showSettings) {
                SettingsView(baseURL: $baseURL, conversionBackend: $conversionBackend)
            }
            .sheet(isPresented: $showCropper) {
                if let img = currentImageForCrop() {
                    CropperSheet(image: img) { self.pickedImage = $0 }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { uiImage in pickedImage = uiImage.fixedOrientation() }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL { ShareSheet(items: [url]) }
            }
            .alert("Error",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { _ in errorMessage = nil })) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage ?? "") }
        
            .task {
                await loadNoteAsync()
            }
            .onChange(of: drawing) { _, _ in if didLoad { save() } }
            .onChange(of: latexText) { _, _ in if didLoad { save() } }
            .onChange(of: panelMode) { _, newMode in
                if newMode == .preview {
                    previewLatex = MiniTeX.render(cleanForKaTeX(latexText))
                }
            }
            .onAppear {
                // Ensure preview is updated when view appears
                if panelMode == .preview {
                    previewLatex = MiniTeX.render(cleanForKaTeX(latexText))
                }
            }
            .onChange(of: pickedImage) { _, _ in if didLoad { save(updateCover: true) } }
            .onChange(of: textBoxes) { _, newVal in
                store.saveTextBoxes(folderID: folderID, notebookID: notebookID, boxes: newVal)
            }
            .onDisappear {
                if didLoad {
                    scheduleSave()
                }
            }
        //exporting
            .confirmationDialog("Export", isPresented: $showExportMenu, titleVisibility: .visible) {
                Button("Typeset PDF (HTML + KaTeX)") { exportTypesetPDF() }
                Button("LaTeX (.tex)") { exportTeX() }
                Button("Cancel", role: .cancel) { }
            }
        
            .toolbar { contentToolbar }
    }// explicit ToolbarContent below

    // MARK: - Views

    private var leftPane: some View {
        VStack(spacing: 0) {
            if let img = pickedImage {
                ZoomableImage(image: Image(uiImage: img))
                    .overlay(alignment: .bottomTrailing) {
                        HStack {
                            Button {
                                showCropper = true
                            } label: {
                                Label("Crop", systemImage: "crop")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(8)

                            Button(role: .destructive) {
                                pickedImage = nil
                            } label: {
                                Label("Clear Image", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .padding(8)
                        }
                    }
            } else {
                CanvasToolBar(
                    currentTool: $currentTool,
                    currentShape: $currentShape,
                    color: $currentColor,
                    strokeWidth: $strokeWidth,
                    showToolOptions: $showToolOptions,
                    penFavorites: $penFavorites,
                    markerFavorites: $markerFavorites,
                    penWidthFavorites: $penWidthFavorites,
                    markerWidthFavorites: $markerWidthFavorites,
                    eraserRadius: $eraserRadius,
                    eraserWidthFavorites: $eraserWidthFavorites,
                    eraseMode: $eraseMode,
                    canUndo: (canvasUndo?.canUndo ?? false),
                    canRedo: (canvasUndo?.canRedo ?? false),
                    onUndo: { canvasUndo?.undo() },
                    onRedo: { canvasUndo?.redo() },
                    onAddTextBox: { addTextBox() }
                )
                ZStack {
                    PencilCanvas(
                        drawing: $drawing,
                        tool: $currentTool,
                        penColor: $currentColor,
                        strokeWidth: $strokeWidth,
                        undoManager: $canvasUndo,
                        eraseMode: $eraseMode,
                        viewport: $canvasViewport,
                        paperStyle: paper
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                    .allowsHitTesting(currentTool != .text)   // <-- NEW
                    // Pixel-eraser overlay (captures polyline and performs stroke splitting)
                    if currentTool == .eraser && eraseMode == .pixel {
                        EraserOverlay(radius: eraserRadius, viewport: $canvasViewport) { polyInCanvas in
                            // Sanity: need at least a segment
                            guard polyInCanvas.count >= 2 else { return }

                            // Radius in canvas space
                            let r = max(0.5, eraserRadius / max(0.001, canvasViewport.zoomScale))

                            // Compute eraser polyline bounds
                            func bounds(of pts: [CGPoint]) -> CGRect {
                                var minX = CGFloat.greatestFiniteMagnitude
                                var minY = CGFloat.greatestFiniteMagnitude
                                var maxX = -CGFloat.greatestFiniteMagnitude
                                var maxY = -CGFloat.greatestFiniteMagnitude
                                for p in pts {
                                    if p.x < minX { minX = p.x }
                                    if p.y < minY { minY = p.y }
                                    if p.x > maxX { maxX = p.x }
                                    if p.y > maxY { maxY = p.y }
                                }
                                if minX > maxX || minY > maxY { return .null }
                                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                            }

                            let polyBounds = bounds(of: polyInCanvas)
                            guard !polyBounds.isNull else { return }
                            // Expand by radius (+ a tiny epsilon to be safe)
                            let expanded = polyBounds.insetBy(dx: -(r + 1.0), dy: -(r + 1.0))

                            // Split drawing into far/near sets using fast bounds test
                            let all = drawing.strokes
                            var near: [PKStroke] = []
                            var far:  [PKStroke] = []
                            near.reserveCapacity(all.count)
                            far.reserveCapacity(all.count)

                            for s in all {
                                // Use renderBounds — it accounts for stroke width
                                if s.renderBounds.intersects(expanded) {
                                    near.append(s)
                                } else {
                                    far.append(s)
                                }
                            }

                            // If nothing is near, exit early
                            guard !near.isEmpty else { return }

                            // Erase only the near subset
                            let nearDrawing = PKDrawing(strokes: near)
                            let erasedNear  = StrokeEraser.erase(nearDrawing, with: polyInCanvas, radius: r)

                            // Merge back (preserve original ordering: far first is fine visually)
                            let merged = PKDrawing(strokes: far + erasedNear.strokes)

                            // Apply + undo registration
                            let before = drawing
                            guard before != merged else { return }

                            drawing = merged
                            let target = DrawingUndoTarget { self.drawing = $0 }

                            canvasUndo?.beginUndoGrouping()
                            canvasUndo?.registerUndo(withTarget: target) { t in
                                let current = self.drawing
                                t.set(before)
                                self.canvasUndo?.registerUndo(withTarget: target) { t2 in
                                    t2.set(current)
                                }
                            }
                            canvasUndo?.setActionName("Erase")
                            canvasUndo?.endUndoGrouping()
                        }
                        .zIndex(10)  // make sure overlay sits above canvas
                        .transition(.opacity)
                    }

                    // Shape overlay ON TOP of the canvas
                    if currentTool == .shape {
                        ShapeDrawOverlay(currentShape: $currentShape,
                                         dragStart: $dragStart,
                                         dragRect: $dragRect,
                                         shapes: $shapes)
                            .allowsHitTesting(true)
                            .transition(.opacity)
                    }

                    // Lasso HUD anchored bottom-trailing
                    if currentTool == .lasso {
                        lassoHUD
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    TextLayer(
                        boxes: $textBoxes,
                        selectedID: $selectedTextBoxID,
                        viewport: canvasViewport,
                        nextDefaultOrigin: { nextTextBoxOrigin() }
                    )
                    .allowsHitTesting(currentTool == .text)
                    .zIndex(12)
                    .transition(.opacity)
                }
                
                .background(Color.white)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onChange(of: currentTool, initial: true) { _, newTool in
            // color handoff (you already had this)
            currentColor = (newTool == .marker) ? markerColor : penColor
            // width handoff
            strokeWidth = (newTool == .marker) ? markerWidth : penWidth
            // NEW: text-mode enter/exit behavior
            if newTool == .text {
                    if textBoxes.isEmpty {
                        let p = nextTextBoxOrigin()
                        let box = TextBox(text: "", x: p.x, y: p.y, width: 520, height: 120, fontSize: 18)
                        textBoxes.append(box)
                        selectedTextBoxID = box.id
                    }
                } else {
                    selectedTextBoxID = nil
                }
        }

        .onChange(of: currentColor) { _, newColor in
            if currentTool == .marker { markerColor = newColor } else { penColor = newColor }
        }

        // remember last-picked width for the active tool
        .onChange(of: strokeWidth) { _, newValue in
            if currentTool == .marker { markerWidth = newValue } else { penWidth = newValue }
        }
    }
    private func addTextBox(select: Bool = true) {
        let p = nextTextBoxOrigin()
        let box = TextBox(text: "", x: p.x, y: p.y, width: 520, height: 120, fontSize: 18)
        textBoxes.append(box)
        if select { selectedTextBoxID = box.id }
        stackOnIdle()
    }

    // Debounced restack (NO capture list; structs don't need [weak self])
    private func stackOnIdle() {
        stackWorkItem?.cancel()
        let wi = DispatchWorkItem {
            if !isTyping { stackTextColumn() }
        }
        stackWorkItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: wi)
    }

    // Lay boxes in a single left-aligned column under lowest ink
    private func stackTextColumn(left: CGFloat = 48, spacing: CGFloat = 16) {
        let inkBottom = drawing.strokes.map { $0.renderBounds.maxY }.max() ?? 48
        var yCursor = max(inkBottom, 48)

        // Keep identities; only move in place to avoid UITextView rebuilds
        let order = textBoxes
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(\.id)

        for id in order {
            guard let idx = textBoxes.firstIndex(where: { $0.id == id }) else { continue }
            textBoxes[idx].x = left
            textBoxes[idx].y = round(yCursor + spacing)
            yCursor = textBoxes[idx].y + textBoxes[idx].height
        }
    }
    /// Stacks all text boxes into a single left-aligned column, honoring handwriting bottom.
    /// Call after height changes or when adding a box.
    private func nextTextBoxOrigin(left: CGFloat = 48,
                                   top: CGFloat = 48,
                                   spacing: CGFloat = 16) -> CGPoint {
        // Lowest ink (in canvas coords)
        let inkBottom = drawing.strokes.map { $0.renderBounds.maxY }.max() ?? top
        // Lowest text box
        let textBottom = textBoxes.map { $0.y + $0.height }.max() ?? top
        let y = max(inkBottom, textBottom) + spacing
        return CGPoint(x: left, y: y)
    }
    private var lassoHUD: some View {
        HStack(spacing: 8) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy), to: nil, from: nil, for: nil)
            } label: { Label("Copy", systemImage: "doc.on.doc") }

            Button {
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy), to: nil, from: nil, for: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste), to: nil, from: nil, for: nil)
                }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

            Button(role: .destructive) {
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.delete), to: nil, from: nil, for: nil)
            } label: { Label("Delete", systemImage: "trash") }
        }
        .buttonStyle(.borderedProminent)
        .tint(.secondary)
    }

    private var rightPane: some View {
        VStack(spacing: 8) {
            Picker("", selection: $panelMode) {
                Text("Editor").tag(PanelMode.editor)
                Text("Preview").tag(PanelMode.preview)
            }
            .pickerStyle(.segmented)
            .padding([.top, .horizontal])

            switch panelMode {
            case .editor:
                TextEditor(text: $latexText)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

            case .preview:
                Group {
                    if previewLatex.isEmpty {
                        VStack(spacing: 8) {
                            Text("Nothing to render yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Button {
                                previewLatex = MiniTeX.render(cleanForKaTeX(latexText))
                            } label: {
                                Label("Render LaTeX", systemImage: "eye")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PseudoLatexPreview(text: previewLatex)
                            .id(previewLatex.hashValue) // refresh only when content actually changes
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .background(Color.white)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                .padding()
            }

            Spacer()

            HStack {
                Button {
                    previewLatex = latexText  // copy whatever is in editor into preview
                    withAnimation { panelMode = .preview }
                } label: {
                    Label("Render LaTeX", systemImage: "eye")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await convertCurrent() }
                } label: {
                    if isConverting {
                        ProgressView()
                    } else {
                        Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConverting || !isServerConfigured)
            }
            .padding(.bottom, 12)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: Convert

    private var isServerConfigured: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
    }
    private func makeConverter() -> LatexConverting {
        let key = (Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String) ?? ""
        return NetworkLatexConverter(apiKey: key)
    }

    private func convertCurrent() async {
        isConverting = true
        defer { isConverting = false }

        do {
            let conv = makeConverter()
            guard let img = snapshotForConversion() else { throw LatexServiceError.imageEncodingFailed }
            let latex = try await conv.convert(image: img)

            await MainActor.run {
                latexText = latex
                if panelMode == .preview {
                    previewLatex = MiniTeX.render(cleanForKaTeX(latex))
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // Your .alert is already bound to errorMessage != nil, so no separate showError flag needed
            }
        }
    }
    private func snapshotForConversion() -> UIImage? {
        // If a photo was picked/cropped, use that
        if let img = currentImageForCrop() { return img }

        // Take the PencilKit drawing itself
        let pad: CGFloat = 24
        var rect = drawing.bounds.insetBy(dx: -pad, dy: -pad)
        if rect.isNull || rect.isEmpty {
            // Fallback if page is blank
            rect = CGRect(origin: .zero, size: CGSize(width: 1024, height: 1024))
        }

        // Supersample and then composite onto white (better OCR than transparent)
        let scale = UIScreen.main.scale * 2.0
        let raw = drawing.image(from: rect, scale: scale)   // transparent bg

        let renderer = UIGraphicsImageRenderer(size: raw.size)
        let composited = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: raw.size))
            raw.draw(at: .zero)
        }

        let bytes = composited.pngData()?.count ?? -1
        print("Noto::Snapshot size=\(composited.size) scale=\(composited.scale) bytes=\(bytes)")
        return composited
    }

    private var canvasRect: CGRect {
        // safe fallback if drawing.bounds is empty
        CGRect(origin: .zero, size: CGSize(width: 1024, height: 1024))
    }




    private func currentImageForCrop() -> UIImage? {
        if let img = pickedImage { return img }
        return nil
    }
    private func buildExportHTML() -> String {
        let body = previewLatex.isEmpty ? MiniTeX.render(cleanForKaTeX(latexText)) : previewLatex
        guard let url = Bundle.main.url(forResource: "PreviewShell", withExtension: "html"),
              var html = try? String(contentsOf: url) else {
            return body // as a last resort
        }
        html = html.replacingOccurrences(of: "<!--CONTENT-->", with: body)
        return html
    }

    // Kick off the PDF export via WKWebView.createPDF
    private func exportTypesetPDF() {
        let html = buildExportHTML()
        typesetExporter.exportPDF(html: html, baseURL: katexBaseURL) { result in
            switch result {
            case .success(let url):
                shareURL = url
                showShare = true
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }

    // Write a raw .tex file (no compile) and present the share sheet
    private func exportTeX() {
        do {
            let url = try LatexExporter.writeTeXFile(body: latexText, fileName: "Noto.tex")
            shareURL = url
            showShare = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func scheduleSave(updateCover: Bool = false) {
        saveWorkItem?.cancel()
        let wi = DispatchWorkItem { [drawing, latexText, pickedImage, textBoxes] in
            Task.detached(priority: .utility) {
                store.saveContent(folderID: folderID, notebookID: notebookID,
                                  drawing: drawing, latexText: latexText, pickedImage: pickedImage,
                                  updateCover: updateCover)
                store.saveTextBoxes(folderID: folderID, notebookID: notebookID, boxes: textBoxes)
            }
        }
        saveWorkItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: wi)
    }
}

// MARK: - Panel mode
private enum PanelMode: String, Hashable {
    case editor, preview
}

//MARK: Tools Picker Strip and Tool Options
private struct ToolPickerStrip: View {
    @Binding var currentTool: ToolType
    var body: some View {
        Picker("", selection: $currentTool) {
            Image(systemName: "pencil.tip").tag(ToolType.pen)
            Image(systemName: "highlighter").tag(ToolType.marker)
            Image(systemName: "eraser").tag(ToolType.eraser)
            Image(systemName: "selection.pin.in.out").tag(ToolType.lasso)
            Image(systemName: "square.on.circle").tag(ToolType.shape)
            Image(systemName: "textformat").tag(ToolType.text)
        }
        .pickerStyle(.segmented)
    }
}
private struct CanvasToolBar: View {
    @State private var showWidthPopover = false
    @Binding var currentTool: ToolType
    @Binding var currentShape: ShapeKind
    @Binding var color: Color
    @Binding var strokeWidth: CGFloat
    @Binding var showToolOptions: Bool

    @Binding var penFavorites: [Color]
    @Binding var markerFavorites: [Color]

    @Binding var penWidthFavorites: [CGFloat]
    @Binding var markerWidthFavorites: [CGFloat]
    
    //for eraser
    @Binding var eraserRadius: CGFloat
    @Binding var eraserWidthFavorites: [CGFloat]
    @Binding var eraseMode: EraseMode

    var canUndo: Bool
    var canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onAddTextBox: () -> Void

    private let swatches: [Color] = [.black, .blue, .red, .green, .orange, .yellow]

    var body: some View {
        HStack(spacing: 12) {

            // 1) Current tool (the “little slider”)
            Picker("", selection: $currentTool) {
                Image(systemName: "pencil.tip").tag(ToolType.pen)
                Image(systemName: "highlighter").tag(ToolType.marker)
                Image(systemName: "eraser").tag(ToolType.eraser)
                Image(systemName: "selection.pin.in.out").tag(ToolType.lasso)
                Image(systemName: "square.on.circle").tag(ToolType.shape)
                Image(systemName: "textformat").tag(ToolType.text)
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(maxWidth: 320)
            if currentTool == .text {
                Divider().frame(height: 20)

                Button(action: onAddTextBox) {
                    Label("Text Box", systemImage: "text.append")
                        .labelStyle(.iconOnly)   // small icon to match your tray
                }
                .help("Add a text box under the last content")
            }

            // ============== ERASER UI (new) ==============
            if currentTool == .eraser {
                // mode toggle
                Picker("", selection: $eraseMode) {
                    Text("Object").tag(EraseMode.object)
                    Text("Pixel").tag(EraseMode.pixel)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                // three radius chips (tap = use, long-press = save)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        let w = eraserWidthFavorites[i]
                        let demoH = max(3, min(14, w))
                        let selected = abs(eraserRadius - w) < 0.5
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(UIColor.secondarySystemBackground))
                            Capsule()
                                .fill(Color.primary.opacity(0.85))
                                .frame(width: 22, height: demoH)
                        }
                        .frame(width: 34, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? Color.blue : .white.opacity(0.7),
                                        lineWidth: selected ? 2 : 1)
                        )
                        .onTapGesture { eraserRadius = w }
                        .onLongPressGesture { eraserWidthFavorites[i] = eraserRadius }
                        .accessibilityLabel("Eraser width preset \(i+1)")
                    }
                }
                .transition(.opacity)

            } else {
                // ============== PEN / MARKER UI (your existing controls) ==============

                // Put these inside the branch to avoid "unused" warnings in eraser mode
                let favs = currentTool == .marker ? $markerFavorites : $penFavorites

                HStack(spacing: 10) {
                    // 3 quick-swap slots
                    ForEach(0..<3, id: \.self) { i in
                        let slotColor = favs.wrappedValue[i]
                        let preview = currentTool == .marker ? slotColor.opacity(0.35) : slotColor
                        Circle()
                            .fill(preview)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .overlay( // selection ring
                                Circle()
                                    .stroke(color == slotColor ? Color.blue : .clear, lineWidth: 2)
                            )
                            .onTapGesture { color = slotColor }
                            .onLongPressGesture { favs.wrappedValue[i] = color }
                            .accessibilityLabel("Favorite color \(i+1)")
                    }

                    // live color picker for fine-tuning
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()

                    // width control (slider popover)
                    Button { showWidthPopover.toggle() } label: {
                        Image(systemName: "scribble.variable")
                            .imageScale(.medium)
                            .padding(.horizontal, 6)
                    }
                    .accessibilityLabel("Adjust thickness")
                    .popover(isPresented: $showWidthPopover, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Thickness").font(.headline)
                            HStack(spacing: 8) {
                                Slider(value: $strokeWidth, in: 1...20, step: 1)
                                Text("\(Int(strokeWidth))")
                                    .monospacedDigit()
                                    .frame(width: 32, alignment: .trailing)
                            }
                            Text("Tip: long-press a width chip to save this value.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(width: 260)
                    }
                }
                .transition(.opacity)

                let wFavs = currentTool == .marker ? $markerWidthFavorites : $penWidthFavorites

                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        let w = wFavs.wrappedValue[i]
                        let demoH = max(2, min(14, w))
                        let lineColor = currentTool == .marker ? color.opacity(0.5) : color
                        let isSelected = abs(strokeWidth - w) < 0.5

                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(UIColor.secondarySystemBackground))
                            Capsule()
                                .fill(lineColor)
                                .frame(width: 22, height: demoH)
                        }
                        .frame(width: 34, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? Color.blue : Color.white.opacity(0.7),
                                        lineWidth: isSelected ? 2 : 1)
                        )
                        .onTapGesture { strokeWidth = w }
                        .onLongPressGesture { wFavs.wrappedValue[i] = strokeWidth }
                        .accessibilityLabel("Width preset \(i+1)")
                    }
                }
            }

            Spacer()

            // 3) Undo / Redo (right side)
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!canUndo)

            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!canRedo)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 48)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct ToolOptionsPopover: View {
    @Binding var currentTool: ToolType
    @Binding var currentShape: ShapeKind
    @Binding var color: Color
    @Binding var strokeWidth: CGFloat

    private let swatches: [Color] = [.black, .blue, .red, .green, .orange, .yellow]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if currentTool == .shape {
                Text("Shape").font(.headline)
                Picker("", selection: $currentShape) {
                    Image(systemName: "line.diagonal").tag(ShapeKind.line)
                    Image(systemName: "arrow.right").tag(ShapeKind.arrow)
                    Image(systemName: "rectangle").tag(ShapeKind.rectangle)
                    Image(systemName: "circle").tag(ShapeKind.ellipse)
                }
                .pickerStyle(.segmented)
            } else {
                Text("Color").font(.headline)
                HStack(spacing: 10) {
                    ForEach(swatches, id: \.self) { c in
                        Circle()
                            .fill(c)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 0.5)
                            .onTapGesture { color = c }
                    }
                }
                Text("Thickness").font(.headline)
                Slider(value: $strokeWidth, in: 1...20, step: 1)
            }
        }
    }
}
// MARK: - PencilKit wrapper

import SwiftUI
import PencilKit

struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var tool: ToolType
    @Binding var penColor: Color
    @Binding var strokeWidth: CGFloat
    @Binding var undoManager: UndoManager?
    
    // Eraser
    @Binding var eraseMode: EraseMode
    @Binding var viewport: EraserOverlay.CanvasViewport
    var paperStyle: PaperStyle = .plain

    // page config
    private let minPageHeight: CGFloat = 2000
    private let bottomHeadroom: CGFloat = 1000
    private let bottomWritingInset: CGFloat = 120   // (kept for clarity, used via applyInsets)

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = CanvasView()
        context.coordinator.canvas = v

        v.delegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.delegate = context.coordinator
        #if targetEnvironment(simulator)
        v.drawingPolicy = .anyInput
        #else
        v.drawingPolicy = .pencilOnly
        #endif

        // scrolling / zoom
        v.isScrollEnabled = true
        v.minimumZoomScale = 1
        v.maximumZoomScale = 6
        v.alwaysBounceVertical = true
        v.alwaysBounceHorizontal = false
        v.contentInsetAdjustmentBehavior = .never
        v.isMultipleTouchEnabled = true
        v.contentScaleFactor = UIScreen.main.scale

        // Bindings into coordinator so we don’t rely on a stale struct copy
        context.coordinator.drawingBinding = $drawing
        context.coordinator.undoBinding = $undoManager
        context.coordinator.viewportBinding = $viewport
        context.coordinator.toolBinding = $tool
        
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        pencil.isEnabled = true
        v.addInteraction(pencil)
    

        // seed initial viewport + content sizing on next runloop
        DispatchQueue.main.async {
            self.applyInsets(v)
            self.ensureContentSize(v)
            self.syncCanvasWidth(v)
            context.coordinator.pushViewport(from: v)
            self.undoManager = v.undoManager
        }

        // Initial state
        v.drawing = drawing
        applyTool(on: v, coordinator: context.coordinator)
        
        let host = UIHostingController(rootView: PaperBackground(style: paperStyle))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = CGRect(origin: .zero, size: v.contentSize)

        // Put it at the back so ink stays above
        v.insertSubview(host.view, at: 0)

        context.coordinator.bgHost = host

        return v
    }
    
    private func syncCanvasWidth(_ v: PKCanvasView) {
        let targetW = max(1, v.bounds.width)
        if abs(v.contentSize.width - targetW) > 0.5 {
            let targetH = max(v.contentSize.height, desiredContentHeight(v))
            v.contentSize = CGSize(width: targetW, height: targetH)
        }
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        // Rebind (parent may have restructured)
        context.coordinator.drawingBinding  = $drawing
        context.coordinator.undoBinding     = $undoManager
        context.coordinator.viewportBinding = $viewport
        
        if let host = context.coordinator.bgHost {
            host.rootView = PaperBackground(style: paperStyle) // reflect picker changes
            host.view.frame.size = v.contentSize               // 🔹 not uiView
        }

        // Only push drawing to PKCanvasView if it actually changed
        if v.drawing != drawing { v.drawing = drawing }
        
        let targetW = max(1, v.bounds.width)
        if abs(v.contentSize.width - targetW) > 0.5 {
            // preserve existing height (or grow to desired), but reset width to match bounds
            let targetH = max(v.contentSize.height, desiredContentHeight(v))
            v.contentSize = CGSize(width: targetW, height: targetH)
        }
        syncCanvasWidth(v)
        applyInsets(v)

        // Update inputs used by applyTool
        context.coordinator.currentToolType    = tool
        context.coordinator.currentPenColor    = penColor
        context.coordinator.currentStrokeWidth = strokeWidth
        context.coordinator.currentEraseMode   = eraseMode

        // Gated tool apply (no duplicates)
        let key = "\(tool)|\(eraseMode)|\(rgbaKey(UIColor(penColor)))|\(strokeWidth)"
        if context.coordinator.lastToolKey != key {
            context.coordinator.lastToolKey = key
            applyTool(on: v, coordinator: context.coordinator)
        }

        // NOTE: Do NOT call ensureContentSize(v) here.
        // The coordinator grows content size after strokes via scheduleSync(...)
    }
    
    private func rgbaKey(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func q(_ x: CGFloat) -> String { String(format: "%.3f", x) } // quantize
        return "\(q(r)),\(q(g)),\(q(b)),\(q(a))"
    }

    // MARK: - Coordinator

    final class Coord: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIPencilInteractionDelegate {
        // live canvas reference
        weak var canvas: PKCanvasView?

        // current inputs to derive toolKey
        var currentToolType: ToolType = .pen
        var currentPenColor: Color = .black
        var currentStrokeWidth: CGFloat = 5
        var currentEraseMode: EraseMode = .pixel

        // bindings
        var drawingBinding: Binding<PKDrawing>!
        var undoBinding: Binding<UndoManager?>!
        var viewportBinding: Binding<EraserOverlay.CanvasViewport>!

        // memoization to avoid redundant updates
        var lastToolKey: String = ""
        var lastGestureEnabled: Bool?
        
        //tool binding
        var toolBinding: Binding<ToolType>!
        var showPaletteBinding: Binding<Bool>?
        
        // keep track of previous non-eraser tool
        private var lastNonEraser: ToolType = .pen
        
        //too much refreshing going on
        private var isActivelyDrawing = false
        private var pendingSync: DispatchWorkItem?
        
        private var lastCommittedHeight: CGFloat = 0
        
        var bgHost: UIHostingController<PaperBackground>?
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            let action: UIPencilPreferredAction
            if #available(iOS 14.0, *) { action = UIPencilInteraction.preferredTapAction }
            else { action = .switchEraser }

            switch action {
            case .ignore:
                break

            case .showColorPalette, .showContextualPalette, .showInkAttributes:
                // open your color/width popover
                showPaletteBinding?.wrappedValue = true

            case .switchEraser:
                let cur = toolBinding.wrappedValue
                if cur == .eraser { toolBinding.wrappedValue = lastNonEraser }
                else { lastNonEraser = cur; toolBinding.wrappedValue = .eraser }

            case .switchPrevious:
                let cur = toolBinding.wrappedValue
                if cur != .eraser { lastNonEraser = cur }
                toolBinding.wrappedValue = (cur == .eraser) ? lastNonEraser : .eraser

            case .runSystemShortcut:
                // nothing to run in-app; treat like palette for now
                showPaletteBinding?.wrappedValue = true

            @unknown default:
                // safe fallback: toggle eraser
                let cur = toolBinding.wrappedValue
                if cur == .eraser { toolBinding.wrappedValue = lastNonEraser }
                else { lastNonEraser = cur; toolBinding.wrappedValue = .eraser }
            }
        }

        // PKCanvasViewDelegate
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isActivelyDrawing else { return }
            self.bgHost?.view.frame.size = canvasView.contentSize
            scheduleSync(from: canvasView, delay: 0.12)
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isActivelyDrawing = true
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isActivelyDrawing = false
            scheduleSync(from: canvasView, delay: 0)
        }

        // UIScrollViewDelegate
        func scrollViewDidScroll(_ scrollView: UIScrollView) { pushViewport(from: scrollView) }
        func scrollViewDidZoom(_ scrollView: UIScrollView)   { pushViewport(from: scrollView) }

        func pushViewport(from scrollView: UIScrollView) {
            viewportBinding.wrappedValue = .init(
                zoomScale: scrollView.zoomScale,
                contentOffset: scrollView.contentOffset
            )
        }
        private func scheduleSync(from cv: PKCanvasView, delay: TimeInterval) {
            pendingSync?.cancel()
            let work = DispatchWorkItem { [weak self, weak cv] in
                guard let self, let cv else { return }

                // push drawing & undo
                self.drawingBinding.wrappedValue = cv.drawing
                self.undoBinding.wrappedValue = cv.undoManager

                // compute target height and only GROW
                let target = self.desiredContentHeight(cv)
                let growTo = max(self.lastCommittedHeight, target)
                if growTo - self.lastCommittedHeight > 0.5, cv.contentSize.height < growTo - 0.5 {
                    cv.contentSize = CGSize(width: max(1, cv.bounds.width), height: growTo)
                    self.lastCommittedHeight = growTo
                }
            }
            pendingSync = work
            if delay == 0 { DispatchQueue.main.async(execute: work) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        }

        // local copy of desired height so we can call it from delegate
        private func desiredContentHeight(_ v: PKCanvasView) -> CGFloat {
            let viewportH = max(1, v.bounds.height)
            let minH = max(2000, viewportH + 200)
            let drawingBottom = v.drawing.bounds.isEmpty ? 0 : v.drawing.bounds.maxY
            return max(minH, drawingBottom + 1000)
        }
    }
    private final class CanvasView: PKCanvasView {
        var onLayout: ((PKCanvasView) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(self)          // <- fires any time bounds change (animations, rotation, splits, etc.)
        }
    }

    // MARK: - Tool application (diffed)

    private func applyTool(on v: PKCanvasView, coordinator: Coord) {
        let key = toolKey(
            tool: coordinator.currentToolType,
            color: coordinator.currentPenColor,
            width: coordinator.currentStrokeWidth,
            eraseMode: coordinator.currentEraseMode
        )
        if key != coordinator.lastToolKey {
            // Toggle drawing gesture only when necessary
            let shouldEnableDrawing: Bool
            switch coordinator.currentToolType {
            case .pen, .marker, .shape:
                shouldEnableDrawing = true
            case .eraser:
                shouldEnableDrawing = (coordinator.currentEraseMode == .object) // vector erase draws; pixel erase uses overlay
            case .lasso, .text:
                shouldEnableDrawing = false
            }

            if coordinator.lastGestureEnabled != shouldEnableDrawing {
                v.drawingGestureRecognizer.isEnabled = shouldEnableDrawing
                coordinator.lastGestureEnabled = shouldEnableDrawing
            }

            // Apply concrete PKTool
            switch coordinator.currentToolType {
            case .pen:
                let ui = UIColor(coordinator.currentPenColor)
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                v.tool = PKInkingTool(.pen, color: ui, width: max(1, coordinator.currentStrokeWidth))

            case .marker:
                let ui = UIColor(coordinator.currentPenColor)
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                    .withAlphaComponent(0.33)
                v.tool = PKInkingTool(.marker, color: ui, width: max(1, coordinator.currentStrokeWidth))

            case .eraser:
                if coordinator.currentEraseMode == .object {
                    v.tool = PKEraserTool(.vector)
                } else {
                    // keep harmless tool; drawing is disabled, overlay does pixel erase
                    v.tool = PKInkingTool(.pen, color: .clear, width: 1)
                }

            case .lasso:
                v.tool = PKLassoTool()
            case .text:
                // keep a harmless tool; drawing disabled by allowsHitTesting anyway
                v.tool = PKInkingTool(.pen, color: .clear, width: 1)


            case .shape:
                let ui = UIColor(coordinator.currentPenColor)
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                v.tool = PKInkingTool(.pen, color: ui, width: max(1, coordinator.currentStrokeWidth))
            }

            coordinator.lastToolKey = key
        }
    }

    private func toolKey(tool: ToolType, color: Color, width: CGFloat, eraseMode: EraseMode) -> String {
        switch tool {
        case .pen:    return "pen:\(UIColor(color).description):\(width)"
        case .marker: return "marker:\(UIColor(color).description):\(width)"
        case .shape:  return "shape:\(UIColor(color).description):\(width)"
        case .lasso:  return "lasso"
        case .eraser: return "eraser:\(eraseMode == .object ? "vector" : "pixel")"
        case .text:   return "text"
        }
    }

    // MARK: - Layout helpers (your originals, lightly guarded)

    private func desiredContentHeight(_ v: PKCanvasView) -> CGFloat {
        let viewportH = max(1, v.bounds.height)
        let minH = max(minPageHeight, viewportH + 200)
        let drawingBottom = v.drawing.bounds.isEmpty ? 0 : v.drawing.bounds.maxY
        return max(minH, drawingBottom + bottomHeadroom)
    }

    private func applyInsets(_ v: PKCanvasView) {
        let safe = v.safeAreaInsets.bottom
        let writePad: CGFloat = max(60, safe)
        if v.contentInset.bottom != writePad {
            v.contentInset.bottom = writePad
        }
        let indicatorPad: CGFloat = max(2, safe + 2)
        if #available(iOS 13.0, *) {
            var vi = v.verticalScrollIndicatorInsets
            if vi.bottom != indicatorPad {
                vi.bottom = indicatorPad
                v.verticalScrollIndicatorInsets = vi
            }
        } else {
            var si = v.scrollIndicatorInsets
            if si.bottom != indicatorPad {
                si.bottom = indicatorPad
                v.scrollIndicatorInsets = si
            }
        }
    }

    private func ensureContentSize(_ v: PKCanvasView) {
        let targetH = desiredContentHeight(v)
        let w = max(1, v.bounds.width)
        if abs(v.contentSize.height - targetH) > 1 || abs(v.contentSize.width - w) > 1 {
            v.contentSize = CGSize(width: w, height: targetH)
        }
    }
}

// MARK: - Photos / Camera

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        vc.allowsEditing = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage] as? UIImage)?.fixedOrientation()
            picker.presentingViewController?.dismiss(animated: true)
            if let i = img { parent.onImage(i) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.presentingViewController?.dismiss(animated: true)
        }
    }
}

// MARK: - Simple cropper (same as before)

struct CropperSheet: View {
    let image: UIImage
    var onCropped: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        // aspect-fit math for .scaledToFit
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let x = (container.width  - w) / 2
        let y = (container.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func cropUIImage(_ image: UIImage, normalized r: CGRect) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)

        var px = CGRect(x: r.minX * W, y: r.minY * H,
                        width: r.width * W, height: r.height * H).integral
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        px = px.intersection(bounds)

        guard px.width > 1, px.height > 1, let cut = cg.cropping(to: px) else { return image }
        return UIImage(cgImage: cut, scale: image.scale, orientation: image.imageOrientation)
    }


    var body: some View {
        VStack {
            Text("Crop")
                .font(.headline)
                .padding(.top)

            GeometryReader { geo in
                let fit = fittedRect(for: image.size, in: geo.size)   // where the image actually sits

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    // draw the crop rectangle (crop is normalized 0..1)
                    let rectOnScreen = CGRect(
                        x: fit.minX + crop.minX * fit.width,
                        y: fit.minY + crop.minY * fit.height,
                        width: crop.width * fit.width,
                        height: crop.height * fit.height
                    )

                    Rectangle()
                        .path(in: rectOnScreen)
                        .stroke(Color.yellow, lineWidth: 2)
                        // simple drag to move the crop box
                        .gesture(
                            DragGesture().onChanged { v in
                                // convert drag in points -> normalized units
                                let dx = v.translation.width  / fit.width
                                let dy = v.translation.height / fit.height
                                crop.origin.x = min(max(0, crop.origin.x + dx), 1 - crop.width)
                                crop.origin.y = min(max(0, crop.origin.y + dy), 1 - crop.height)
                            }
                        )
                }
            }
            .padding()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Crop") {
                    let cropped = cropUIImage(image, normalized: crop)
                    onCropped(cropped)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var baseURL: String
    @Binding var conversionBackend: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversion Engine") {
                    Picker("Engine", selection: $conversionBackend) {
                        Text("Server").tag("server")
                        Text("On-Device (beta)").tag("ondevice")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Conversion Engine")
                }

                if conversionBackend == "server" {
                    Section("Server") {
                        TextField("Base URL (e.g. http://192.168.0.42:8000)", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Text("Simulator can use http://127.0.0.1:8000. Real iPad must use your Mac’s LAN IP.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("On-Device Status") {
                        Text("Runs entirely on this device. Requires a supported model; current build uses a placeholder.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
struct PageView: View {
    var size: CGSize = .init(width: 768, height: 1024)
    var style: PaperStyle

    // forward all the bindings your PencilCanvas needs
    @Binding var drawing: PKDrawing
    @Binding var tool: ToolType
    @Binding var penColor: Color
    @Binding var strokeWidth: CGFloat
    @Binding var undoManager: UndoManager?
    @Binding var eraseMode: EraseMode
    @Binding var viewport: EraserOverlay.CanvasViewport

    var body: some View {
        ZStack {
            PaperBackground(style: style)
            PencilCanvas(
                drawing: $drawing,
                tool: $tool,
                penColor: $penColor,
                strokeWidth: $strokeWidth,
                undoManager: $undoManager,
                eraseMode: $eraseMode,
                viewport: $viewport
            )
            .background(Color.clear)
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

// MARK: - Helpers

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ZoomableImage: View {
    let image: Image
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = lastScale * value }
                    .onEnded { _ in lastScale = max(1.0, min(6.0, scale)) ; scale = lastScale }
            )
            .gesture(
                DragGesture()
                    .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width,
                                                      height: lastOffset.height + v.translation.height) }
                    .onEnded { _ in lastOffset = offset }
            )
            .scaleEffect(scale)
            .offset(offset)
            .animation(.default, value: scale)
    }
}

struct ShapeDrawOverlay: View {
    @Binding var currentShape: ShapeKind
    @Binding var dragStart: CGPoint?
    @Binding var dragRect: CGRect?
    @Binding var shapes: [ShapeItem]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // existing shapes
                ForEach(shapes) { item in
                    ShapeView(kind: item.kind, rect: item.rect)
                }
                // preview while dragging
                if let r = dragRect {
                    ShapeView(
                        kind: currentShape,
                        rect: r,
                        color: Color.blue.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 6])
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        let s = dragStart ?? value.startLocation
                        let e = value.location
                        dragRect = CGRect(x: min(s.x,e.x), y: min(s.y,e.y),
                                          width: abs(e.x - s.x), height: abs(e.y - s.y))
                    }
                    .onEnded { _ in
                        if let r = dragRect {
                            shapes.append(.init(kind: currentShape, rect: r))
                        }
                        dragStart = nil
                        dragRect = nil
                    }
            )
        }
    }
}

struct ShapeItem: Identifiable {
    var id = UUID()
    var kind: ShapeKind
    var rect: CGRect
}

struct ShapeView: View {
    let kind: ShapeKind
    let rect: CGRect
    var color: Color = .primary.opacity(0.9)
    var style: StrokeStyle = .init(lineWidth: 2, lineCap: .round, lineJoin: .round)

    var body: some View {
        Path { p in
            switch kind {
            case .rectangle:
                p.addRoundedRect(in: rect, cornerSize: .init(width: 8, height: 8))
            case .ellipse:
                p.addEllipse(in: rect)
            case .line, .arrow:
                p.move(to: rect.origin)
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                if kind == .arrow {
                    let end = CGPoint(x: rect.maxX, y: rect.maxY)
                    let v = CGVector(dx: end.x - rect.minX, dy: end.y - rect.minY)
                    let len = max(1, hypot(v.dx, v.dy))
                    let ux = v.dx / len, uy = v.dy / len
                    let tip = end
                    let back = CGPoint(x: tip.x - ux*18, y: tip.y - uy*18)
                    let left = CGPoint(x: back.x + -uy*8, y: back.y + ux*8)
                    let right = CGPoint(x: back.x - -uy*8, y: back.y - ux*8)
                    p.move(to: tip); p.addLine(to: left)
                    p.move(to: tip); p.addLine(to: right)
                }
            }
        }
        .stroke(color, style: style)
    }
}

extension UIImage {
    func fixedOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return normalized
    }

    func withBackground(color: UIColor) -> UIImage {
        let rect = CGRect(origin: .zero, size: size)
        UIGraphicsBeginImageContextWithOptions(size, true, scale)
        color.setFill()
        UIRectFill(rect)
        draw(in: rect)
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return result
    }
}
// MARK: - KaTeX cleaning helper
private func cleanForKaTeX(_ raw: String) -> String {
    var s = raw

    // 0) Normalize common “mistyped backslashes” before LaTeX commands.
    //    Converts /int, ／sqrt, ¥frac, etc.  →  \int, \sqrt, \frac …
    //    The negative lookbehind (?<![/∕／⁄¥￥]) keeps `//int` from turning into `/\int`.
    let cmds = #"(int|sum|prod|lim|sqrt|frac|sin|cos|tan|log|ln|cdot|times|to|le|ge|ne|neq|infty|alpha|beta|gamma|pi|partial|nabla|pm|mp|cup|cap|subset|supset|approx|sim|equiv|forall|exists|left|right|rightarrow|Rightarrow|ldots|dots|vec|hat|bar|overline|underline|mathbb|mathcal|mathrm|mathbf|text)"#
    s = s.replacingOccurrences(
        of: #"(?<![/∕／⁄¥￥])[/∕／⁄¥￥]\s*\#(cmds)"#,
        with: #"\\$1"#,
        options: .regularExpression
    )

    // 1) (your existing cleanups)
    s = s.replacingOccurrences(of: "\\\\documentclass\\{.*?\\}", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\\\usepackage\\{.*?\\}",   with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\\\begin\\{document\\}",   with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\\\end\\{document\\}",     with: "", options: .regularExpression)

    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class DrawingUndoTarget {
    let set: (PKDrawing) -> Void
    init(set: @escaping (PKDrawing) -> Void) { self.set = set }
}

enum StrokeEraserDev {
    static func runSimpleSplitTest() {
        let ink = PKInk(.pen, color: .black)

        // A straight 0→100 line
        var pts: [PKStrokePoint] = []
        for x in stride(from: 0, through: 100, by: 2) {
            let p = CGPoint(x: CGFloat(x), y: 0)
            pts.append(PKStrokePoint(location: p,
                                     timeOffset: 0,
                                     size: CGSize(width: 4, height: 4),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi/2))
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: .now)
        let s = PKStroke(ink: ink, path: path, transform: .identity)
        let drawing = PKDrawing(strokes: [s])

        // Eraser crosses at x≈50
        let eraser: [CGPoint] = [CGPoint(x: 50, y: -10), CGPoint(x: 50, y: 10)]
        let out = StrokeEraser.erase(drawing, with: eraser, radius: 6)

        print("Split test: in=\(drawing.strokes.count) out=\(out.strokes.count)") // expect 2
    }
}
