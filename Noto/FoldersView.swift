import SwiftUI

// ROOT BROWSER (first screen)
struct FoldersView: View {
    @State private var warmed = false

    var body: some View {
        NavigationStack {
            BrowserGrid(title: "Browser")
                .navigationTitle("All Notes")
        }
    }
}



// Reusable grid for any container (nil = root)
// Reusable grid for any container (nil = root)
private struct BrowserGrid: View {
    @EnvironmentObject var store: NotebookStore

    // allow calling as BrowserGrid(title:) for root
    init(containerID: UUID? = nil, title: String) {
        self.containerID = containerID
        self.title = title
    }
    let containerID: UUID?
    let title: String

    // ---- New-sheet state (item-based) ----
    enum CreateKind { case folder, notebook }
    private struct NewSheetContext: Identifiable { let id = UUID(); let kind: CreateKind }
    @State private var newName = ""
    @State private var newSheet: NewSheetContext? = nil
    
    @State private var namePrompt: TextFieldPrompt? = nil
    
    @State private var didPresentNewOnce = false

    // ---- Rename/Delete state (unchanged) ----
    @State private var renamingFolder: Folder?
    @State private var renameFolderText = ""
    @State private var renamingNote: NotebookMeta?
    @State private var renameNoteText = ""
    @State private var confirmDeleteNote: NotebookMeta?

    var body: some View {
        ScrollView {
            let cols = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)]
            LazyVGrid(columns: cols, spacing: 16) {

                // New… tile (menu) — NO showNameSheet/createKind anymore
                NewChoiceTile {
                    namePrompt = TextFieldPrompt(
                        kind: .folder,
                        title: "New Folder",
                        placeholder: "Folder name",
                        initialText: "New Folder",
                        confirmTitle: "Create Folder"
                    )
                } onNotebook: {
                    namePrompt = TextFieldPrompt(
                        kind: .notebook,
                        title: "New Notebook",
                        placeholder: "Notebook title",
                        initialText: "Untitled",
                        confirmTitle: "Create Notebook"
                    )
                }


                // Folders first
                ForEach(store.childFolders(of: containerID)) { f in
                    NavigationLink {
                        BrowserGrid(containerID: f.id, title: f.name)
                            .navigationTitle(f.name)
                    } label: {
                        FolderTile(name: f.name, count: f.notebooks.count)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            renamingFolder = f
                            renameFolderText = f.name
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.deleteFolder(id: f.id)
                        }
                    }
                }

                // Then notebooks
                ForEach(store.childNotebooks(of: containerID)) { nb in
                    NavigationLink {
                        ContentView(folderID: containerID ?? NotebookStore.rootPseudoID,
                                    notebookID: nb.id)
                            .navigationTitle(nb.title)
                    } label: {
                        NotebookCard(
                            title: nb.title,
                            updated: nb.updated,
                            cover: store.coverImage(folderID: containerID ?? NotebookStore.rootPseudoID,
                                                    notebookID: nb.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            renamingNote = nb
                            renameNoteText = nb.title
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.deleteNotebook(in: containerID, notebookID: nb.id)
                        }
                    }
                }
            }
            .padding(16)
        }
        // ---- New sheet (item-based so the labels are always correct) ----
//        .sheet(item: $newSheet) { ctx in
//            NameSheet(
//                title: ctx.kind == .folder ? "New Folder" : "New Notebook",
//                confirmLabel: ctx.kind == .folder ? "Create Folder" : "Create Notebook",
//                text: $newName
//            ) {
//                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
//                switch ctx.kind {
//                case .folder:   store.createFolder(in: containerID, name: trimmed.isEmpty ? "New Folder" : trimmed)
//                case .notebook: _ = store.createNotebook(in: containerID, title: trimmed.isEmpty ? "Untitled" : trimmed)
//                }
//            }
//            .onAppear { didPresentNewOnce = true }
//        }
//        .transaction { tx in
//            if !didPresentNewOnce { tx.disablesAnimations = true }
//        }
        .textFieldPrompt($namePrompt) { entered, kind in
            let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .folder:
                store.createFolder(in: containerID, name: trimmed.isEmpty ? "New Folder" : trimmed)
            case .notebook:
                _ = store.createNotebook(in: containerID, title: trimmed.isEmpty ? "Untitled" : trimmed)
            }
        }

        // ---- Rename sheets/alerts (unchanged) ----
        .sheet(item: $renamingFolder) { f in
            RenameSheet(title: "Rename Folder", text: $renameFolderText) {
                store.renameFolder(id: f.id, to: renameFolderText)
            }
        }
        .sheet(item: $renamingNote) { nb in
            RenameSheet(title: "Rename Notebook", text: $renameNoteText) {
                store.renameNotebook(in: containerID, notebookID: nb.id, to: renameNoteText)
            }
        }
        .alert("Delete this notebook?",
               isPresented: Binding(get: { confirmDeleteNote != nil },
                                   set: { _ in confirmDeleteNote = nil }),
               presenting: confirmDeleteNote) { nb in
            Button("Delete", role: .destructive) {
                store.deleteNotebook(in: containerID, notebookID: nb.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { nb in
            Text("“\(nb.title)” will be removed permanently.")
        }
    }
}
    
// MARK: - Folder Tile (icon only, no card)
private struct FolderTile: View {
    var name: String
    var count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One big folder icon (no background)
            ZStack {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical) // nice depth without a box
                    .foregroundStyle(.yellow)            // or .tint for accent color
                    .padding(20)
                    .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3) // optional
            }
            .aspectRatio(1, contentMode: .fit) // keeps grid squares consistent

            // Title
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)

            // (Optional) notebook count—delete if you want ultra-minimal
            Text(count == 1 ? "1 notebook" : "\(count) notebooks")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)              // bigger tap target
        .contentShape(Rectangle())          // tap anywhere in the tile
    }
}




