#if DEBUG
import PencilKit
import PhotosUI
import SwiftUI
import UIKit

/// Text placed on the doodle. `center` is in canvas points.
struct ProtoTextItem: Identifiable, Equatable {
    let id = UUID()
    var text = ""
    var color: UIColor
    var center: CGPoint
}

/// Everything on the canvas, for undo / redo.
struct ProtoCanvasState: Equatable {
    var drawing = PKDrawing()
    var texts: [ProtoTextItem] = []
    var photo: UIImage?
    var background = UIColor(DoodleTheme.paper)
}

/// Draw back / draw for someone. No reply banner: the widget only shows the doodle, so what it answers can't travel with it.
struct ProtoDrawView: View {
    @EnvironmentObject private var store: PrototypeStore
    @Environment(\.dismiss) private var dismiss
    let target: ProtoDrawTarget
    var onSent: () -> Void = {}

    /// Everyone this doodle goes to, in the order picked.
    @State private var recipientIDs: [String] = []
    @State private var drawing = PKDrawing()
    @State private var texts: [ProtoTextItem] = []
    /// A photo to draw on, from the library or the camera. Fills the canvas behind the drawing.
    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    /// Background tool: the bar shows background colours and photo options instead of pen colours.
    @State private var backgroundMode = false
    /// Photo tool: the bar shows Library / Camera / Remove instead of pen colours.
    @State private var photoMode = false
    @State private var background = UIColor(DoodleTheme.paper)
    @State private var ink: UIColor = UIColor(DoodleTheme.inks[0])  // follows the selected slot
    @State private var tool: AppState.CanvasTool = .pen
    @AppStorage("protoBrush") private var brush: ProtoBrush = .medium
    @State private var choosingRecipient = false
    /// The colour set showing in the row; swipe the row to change it. Remembered.
    @AppStorage("protoPalette") private var paletteName = ProtoPalette.all[0].name
    @State private var visiblePalette: String?
    @State private var barWidth: CGFloat = 361

    // Undo / redo over strokes and text alike.
    @State private var committed = ProtoCanvasState()
    @State private var undoStack: [ProtoCanvasState] = []
    @State private var redoStack: [ProtoCanvasState] = []
    /// The next drawing change comes from undo/redo, not the pen.
    @State private var restoring = false

    @State private var editingID: UUID?
    @State private var dragStart: CGPoint?
    @FocusState private var textFocused: Bool
    @State private var canvasSide: CGFloat = 361

    private static let textSize: CGFloat = 30

