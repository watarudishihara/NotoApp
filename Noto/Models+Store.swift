import SwiftUI
import PencilKit

// ============= Models =============
struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created: Date = .now
    var notebooks: [NotebookMeta] = []
    var folders: [Folder] = []            // NEW: subfolders
}

struct NotebookMeta: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var created: Date = .now
    var updated: Date = .now
}

// Persisted state wrapper (back-compat with older state.json)
private struct AppState: Codable {
    var rootNotebooks: [NotebookMeta] = []
    var folders: [Folder] = []
}

// ============= Store =============
final class NotebookStore: ObservableObject {
    static let shared = NotebookStore()

    // Public tree:
    @Published var folders: [Folder] = []             // top-level folders
    @Published var rootNotebooks: [NotebookMeta] = [] // notebooks at root (first screen)

    // Pseudo id used to store root notebooks on disk
    static let rootPseudoID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // ---- Paths / Files ----
    private let base: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("NTex", isDirectory: true)
    }()
    private var stateURL: URL { base.appendingPathComponent("state.json") }
    private var rootDir: URL { base.appendingPathComponent("root", isDirectory: true) }

    private init() { loadState() }

    // MARK: - Load / Save
    private func loadState() {
        ensureDir(base); ensureDir(rootDir)

        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(AppState.self, from: data) {
            self.folders = s.folders
            self.rootNotebooks = s.rootNotebooks
            return
        }

        // Back-compat: older builds stored [Folder] only
        if let data = try? Data(contentsOf: stateURL),
           let f = try? JSONDecoder().decode([Folder].self, from: data) {
            self.folders = f
            self.rootNotebooks = []
            saveState()
            return
        }

        // First run
        self.folders = [Folder(name: "My Notes")]
        saveState()
    }

    private func saveState() {
        ensureDir(base)
        let s = AppState(rootNotebooks: rootNotebooks, folders: folders)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Helpers (find/mutate recursively)
    private func mutateFolder(id: UUID, _ body: (inout Folder) -> Void) -> Bool {
        for i in 0..<folders.count {
            if mutateFolder(&folders[i], id: id, body) { return true }
        }
        return false
    }
    private func mutateFolder(_ f: inout Folder, id: UUID, _ body: (inout Folder) -> Void) -> Bool {
        if f.id == id { body(&f); return true }
        for i in 0..<f.folders.count {
            if mutateFolder(&f.folders[i], id: id, body) { return true }
        }
        return false
    }

    private func getFolder(id: UUID) -> Folder? {
        func dfs(_ list: [Folder]) -> Folder? {
            for f in list {
                if f.id == id { return f }
                if let hit = dfs(f.folders) { return hit }
            }
            return nil
        }
        return dfs(folders)
    }

    // Public accessors for UI
    func childFolders(of containerID: UUID?) -> [Folder] {
        guard let id = containerID else { return folders }
        return getFolder(id: id)?.folders ?? []
    }
    func childNotebooks(of containerID: UUID?) -> [NotebookMeta] {
        guard let id = containerID else { return rootNotebooks }
        return getFolder(id: id)?.notebooks ?? []
    }

    // MARK: - Create
    func createFolder(in containerID: UUID? = nil, name: String = "New Folder") {
        let f = Folder(name: name)
        if let id = containerID {
            _ = mutateFolder(id: id) { $0.folders.insert(f, at: 0) }
        } else {
            folders.insert(f, at: 0)
        }
        ensureDir(dir(forFolder: f.id))
        saveState()
    }

    @discardableResult
    func createNotebook(in containerID: UUID? = nil, title: String = "New Notebook") -> NotebookMeta {
        let nb = NotebookMeta(title: title)
        if let id = containerID {
            _ = mutateFolder(id: id) { $0.notebooks.insert(nb, at: 0) }
            ensureDir(dir(forFolder: id, notebookID: nb.id))
        } else {
            rootNotebooks.insert(nb, at: 0)
            ensureDir(dir(forFolder: Self.rootPseudoID, notebookID: nb.id))
        }
        saveState()
        return nb
    }

    // Back-compat helpers (old call sites keep working)
    @discardableResult
    func createNotebook(in folderID: UUID, title: String = "New Notebook") -> NotebookMeta {
        createNotebook(in: Optional(folderID), title: title)
    }
    func createFolder(name: String = "New Folder") { createFolder(in: nil, name: name) }

    // MARK: - Rename / Delete (folders)
    func renameFolder(id: UUID, to name: String) {
        _ = mutateFolder(id: id) { $0.name = name }
        saveState()
    }

    func deleteFolder(id: UUID) {
        // collect ids for cleanup
        let toDelete = collectIDs(forFolderID: id)
        // remove from tree
        _ = removeFolder(id: id, in: &folders)
        saveState()
        // delete dirs on disk (best-effort)
        for fID in toDelete.folders { try? FileManager.default.removeItem(at: dir(forFolder: fID)) }
        for (fID, nID) in toDelete.notebooks {
            try? FileManager.default.removeItem(at: dir(forFolder: fID, notebookID: nID))
        }
    }

    private func removeFolder(id: UUID, in list: inout [Folder]) -> Bool {
        if let i = list.firstIndex(where: { $0.id == id }) {
            list.remove(at: i); return true
        }
        for i in 0..<list.count {
            if removeFolder(id: id, in: &list[i].folders) { return true }
        }
        return false
    }

    private func collectIDs(forFolderID id: UUID) -> (folders: [UUID], notebooks: [(UUID, UUID)]) {
        var fIDs: [UUID] = []
        var nIDs: [(UUID, UUID)] = []

        func walk(_ f: Folder) {
            fIDs.append(f.id)
            for nb in f.notebooks { nIDs.append((f.id, nb.id)) }
            for sub in f.folders { walk(sub) }
        }
        if let f = getFolder(id: id) { walk(f) }
        return (fIDs, nIDs)
    }

    // MARK: - Rename / Delete (notebooks)
    func renameNotebook(in containerID: UUID?, notebookID: UUID, to title: String) {
        if let id = containerID {
            _ = mutateFolder(id: id) {
                if let i = $0.notebooks.firstIndex(where: { $0.id == notebookID }) {
                    $0.notebooks[i].title = title
                    $0.notebooks[i].updated = .now
                }
            }
        } else {
            if let i = rootNotebooks.firstIndex(where: { $0.id == notebookID }) {
                rootNotebooks[i].title = title
                rootNotebooks[i].updated = .now
            }
        }
        saveState()
    }

    func deleteNotebook(in containerID: UUID?, notebookID: UUID) {
        if let id = containerID {
            _ = mutateFolder(id: id) {
                if let i = $0.notebooks.firstIndex(where: { $0.id == notebookID }) {
                    $0.notebooks.remove(at: i)
                }
            }
            try? FileManager.default.removeItem(at: dir(forFolder: id, notebookID: notebookID))
        } else {
            if let i = rootNotebooks.firstIndex(where: { $0.id == notebookID }) {
                rootNotebooks.remove(at: i)
            }
            try? FileManager.default.removeItem(at: dir(forFolder: Self.rootPseudoID, notebookID: notebookID))
        }
        saveState()
    }

    // Back-compat (old signatures)
    func renameNotebook(folderID: UUID, notebookID: UUID, to title: String) {
        renameNotebook(in: Optional(folderID), notebookID: notebookID, to: title)
    }
    func deleteNotebook(folderID: UUID, notebookID: UUID) {
        deleteNotebook(in: Optional(folderID), notebookID: notebookID)
    }

    // MARK: - Note content I/O (same API; root uses pseudo id)
    struct NotebookContent {
        var drawing: PKDrawing
        var latexText: String
        var pickedImage: UIImage?
    }

    func loadContent(folderID: UUID, notebookID: UUID) -> NotebookContent {
        let d = dir(forFolder: folderID, notebookID: notebookID)
        let drawingURL = d.appendingPathComponent("drawing.data")
        let latexURL   = d.appendingPathComponent("latex.txt")
        let imageURL   = d.appendingPathComponent("image.png")

        let drawing = (try? PKDrawing(data: Data(contentsOf: drawingURL))) ?? PKDrawing()
        let latex   = (try? String(contentsOf: latexURL, encoding: .utf8)) ?? ""
        let image   = UIImage(contentsOfFile: imageURL.path)

        return NotebookContent(drawing: drawing, latexText: latex, pickedImage: image)
    }
    // Async, off-main loader used by ContentView
    struct NotebookPayload {
        var drawing: PKDrawing
        var latexText: String
        var pickedImage: UIImage?
        var textBoxes: [TextBox]
    }

    func loadNotebookAsync(folderID: UUID, notebookID: UUID) async -> NotebookPayload {
        await withCheckedContinuation { cont in
            // Explicit self capture to satisfy Swift 6 actor isolation inside the closure
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                // ---- URLs ----
                let d = self.dir(forFolder: folderID, notebookID: notebookID)
                let drawingURL = d.appendingPathComponent("drawing.data")
                let latexURL   = d.appendingPathComponent("latex.txt")
                let imageURL   = d.appendingPathComponent("image.png")
                let boxesURL   = self.textBoxesURL(folderID: folderID, notebookID: notebookID)

                // ---- Decode PKDrawing off-main ----
                let drawingData = (try? Data(contentsOf: drawingURL)) ?? Data()
                let drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()

                // ---- Plain text ----
                let latex = (try? String(contentsOf: latexURL, encoding: .utf8)) ?? ""

                // ---- Downsample image (avoid full PNG decode on main) ----
                var image: UIImage? = nil
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    // UIScreen.main is deprecated in iOS 26 — get scale from the active window scene if possible
                    let scale = Self.currentScreenScale()
                    image = Self.downsampledImage(at: imageURL,
                                                  to: CGSize(width: 1200, height: 1600),
                                                  scale: scale)
                }

                // ---- Text boxes ----
                var boxes: [TextBox] = []
                if let data = try? Data(contentsOf: boxesURL),
                   let decoded = try? JSONDecoder().decode([TextBox].self, from: data) {
                    boxes = decoded
                }

                cont.resume(returning: NotebookPayload(drawing: drawing,
                                                       latexText: latex,
                                                       pickedImage: image,
                                                       textBoxes: boxes))
            }
        }
    }
    // Prefer a screen from the active window scene; fall back to UIScreen.main for older iOS
    private static func currentScreenScale() -> CGFloat {
        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let screen = scene.screen as UIScreen? {
            return screen.scale
        }
        // Fallback; fine on older SDKs even if deprecated on newer
        return UIScreen.main.scale
        #else
        return 2.0
        #endif
    }

    // Helper used above
    private static func downsampledImage(at url: URL, to size: CGSize, scale: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxDim = Int(max(size.width, size.height) * scale)
        let opts: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }


    func saveContent(folderID: UUID, notebookID: UUID,
                     drawing: PKDrawing, latexText: String, pickedImage: UIImage?,
                     updateCover: Bool = false) {
        let d = dir(forFolder: folderID, notebookID: notebookID)
        ensureDir(d)
        do {
            try drawing.dataRepresentation().write(to: d.appendingPathComponent("drawing.data"), options: .atomic)
            try latexText.data(using: .utf8)?.write(to: d.appendingPathComponent("latex.txt"), options: .atomic)
            if let img = pickedImage, let data = img.pngData() {
                try data.write(to: d.appendingPathComponent("image.png"), options: .atomic)
            }
            if updateCover {
                writeCover(folderID: folderID, notebookID: notebookID,
                           drawing: drawing, pickedImage: pickedImage)
            }
        } catch {
            print("NTex save error:", error)
        }
        touchUpdated(folderID: folderID, notebookID: notebookID)
    }

    private func touchUpdated(folderID: UUID, notebookID: UUID) {
        if folderID == Self.rootPseudoID {
            if let i = rootNotebooks.firstIndex(where: { $0.id == notebookID }) {
                rootNotebooks[i].updated = .now
            }
        } else {
            _ = mutateFolder(id: folderID) {
                if let i = $0.notebooks.firstIndex(where: { $0.id == notebookID }) {
                    $0.notebooks[i].updated = .now
                }
            }
        }
        saveState()
    }

    // MARK: - Cover thumbnails (unchanged)
    func coverImage(folderID: UUID, notebookID: UUID) -> UIImage? {
        let url = coverURL(folderID: folderID, notebookID: notebookID)
        return UIImage(contentsOfFile: url.path)
    }

    private func coverURL(folderID: UUID, notebookID: UUID) -> URL {
        dir(forFolder: folderID, notebookID: notebookID).appendingPathComponent("cover.png")
    }

    private func writeCover(folderID: UUID, notebookID: UUID,
                            drawing: PKDrawing, pickedImage: UIImage?) {
        let size = CGSize(width: 1200, height: 800)   // 3:2
        UIGraphicsBeginImageContextWithOptions(size, true, 2.0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        if let base = pickedImage {
            let r = aspectFitRect(imageSize: base.size, bounds: CGRect(origin: .zero, size: size))
            base.draw(in: r)
        }
        if !drawing.bounds.isEmpty {
            let img = drawing.image(from: drawing.bounds, scale: 2.0)
            let r = aspectFitRect(imageSize: img.size, bounds: CGRect(origin: .zero, size: size)).insetBy(dx: 24, dy: 24)
            img.draw(in: r, blendMode: .normal, alpha: pickedImage == nil ? 1.0 : 0.9)
        }

        let cover = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        if let cover, let data = cover.pngData() {
            try? data.write(to: coverURL(folderID: folderID, notebookID: notebookID), options: .atomic)
        }
    }

    private func aspectFitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        let x = bounds.midX - w/2, y = bounds.midY - h/2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Dirs
    private func dir(forFolder folderID: UUID) -> URL {
        if folderID == Self.rootPseudoID { return rootDir }
        return base.appendingPathComponent(folderID.uuidString, isDirectory: true)
    }
    private func dir(forFolder folderID: UUID, notebookID: UUID) -> URL {
        dir(forFolder: folderID).appendingPathComponent(notebookID.uuidString, isDirectory: true)
    }
    // MARK: - Text boxes persistence
    private func textBoxesURL(folderID: UUID, notebookID: UUID) -> URL {
        dir(forFolder: folderID, notebookID: notebookID).appendingPathComponent("textboxes.json")
    }

    func loadTextBoxes(folderID: UUID, notebookID: UUID) -> [TextBox] {
        let url = textBoxesURL(folderID: folderID, notebookID: notebookID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TextBox].self, from: data)) ?? []
    }

    func saveTextBoxes(folderID: UUID, notebookID: UUID, boxes: [TextBox]) {
        let d = dir(forFolder: folderID, notebookID: notebookID)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = textBoxesURL(folderID: folderID, notebookID: notebookID)
        if let data = try? JSONEncoder().encode(boxes) {
            try? data.write(to: url, options: .atomic)
        }
    }

}
struct TextBox: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String = ""
    var x: CGFloat = 0       // in canvas points
    var y: CGFloat = 0
    var width: CGFloat = 520 // sensible default width
    var height: CGFloat = 120
    var fontSize: CGFloat = 18
}