// Dashed card with a menu for Folder/Notebook
private struct NewChoiceTile: View {
    var onFolder: () -> Void
    var onNotebook: () -> Void

    init(onFolder: @escaping () -> Void, onNotebook: @escaping () -> Void) {
        self.onFolder = onFolder
        self.onNotebook = onNotebook
    }

    var body: some View {
        Menu {
            Button("Folder", systemImage: "folder.badge.plus", action: onFolder)
            Button("Notebook", systemImage: "square.and.pencil", action: onNotebook)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle").font(.system(size: 36, weight: .semibold))
                    Text("New…").font(.subheadline)
                }
                .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("New…")
        }
        .buttonStyle(.plain)
    }
}

struct NotebookCard: View {
    let title: String
    let updated: Date
    let cover: UIImage?
    private let corner: CGFloat = 14
    private let aspect: CGFloat = 4.0/5.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let ui = cover {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: w, height: w * aspect)
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .overlay(RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1))

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(updated, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: w, alignment: .leading)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }
}

// MARK: - Sheets
private struct NameSheet: View {
    var title: String
    var confirmLabel: String = "Create"
    @Binding var text: String
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                FirstResponderTextField(text: $text, placeholder: "Name") {
                    onConfirm(); dismiss()
                }
                .frame(height: 36)                 // compact height
                .padding(.horizontal)
            }
            .padding(.vertical, 18)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) { onConfirm(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .presentationDetents([.height(160), .medium])   // small, clean detent
    }
}





private struct RenameSheet: View {
    var title: String
    @Binding var text: String
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $text) }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onConfirm()
                            dismiss()
                        }.keyboardShortcut(.defaultAction)
                    }
                }
        }
        .presentationDetents([.height(180), .medium])
    }
}


// A UITextField that becomes first responder immediately (no focus lag)
// A UITextField that becomes first responder immediately (no focus lag)
private struct FirstResponderTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Name"
    var onSubmit: () -> Void
    var selectAllOnFocus: Bool = true

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: FirstResponderTextField
        init(_ parent: FirstResponderTextField) { self.parent = parent }
        @objc func editingChanged(_ tf: UITextField) { parent.text = tf.text ?? "" }
        func textFieldShouldReturn(_ tf: UITextField) -> Bool { parent.onSubmit(); return true }
        func textFieldDidBeginEditing(_ tf: UITextField) {
            if parent.selectAllOnFocus {
                // Select all text on first focus for easy overwrite
                tf.selectedTextRange = tf.textRange(from: tf.beginningOfDocument, to: tf.endOfDocument)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.text = text
        tf.returnKeyType = .done
        tf.autocapitalizationType = .words
        tf.autocorrectionType = .no
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)

        // Slim system-like look (keep your current styling if you’ve customized)
        tf.backgroundColor = UIColor.secondarySystemBackground
        tf.layer.cornerRadius = 10
        tf.layer.borderWidth = 1 / UIScreen.main.scale
        tf.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        tf.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 0))
        tf.leftViewMode = .always

        // ✅ Built-in clear (the little ⓧ)
        tf.clearButtonMode = .whileEditing

        // Instant focus
        DispatchQueue.main.async { tf.becomeFirstResponder() }
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text { uiView.text = text }
    }
}

// MARK: - Fast text-field alert (UIKit) for instant first-open
// MARK: - Fast text-field alert (UIKit) – carries its kind so creation works
private enum CreateKind { case folder, notebook }

private struct TextFieldPrompt: Identifiable {
    let id = UUID()
    var kind: CreateKind
    var title: String
    var message: String? = nil
    var placeholder: String = "Name"
    var initialText: String = ""
    var confirmTitle: String = "Create"
}

private struct TextFieldAlertPresenter: UIViewControllerRepresentable {
    @Binding var prompt: TextFieldPrompt?
    var onSubmit: (String, CreateKind) -> Void
    var onCancel: () -> Void = {}

    final class Coordinator: NSObject { var host: UIViewController? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.isHidden = true
        context.coordinator.host = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let prompt = prompt, uiViewController.presentedViewController == nil else { return }

        let alert = UIAlertController(title: prompt.title, message: prompt.message, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = prompt.placeholder
            tf.text = prompt.initialText
            tf.clearButtonMode = .whileEditing
            tf.returnKeyType = .done
            DispatchQueue.main.async {
                tf.becomeFirstResponder()
                tf.selectedTextRange = tf.textRange(from: tf.beginningOfDocument, to: tf.endOfDocument)
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.prompt = nil
            onCancel()
        })
        alert.addAction(UIAlertAction(title: prompt.confirmTitle, style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            // ✅ Pass the kind BEFORE clearing the binding
            let kind = prompt.kind
            self.prompt = nil
            onSubmit(text, kind)
        })
        uiViewController.present(alert, animated: true, completion: nil)
    }
}

private extension View {
    func textFieldPrompt(_ prompt: Binding<TextFieldPrompt?>,
                         onSubmit: @escaping (String, CreateKind) -> Void,
                         onCancel: @escaping () -> Void = {}) -> some View {
        background(TextFieldAlertPresenter(prompt: prompt, onSubmit: onSubmit, onCancel: onCancel))
    }
}


// ===== Existing visual pieces from your file =====
// - FolderTile / FolderShape are unchanged (we keep your look)
// - NameSheet / RenameSheet reused from your file

// (Paste your existing FolderTile / FolderShape / NameSheet / RenameSheet structs here
// if Xcode complains; otherwise they’re already in this file from before.)