    private var recipients: [ProtoPerson] { recipientIDs.compactMap(store.person) }
    private var canSend: Bool { !drawing.strokes.isEmpty || texts.contains { !$0.text.isEmpty } || photo != nil }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
            VStack(spacing: 16) {
                canvas
                Spacer(minLength: 0)
                // While typing, the keyboard's own colour bar (with Done) takes over: one bar, never two.
                tools
                    .opacity(editingID == nil ? 1 : 0)
                    .allowsHitTesting(editingID == nil)
                    .animation(.snappy(duration: 0.2), value: editingID)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            // Typing shouldn't squash the canvas; colours ride above the keyboard instead.
            .ignoresSafeArea(.keyboard)
            // Typing row: its own layer, so it rides above the keyboard while the canvas keeps its size.
            // (Not the keyboard toolbar, which draws its own white band.)
            if editingID != nil {
                typingRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) { recipientPicker }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                        .disabled(undoStack.isEmpty)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                        .disabled(redoStack.isEmpty)
                }
            }
        }
        .onAppear {
            recipientIDs = [target.personID]
            visiblePalette = paletteName
            ink = palette.colors[0]
        }
        .onChange(of: drawing) { _, _ in
            if restoring { restoring = false } else { commit() }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    setPhoto(image)
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            ProtoCameraView { image in setPhoto(image) }
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var recipientPicker: some View {
        if let first = recipients.first {
            Button {
                choosingRecipient = true
            } label: {
                if recipients.count == 1 {
                    ProtoPersonHeader(person: first, showsChevron: true)
                } else {
                    ProtoRecipientsHeader(people: recipients)
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $choosingRecipient) {
                ProtoRecipientSheet(selection: $recipientIDs)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Color(background))
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: canvasSide, height: canvasSide)
                    .clipped()
                    .transition(.opacity)
            }
            ProtoFingerCanvas(drawing: $drawing, ink: ink, tool: tool, width: brush.width)
            if editingID != nil {
                // Tap anywhere else on the canvas to finish typing.
                Color.clear.contentShape(Rectangle()).onTapGesture { finishEditing() }
            }
            ForEach(texts) { item in
                textView(textBinding(item))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasSide = $0 }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    /// Looks the text up by id, never by position: a text removed (emptied, or undone) while its
    /// field is still on screen is simply ignored instead of crashing on a stale index.
    private func textBinding(_ item: ProtoTextItem) -> Binding<ProtoTextItem> {
        Binding(
            get: { texts.first { $0.id == item.id } ?? item },
            set: { updated in
                if let i = texts.firstIndex(where: { $0.id == item.id }) { texts[i] = updated }
            }
        )
    }

    @ViewBuilder
    private func textView(_ item: Binding<ProtoTextItem>) -> some View {
        let font = Font.system(size: Self.textSize, weight: .bold, design: .rounded)
        if editingID == item.wrappedValue.id {
            TextField("", text: item.text, prompt: Text("Type").foregroundStyle(Color(item.wrappedValue.color).opacity(0.35)))
                .font(font)
                .foregroundStyle(Color(item.wrappedValue.color))
                .tint(Color(item.wrappedValue.color))
                .multilineTextAlignment(.center)
                .focused($textFocused)
                .submitLabel(.done)
                .onSubmit(finishEditing)
                .fixedSize()
                .position(item.wrappedValue.center)
        } else {
            Text(item.wrappedValue.text)
                .font(font)
                .foregroundStyle(Color(item.wrappedValue.color))
                .fixedSize()
                .padding(8)
                .contentShape(Rectangle())
                .position(item.wrappedValue.center)
                .onTapGesture { startEditing(item.wrappedValue.id) }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStart ?? item.wrappedValue.center
                            dragStart = start
                            item.wrappedValue.center = clamp(CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height))
                        }
                        .onEnded { _ in
                            dragStart = nil
                            commit()
                        }
                )
        }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 20), canvasSide - 20), y: min(max(p.y, 20), canvasSide - 20))
    }

    // MARK: - Tools

    private var tools: some View {
        VStack(spacing: 12) {
            Group {
                if photoMode {
                    toolBar { barTitle("Photo") } content: { photoRow }
                } else if backgroundMode {
                    toolBar { barTitle("Background") } content: { backgroundRow }
                } else {
                    toolBar { paletteLabel } content: { colorRow(compact: false) }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
                }
            }
            .transition(.opacity)
            .animation(.snappy(duration: 0.25), value: backgroundMode)
            .animation(.snappy(duration: 0.25), value: photoMode)
            HStack {
                HStack(spacing: 4) {
                    toolButton("pencil.tip", label: "Pen", selected: tool == .pen && editingID == nil && !backgroundMode && !photoMode) {
                        finishEditing()
                        backgroundMode = false
                        photoMode = false
                        tool = .pen
                    }
                    toolButton("square.fill", label: "Background", selected: backgroundMode) {
                        finishEditing()
                        photoMode = false
                        backgroundMode.toggle()
                    }
                    toolButton("textformat", label: "Text", selected: editingID != nil) {
                        backgroundMode = false
                        photoMode = false
                        addText()
                    }
                    photoButton
                }
                .padding(6)
                .glassEffect(.regular, in: Capsule())
                Spacer()
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(DoodleTheme.pink, in: Circle())
                        .opacity(canSend ? 1 : 0.4)
                }
                .disabled(!canSend)
            }
        }
        .animation(.snappy, value: paletteName)
    }

    private static let backgrounds: [UIColor] = [
        UIColor(DoodleTheme.paper),
        .white,
        UIColor(Color(hex: 0x1C1C1E)),
        UIColor(Color(hex: 0xFFE3EA)),
        UIColor(Color(hex: 0xE3F0FF)),
        UIColor(Color(hex: 0xE3F7EA)),
        UIColor(Color(hex: 0xFFF4CC)),
    ]

    /// Background colours. A photo (from the photo tool) sits on top of the background.
    private var backgroundRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.backgrounds.indices, id: \.self) { i in
                let color = Self.backgrounds[i]
                let selected = photo == nil && Self.same(color, background)
                Button {
                    setBackground(color)
                } label: {
                    Circle()
                        .fill(Color(color))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
                        .overlay { if selected { Circle().stroke(Color.primary, lineWidth: 2).padding(-3) } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy, value: photo != nil)
    }

    private var photoButton: some View {
        toolButton("photo", label: "Photo", selected: photoMode) {
            finishEditing()
            backgroundMode = false
            photoMode.toggle()
        }
    }

    /// Photo to draw on: from the library or the camera.
    private var photoRow: some View {
        HStack(spacing: 0) {
            photoAction("Library", symbol: "photo.on.rectangle") { choosingPhoto = true }
            photoAction("Camera", symbol: "camera") { takingPhoto = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            if photo != nil {
                photoAction("Remove", symbol: "trash", role: .destructive) { setPhoto(nil) }
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: photo != nil)
    }

    private func photoAction(_ title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }

    /// A background colour replaces any photo.
    private func setBackground(_ color: UIColor) {
        finishEditing()
        withAnimation(.smooth) {
            background = color
            photo = nil
        }
        commit()
    }

    private func setPhoto(_ image: UIImage?) {
        finishEditing()
        withAnimation(.smooth) { photo = image }
        commit()
    }

    /// Aspect-fill, centred: the same crop the canvas shows.
    static func drawFilling(_ image: UIImage, in rect: CGRect) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsGetCurrentContext()?.saveGState()
        UIRectClip(rect)
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        UIGraphicsGetCurrentContext()?.restoreGState()
    }

    private func toolButton(_ symbol: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .background(selected ? Color.primary.opacity(0.1) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    /// While typing: the colour sets (still swipeable) and Done, floating above the keyboard.
    private var typingRow: some View {
        HStack(alignment: .bottom) {
            VStack(spacing: 0) {
                paletteLabel.padding(.top, 6)
                palettePager(swatch: 22, pageWidth: Self.compactPageWidth)
                    .frame(height: 38)
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer()
                Button("Done") { finishEditing() }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

    /// A bottom bar with its title inside, on top: "Classic ●○○○", "Background", "Photo".
    private func toolBar<Label: View, Content: View>(@ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            label().padding(.top, 8)
            content().frame(height: 46)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func barTitle(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private static let compactPageWidth: CGFloat = 6 * 36

    /// Colour sets, a page at a time. Shared by the colour bar and the typing row.
    private func palettePager(swatch size: CGFloat, pageWidth width: CGFloat) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(ProtoPalette.all) { set in
                    HStack(spacing: 0) {
                        ForEach(set.colors.indices, id: \.self) { i in
                            swatch(set.colors[i], size: size).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: width, height: size + 18) // room for the selection ring
                    .id(set.name)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visiblePalette)
        .scrollIndicators(.hidden)
        .frame(width: width, height: size + 18)
        .onChange(of: visiblePalette) { _, name in
            if let name, name != paletteName { paletteName = name }
        }
        // A pager that appears later (the typing row) starts on the current set, not the first.
        .onAppear { proxy.scrollTo(paletteName, anchor: .leading) }
        }
    }

    private func colorRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 8) {
            if compact {
                ForEach(palette.colors.indices, id: \.self) { i in swatch(palette.colors[i], size: 22) }
            } else {
                // Swipe between colour sets, a page at a time.
                palettePager(swatch: 28, pageWidth: pageWidth)
                // Size and eraser only work with the pen, so they live with the pen's colours.
                Divider().frame(height: 24)
                Button {
                    brush = brush.next
                    if tool != .eraser { tool = .pen }
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: brush.dot, height: brush.dot)
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                        .animation(.snappy, value: brush)
                }
                .accessibilityLabel("Brush size")
                .accessibilityValue(brush.name)
                Button {
                    finishEditing()
                    tool = tool == .eraser ? .pen : .eraser
                } label: {
                    Image(systemName: "eraser")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                        .background(tool == .eraser ? Color.primary.opacity(0.1) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Eraser")
            }
        }
    }

    /// The colours fill the bar; the divider and eraser keep their size at the end.
    private var pageWidth: CGFloat { max(barWidth - 24 - 8 * 3 - 1 - 36 * 2, 120) }

    private var palette: ProtoPalette { ProtoPalette.all.first { $0.name == paletteName } ?? ProtoPalette.all[0] }

    /// "Classic ●○○○" under the row.
    private var paletteLabel: some View {
        HStack(spacing: 8) {
            Text(palette.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            HStack(spacing: 4) {
                ForEach(ProtoPalette.all) { set in
                    Circle()
                        .fill(Color.primary.opacity(set.name == palette.name ? 0.6 : 0.18))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .animation(.snappy, value: paletteName)
    }

    private func swatch(_ color: UIColor, size: CGFloat) -> some View {
        let selected = (tool == .pen || editingID != nil) && Self.same(color, ink)
        return Button {
            pickInk(color)
        } label: {
            Circle()
                .fill(Color(color))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .overlay { if selected { Circle().stroke(Color.primary, lineWidth: 2).padding(-3) } }
                .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(.plain)
    }

    /// New ink for the pen, and for the text being typed.
    private func pickInk(_ color: UIColor) {
        ink = color
        if let id = editingID, let i = texts.firstIndex(where: { $0.id == id }) {
            texts[i].color = color
        } else {
            tool = .pen
        }
    }

    static func same(_ a: UIColor, _ b: UIColor) -> Bool {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return abs(ar - br) < 0.02 && abs(ag - bg) < 0.02 && abs(ab - bb) < 0.02
    }

    // MARK: - Text

    private func addText() {
        finishEditing()
        let item = ProtoTextItem(color: ink, center: CGPoint(x: canvasSide / 2, y: canvasSide / 2))
        texts.append(item)
        startEditing(item.id)
    }

    private func startEditing(_ id: UUID) {
        editingID = id
        textFocused = true
    }

    /// Ends typing; an empty text is removed.
    private func finishEditing() {
        guard editingID != nil else { return }
        texts.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        editingID = nil
        textFocused = false
        commit()
    }

    // MARK: - Undo / redo

    private var current: ProtoCanvasState { ProtoCanvasState(drawing: drawing, texts: texts, photo: photo, background: background) }

    private func commit() {
        let now = current
        guard now != committed else { return }
        undoStack.append(committed)
        redoStack.removeAll()
        committed = now
    }

    private func undo() {
        finishEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(committed)
        apply(previous)
    }

    private func redo() {
        finishEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(committed)
        apply(next)
    }

    private func apply(_ state: ProtoCanvasState) {
        if state.drawing != drawing {
            restoring = true
            drawing = state.drawing
        }
        texts = state.texts
        photo = state.photo
        background = state.background
        committed = state
    }

    // MARK: - Send

    private func send() {
        finishEditing()
        let size = CGSize(width: 360, height: 360)
        let scale = size.width / max(canvasSide, 1)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            background.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            if let photo { Self.drawFilling(photo, in: CGRect(origin: .zero, size: size)) }
            drawing.image(from: CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide), scale: 3)
                .draw(in: CGRect(origin: .zero, size: size))
            let base = UIFont.systemFont(ofSize: Self.textSize * scale, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? base
            for item in texts where !item.text.isEmpty {
                let string = NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: item.color])
                let textSize = string.size()
                string.draw(at: CGPoint(x: item.center.x * scale - textSize.width / 2, y: item.center.y * scale - textSize.height / 2))
            }
        }
        for id in recipientIDs { store.send(image, to: id) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSent()
        dismiss()
    }
}

/// The system camera, for "Take Photo".
struct ProtoCameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ProtoCameraView
        init(_ parent: ProtoCameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Brush sizes for finger drawing: thick hides wobble, thin gives detail.
enum ProtoBrush: String, CaseIterable {
    case thin, medium, thick

    var width: CGFloat { [.thin: 4, .medium: 9, .thick: 18][self]! }
    /// The dot drawn in the size button.
    var dot: CGFloat { [.thin: 6, .medium: 11, .thick: 17][self]! }
    var name: String { rawValue.capitalized }
    var next: ProtoBrush { [.thin: .medium, .medium: .thick, .thick: .thin][self]! }
}

/// PencilKit canvas tuned for fingers: even (monoline) strokes, no zoom.
struct ProtoFingerCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var ink: UIColor
    var tool: AppState.CanvasTool
    var width: CGFloat

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.tool = makeTool()
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.drawing != drawing { canvas.drawing = drawing }
        canvas.tool = makeTool()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeTool() -> PKTool {
        switch tool {
        case .pen: return PKInkingTool(.monoline, color: ink, width: width)
        case .eraser: return PKEraserTool(.bitmap, width: width * 2.5)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: ProtoFingerCanvas
        init(_ parent: ProtoFingerCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

/// Curated colour sets for the pen: swipe the colour row to move between them.
struct ProtoPalette: Identifiable {
    let name: String
    let colors: [UIColor]
    var id: String { name }

    /// Six colours each, picked to stand for the set.
    static let all: [ProtoPalette] = [
        ProtoPalette(name: "Classic", hex: [0x1C1C1E, 0xFF3B30, 0xFFCC00, 0x34C759, 0x007AFF, 0xAF52DE]),
        ProtoPalette(name: "Pastel", hex: [0xF7A8C4, 0xFFC8A2, 0xFFE8A3, 0xB8E6C9, 0xA7CCF2, 0xCDB8F0]),
        ProtoPalette(name: "Neon", hex: [0xFF2E93, 0xFF6B00, 0xE6FF00, 0x39FF14, 0x00F0FF, 0x9D4DFF]),
        ProtoPalette(name: "Earth", hex: [0x4B3621, 0xC65D3B, 0xD9A441, 0x7C8B4A, 0x9CAF88, 0x4A6378]),
    ]
}

extension ProtoPalette {
    init(name: String, hex: [UInt32]) {
        self.init(name: name, colors: hex.map { UIColor(Color(hex: $0)) })
    }
}

/// Several recipients in the header: stacked avatars + "Dias & Mom" / "Dias +2".
struct ProtoRecipientsHeader: View {
    let people: [ProtoPerson]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: -10) {
                ForEach(people.prefix(3)) { person in
                    ProtoAvatar(person: person, size: 28)
                        .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                }
            }
            Text(people.count == 2 ? "\(people[0].name) & \(people[1].name)" : "\(people[0].name) +\(people.count - 1)")
                .font(.headline)
            Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}

/// Who you're drawing for, three to a row. Tap to pick one; "Select" to send to several.
struct ProtoRecipientSheet: View {
    @EnvironmentObject private var store: PrototypeStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: [String]
    @State private var picked: [String] = []
    @State private var selecting = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(store.people) { person in
                        Button {
                            tap(person)
                        } label: {
                            cell(person)
                        }
                        .buttonStyle(.plain)
                        .disabled(!person.isConnected)
                    }
                    if !selecting {
                        Button {
                            store.invitePerson()
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                Circle()
                                    .strokeBorder(DoodleTheme.pink.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .frame(width: 68, height: 68)
                                    .overlay {
                                        Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(DoodleTheme.pink)
                                    }
                                Text("Add someone")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(DoodleTheme.pink)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    Button {
                        selection = picked
                        dismiss()
                    } label: {
                        Text(picked.count == 1 ? "Draw for 1 person" : "Draw for \(picked.count) people")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(DoodleTheme.pink)
                    .disabled(picked.isEmpty)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(selecting ? "\(picked.count) selected" : "Draw for")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Cancel" : "Select") {
                        withAnimation(.snappy) {
                            selecting.toggle()
                            picked = selection
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .onAppear {
            picked = selection
            selecting = selection.count > 1
        }
        .presentationDetents([.fraction(0.55), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private func tap(_ person: ProtoPerson) {
        guard selecting else {
            selection = [person.id]
            dismiss()
            return
        }
        withAnimation(.snappy) {
            if let i = picked.firstIndex(of: person.id) { picked.remove(at: i) } else { picked.append(person.id) }
        }
    }

    private func cell(_ person: ProtoPerson) -> some View {
        let selected = (selecting ? picked : selection).contains(person.id)
        return VStack(spacing: 8) {
            ProtoAvatar(person: person, size: selected ? 60 : 68)
                .frame(width: 68, height: 68)
                .overlay {
                    if selected { Circle().strokeBorder(DoodleTheme.pink, lineWidth: 2.5) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(DoodleTheme.pink, in: Circle())
                            .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                    } else if selecting, person.isConnected {
                        // Empty circle: shows each person can be added.
                        Circle()
                            .fill(Color(.systemGroupedBackground))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5))
                    }
                }
                .opacity(person.isConnected ? 1 : 0.45)
            VStack(spacing: 1) {
                Text(person.name)
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                if !person.isConnected {
                    Text("Invite sent").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(.snappy, value: selected)
    }
}
#endif
