import PencilKit
import PhotosUI
import SwiftUI
import UIKit

struct PencilCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var inkColor: UIColor
    var tool: AppState.CanvasTool
    var isOpaquePaper: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = makeTool()
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        canvas.tool = makeTool()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func makeTool() -> PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: inkColor, width: 8)
        case .eraser:
            return PKEraserTool(.bitmap)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvasView

        init(_ parent: PencilCanvasView) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

struct CanvasScreen: View {
    @EnvironmentObject private var appState: AppState
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmUnpair = false

    private var inkColors: [Color] {
        appState.backgroundPhoto == nil ? DoodleTheme.inks : DoodleTheme.photoInks
    }

    private var canSend: Bool {
        !appState.canvasDrawing.strokes.isEmpty || appState.backgroundPhoto != nil
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                canvasCard
                    .padding(.top, 12)
                Text("Appears exactly like this on \(appState.partnerName)'s widget")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                Spacer(minLength: 12)
                toolbar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
            }
        }
        .confirmationDialog(
            "Unpair from \(appState.partnerName)?",
            isPresented: $confirmUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { Task { await appState.unpair() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your shared doodles will be deleted for both of you.")
        }
        .onChange(of: photoItem) { _, item in
            Task {
                guard let item,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data)
                else { return }
                appState.backgroundPhoto = image
                // Switch default ink to white on photos
                appState.selectedInk = .white
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                appState.route = .latest
            } label: {
                Image(systemName: "clock")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.primary)

            Spacer()

            Text(appState.partnerName)
                .font(.headline)

            Spacer()

            Menu {
                Button("History", systemImage: "clock") {
                    appState.route = .history
                }
                Button("Clear canvas", systemImage: "trash", role: .destructive) {
                    appState.clearCanvas()
                }
                Button("Unpair", systemImage: "person.2.slash", role: .destructive) {
                    confirmUnpair = true
                }
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    appState.signOut()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var canvasCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(DoodleTheme.paper)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)

            if let photo = appState.backgroundPhoto {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }

            PencilCanvasView(
                drawing: $appState.canvasDrawing,
                inkColor: appState.selectedInk,
                tool: appState.tool,
                isOpaquePaper: appState.backgroundPhoto == nil
            )
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .frame(width: 361, height: 361)
        .frame(maxWidth: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(Array(inkColors.enumerated()), id: \.offset) { _, color in
                let ui = UIColor(color)
                let selected = appState.tool == .pen && colorsMatch(appState.selectedInk, ui)
                Button {
                    appState.selectedInk = ui
                    appState.tool = .pen
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .overlay {
                            if selected {
                                Circle().stroke(Color.primary, lineWidth: 2).padding(-3)
                            }
                        }
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
                    .background(appState.backgroundPhoto != nil ? Color.primary.opacity(0.08) : .clear, in: Circle())
            }
            .foregroundStyle(.primary)

            Button {
                appState.tool = appState.tool == .eraser ? .pen : .eraser
            } label: {
                Image(systemName: "eraser")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
                    .background(appState.tool == .eraser ? Color.primary.opacity(0.08) : .clear, in: Circle())
            }
            .foregroundStyle(.primary)

            Button {
                undoLastStroke()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
            }
            .foregroundStyle(.primary)

            Spacer(minLength: 4)

            Button {
                Task { await appState.sendCurrentDoodle() }
            } label: {
                Group {
                    if appState.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.body.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(DoodleTheme.pink, in: Circle())
                .opacity(canSend ? 1 : 0.4)
            }
            .disabled(!canSend || appState.isSending)
        }
        .padding(.horizontal, 16)
        .frame(height: 66)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func undoLastStroke() {
        var drawing = appState.canvasDrawing
        guard !drawing.strokes.isEmpty else { return }
        drawing.strokes.removeLast()
        appState.canvasDrawing = drawing
    }

    private func colorsMatch(_ a: UIColor, _ b: UIColor) -> Bool {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return abs(ar - br) < 0.02 && abs(ag - bg) < 0.02 && abs(ab - bb) < 0.02
    }
}
