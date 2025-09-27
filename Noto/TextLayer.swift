import SwiftUI

// Use the viewport you already defined in EraserOverlay
typealias Viewport = EraserOverlay.CanvasViewport

// If you want stricter clamping, bump these to your page size later.
private let canvasMaxSize = CGSize(width: 4096, height: 8192)
private let docLeftMargin: CGFloat = 48

// MARK: - TextLayer
// Props match what you're already passing from ContentView: boxes, selectedID, viewport, nextDefaultOrigin()
struct TextLayer: View {
    @Binding var boxes: [TextBox]
    @Binding var selectedID: UUID?

    var viewport: Viewport
    var nextDefaultOrigin: () -> CGPoint

    // Runtime-only state (not persisted)
    @State private var dragStartByID: [UUID: CGPoint] = [:]   // canvas coords
    @State private var axisUnlocked: Set<UUID> = []           // allow free horizontal after intent
    @State private var guideScreenX: CGFloat? = nil           // vertical guide while snapping

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Vertical guide while snapping
                if let gx = guideScreenX {
                    Path { p in
                        p.move(to: CGPoint(x: gx, y: 0))
                        p.addLine(to: CGPoint(x: gx, y: geo.size.height))
                    }
                    .stroke(Color.blue.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .allowsHitTesting(false)
                }

                // SAFE, index-driven loop
                ForEach(boxes.indices, id: \.self) { i in
                    let id = boxes[i].id

                    SingleTextBox(
                        box: $boxes[i],
                        isSelected: Binding(
                            get: { selectedID == id },
                            set: { newVal in selectedID = newVal ? id : nil }
                        ),
                        viewport: viewport,
                        onDelete: {
                            // delete by index (safe during ForEach by indices)
                            let deleted = boxes[i].id
                            boxes.remove(at: i)
                            if selectedID == deleted { selectedID = nil }
                        },
                        onDragChanged: { v in
                            // select on drag
                            selectedID = id

                            // stable starting point per-box (canvas coords)
                            if dragStartByID[id] == nil {
                                dragStartByID[id] = CGPoint(x: boxes[i].x, y: boxes[i].y)
                            }
                            let start = dragStartByID[id]!
                            let scale = max(viewport.zoomScale, 0.001)

                            // screen → canvas delta
                            var newX = start.x + v.translation.width  / scale
                            let newY = start.y + v.translation.height / scale

                            // vertical-first: lock X until clear horizontal intent
                            if !axisUnlocked.contains(id) {
                                if abs(v.translation.width) < 20 {
                                    let snap = snapCandidate(forCanvasX: start.x, excluding: id)
                                    newX = snap.didSnap ? snap.canvasX : start.x
                                    guideScreenX = snap.didSnap ? snap.screenX : nil
                                } else {
                                    axisUnlocked.insert(id) // unlock horizontal
                                }
                            } else {
                                let snap = snapCandidate(forCanvasX: newX, excluding: id)
                                if snap.didSnap {
                                    newX = snap.canvasX
                                    guideScreenX = snap.screenX
                                } else {
                                    guideScreenX = nil
                                }
                            }

                            // clamp and write back through the binding
                            boxes[i].x = clampX(newX, width: boxes[i].width)
                            boxes[i].y = clampY(newY, height: boxes[i].height)
                        },
                        onDragEnded: {
                            dragStartByID[id] = nil
                            axisUnlocked.remove(id)
                            guideScreenX = nil
                        },
                        onResizeChanged: { deltaInScreen in
                            let scale = max(viewport.zoomScale, 0.001)
                            let delta = CGSize(width: deltaInScreen.width/scale,
                                               height: deltaInScreen.height/scale)

                            let minW: CGFloat = 160, minH: CGFloat = 60
                            let maxW = canvasMaxSize.width  - boxes[i].x - 8
                            let maxH = canvasMaxSize.height - boxes[i].y - 8
                            var w = max(minW, min(maxW, boxes[i].width  + delta.width))
                            var h = max(minH, min(maxH, boxes[i].height + delta.height))

                            // optional width snapping
                            let widths: [CGFloat] = [360, 420, 480, 520, 600]
                            if let nearest = widths.min(by: { abs($0 - w) < abs($1 - w) }),
                               abs(nearest - w) < 10 { w = nearest }

                            boxes[i].width = w
                            boxes[i].height = h
                        }
                    )
                    .position(x: boxes[i].x + boxes[i].width/2,
                              y: boxes[i].y + boxes[i].height/2)
                }
            }
        }
    }

    // MARK: - Helpers

    private func clampX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, x), max(0, canvasMaxSize.width - width))
    }
    private func clampY(_ y: CGFloat, height: CGFloat) -> CGFloat {
        min(max(0, y), max(0, canvasMaxSize.height - height))
    }

    private func canvasXToScreenX(_ x: CGFloat) -> CGFloat {
        // project a canvas X into screen X using current viewport
        (x - viewport.contentOffset.x) * max(viewport.zoomScale, 0.001)
    }

    // Snap to doc left margin & other boxes' left edges
    private func snapCandidate(forCanvasX x: CGFloat, excluding id: UUID?) -> (didSnap: Bool, canvasX: CGFloat, screenX: CGFloat) {
        let thresholdPx: CGFloat = 8
        var candidates: [CGFloat] = [docLeftMargin]
        for b in boxes where b.id != id { candidates.append(b.x) }

        let targetSX = canvasXToScreenX(x)
        var best: (dx: CGFloat, cx: CGFloat, sx: CGFloat)? = nil
        for cx in candidates {
            let sx = canvasXToScreenX(cx)
            let dx = abs(sx - targetSX)
            if dx < thresholdPx && (best == nil || dx < best!.dx) {
                best = (dx, cx, sx)
            }
        }
        if let b = best { return (true, b.cx, b.sx) }
        return (false, x, 0)
    }
}

// MARK: - SingleTextBox
// Kept inside this file so you don't need new files.
// Swap TextEditor for your UITextView wrapper if you have one.
private struct SingleTextBox: View {
    @Binding var box: TextBox
    @Binding var isSelected: Bool
    var viewport: Viewport

    var onDelete: () -> Void
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: () -> Void
    var onResizeChanged: (CGSize) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Outline
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0),
                                lineWidth: isSelected ? 1.5 : 1)
                )

            // The editor (replace with your UITextView wrapper for crisper IME/selection)
            TextEditor(text: Binding(
                get: { box.text },
                set: { box.text = $0 }
            ))
            .font(.system(size: 16))
            .scrollContentBackground(.hidden)   // <-- THIS removes the white
            .background(Color.clear)            // keep clear
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .disabled(false)

            // Delete ⓧ
            if isSelected {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.secondary)
                        .shadow(radius: 1)
                }
                .buttonStyle(.plain)
                .offset(x: max(0, box.width - 20), y: -10)
            }

            // Resize nub (bottom-right)
            if isSelected {
                Circle()
                    .fill(Color.secondary.opacity(0.9))
                    .frame(width: 12, height: 12)
                    .position(x: max(12, box.width - 6), y: max(12, box.height - 6))
                    .gesture(
                        DragGesture()
                            .onChanged { v in onResizeChanged(v.translation) }
                    )
            }
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    isSelected = true
                    onDragChanged(v)
                }
                .onEnded { _ in onDragEnded() }
        )
        .onTapGesture { isSelected = true }
    }
}
