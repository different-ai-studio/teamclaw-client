# iMessage-style Session Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `RuntimeDetailView` into an iMessage-style chat detail: top toolbar swaps prev/next for Members + Agent settings; bottom replaces three glass capsules and the modal `ReplySheet` with a single inline pill (TextField + state-aware mic/send/stop button), plus a `+` drawer for files/camera/photos/model selection and an animated recording waveform overlay.

**Architecture:** Extract a pure `ComposerState` decision helper (testable, no SwiftUI). Build small focused subviews — `RecordingWaveform`, `CameraImagePicker`, `AttachmentDrawerSheet`, `SessionComposer` — each in its own file under `AgentDetail/`. `RuntimeDetailView` becomes a thin host that wires the existing `RuntimeDetailViewModel`, `VoiceRecorder`, `MemberListView`, and `RuntimeSettingsSheet` together with the new composer.

**Tech Stack:** SwiftUI (iOS 26 SDK per package manifest), Swift Testing (`@Suite`/`@Test`), `PhotosUI` (`PhotosPicker`), `UIKit` bridging via `UIViewControllerRepresentable` for camera capture, existing `VoiceRecorder` from AMUXCore (already exposes `audioLevel: Float`).

**Spec:** `docs/superpowers/specs/2026-04-28-imessage-style-composer-design.md`

---

## File Structure

**New files** (all under `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/`):
- `ComposerState.swift` — pure decision helpers (right-button kind, input-mode), no SwiftUI deps
- `RecordingWaveform.swift` — animated waveform driven by `VoiceRecorder.audioLevel`
- `CameraImagePicker.swift` — `UIViewControllerRepresentable` wrapping `UIImagePickerController` (camera source)
- `AttachmentDrawerSheet.swift` — `+` drawer (files / camera / photos / model picker)
- `SessionComposer.swift` — main composer view (input pill + state-aware action button + chip row + waveform overlay + slash popup)

**New tests** (under `ios/Packages/AMUXUI/Tests/AMUXUIPackageTests/`):
- `ComposerStateTests.swift` — covers all branches of the state machine

**Modified:**
- `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RuntimeDetailView.swift` — top toolbar swap, bottom inset replacement, deletion of `ReplySheet`, `RecordButton`, transcription preview bubble, prev/next nav state, `allAgentIds:` / `navigationPath:` parameters
- `ios/Packages/AMUXUI/Sources/AMUXUI/Root/SessionsTab.swift` — drop the two removed parameters from two call sites (lines ~166, ~176, ~240)
- `ios/Packages/AMUXUI/Sources/AMUXUI/Root/IdeasTab.swift` — drop the two removed parameters from two call sites (lines ~77, ~90)
- `ios/AMUXApp/Info.plist` — add `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`

---

## Task 1: Composer State Machine (TDD)

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ComposerState.swift`
- Create: `ios/Packages/AMUXUI/Tests/AMUXUIPackageTests/ComposerStateTests.swift`

This task is the only piece with non-trivial branching logic, and it's pure — perfect for TDD. Everything else this plan builds is SwiftUI assembly verified by build + simulator.

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/AMUXUI/Tests/AMUXUIPackageTests/ComposerStateTests.swift`:

```swift
import Testing
import AMUXCore
@testable import AMUXUI

@Suite("ComposerState decision helpers")
struct ComposerStateTests {

    // MARK: rightButton

    @Test("agent active forces stop, regardless of text or voice state")
    func agentActiveAlwaysStop() {
        #expect(ComposerState.rightButton(isAgentActive: true, hasText: false, voiceState: .idle) == .stop)
        #expect(ComposerState.rightButton(isAgentActive: true, hasText: true,  voiceState: .idle) == .stop)
        #expect(ComposerState.rightButton(isAgentActive: true, hasText: false, voiceState: .recording) == .stop)
        #expect(ComposerState.rightButton(isAgentActive: true, hasText: true,  voiceState: .recording) == .stop)
    }

    @Test("recording shows stopRecording when agent idle")
    func recordingShowsStopRecording() {
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: false, voiceState: .recording) == .stopRecording)
        // recording wins over hasText when agent idle
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: true,  voiceState: .recording) == .stopRecording)
    }

    @Test("idle + non-empty text shows send")
    func idleWithTextShowsSend() {
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: true, voiceState: .idle) == .send)
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: true, voiceState: .done) == .send)
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: true, voiceState: .denied) == .send)
    }

    @Test("idle + empty text shows mic")
    func idleEmptyShowsMic() {
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: false, voiceState: .idle) == .mic)
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: false, voiceState: .done) == .mic)
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: false, voiceState: .denied) == .mic)
        #expect(ComposerState.rightButton(isAgentActive: false, hasText: false, voiceState: .error("oops")) == .mic)
    }

    // MARK: inputMode

    @Test("input shows waveform only while recording")
    func waveformOnlyWhileRecording() {
        #expect(ComposerState.inputMode(voiceState: .recording) == .waveform)
        #expect(ComposerState.inputMode(voiceState: .idle) == .textField)
        #expect(ComposerState.inputMode(voiceState: .done) == .textField)
        #expect(ComposerState.inputMode(voiceState: .denied) == .textField)
        #expect(ComposerState.inputMode(voiceState: .error("x")) == .textField)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd ios/Packages/AMUXUI && swift test --filter ComposerStateTests
```

Expected: build error — `ComposerState` does not exist.

- [ ] **Step 3: Implement ComposerState**

Create `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ComposerState.swift`:

```swift
import AMUXCore

enum ComposerRightButton: Equatable {
    case stop          // agent is running — cancel task
    case stopRecording // voice recording in progress — finish recording
    case send          // idle, text non-empty
    case mic           // idle, text empty — start recording
}

enum ComposerInputMode: Equatable {
    case textField
    case waveform
}

enum ComposerState {
    static func rightButton(
        isAgentActive: Bool,
        hasText: Bool,
        voiceState: VoiceRecorder.State
    ) -> ComposerRightButton {
        if isAgentActive { return .stop }
        if voiceState == .recording { return .stopRecording }
        return hasText ? .send : .mic
    }

    static func inputMode(voiceState: VoiceRecorder.State) -> ComposerInputMode {
        voiceState == .recording ? .waveform : .textField
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd ios/Packages/AMUXUI && swift test --filter ComposerStateTests
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ComposerState.swift ios/Packages/AMUXUI/Tests/AMUXUIPackageTests/ComposerStateTests.swift
git commit -m "feat(ios): ComposerState decision helpers + tests"
```

---

## Task 2: RecordingWaveform View

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RecordingWaveform.swift`

Pure SwiftUI. Driven by `VoiceRecorder.audioLevel: Float` (0...1). Renders 7 vertical bars whose heights ease toward the live level with a small per-bar phase offset, giving a waveform feel even with a single audio level value.

- [ ] **Step 1: Implement RecordingWaveform**

Create `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RecordingWaveform.swift`:

```swift
import SwiftUI

struct RecordingWaveform: View {
    /// 0...1 normalized current audio level.
    let level: Float
    /// Number of bars to render.
    var barCount: Int = 7

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.subheadline)
                .foregroundStyle(.red)
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 3, height: barHeight(for: i))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(height: 22, alignment: .center)
            Text("Recording…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .onAppear { pulse = true }
        .accessibilityLabel("Recording")
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Each bar gets a phase offset so the row feels like a wave even though
        // there is only one live level value coming in.
        let l = CGFloat(max(0, min(1, level)))
        let phase = CGFloat(index) / CGFloat(barCount)
        let offset = sin(phase * .pi * 2 + (pulse ? .pi : 0)) * 0.25
        let h = max(0.15, min(1.0, l + offset))
        return 6 + h * 16  // 6...22
    }
}

#Preview {
    VStack(spacing: 12) {
        RecordingWaveform(level: 0.1)
        RecordingWaveform(level: 0.5)
        RecordingWaveform(level: 0.9)
    }
    .padding()
}
```

- [ ] **Step 2: Verify the package builds**

Run:
```bash
cd ios/Packages/AMUXUI && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RecordingWaveform.swift
git commit -m "feat(ios): RecordingWaveform view for composer recording overlay"
```

---

## Task 3: CameraImagePicker (UIKit bridge)

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/CameraImagePicker.swift`

Wraps `UIImagePickerController` so the composer drawer can present a camera capture flow. Saves the captured image to a temp file and returns the URL via callback.

- [ ] **Step 1: Implement CameraImagePicker**

Create `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/CameraImagePicker.swift`:

```swift
import SwiftUI
import UIKit

struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker
        init(_ parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.8) else {
                parent.onCancel()
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("camera-\(UUID().uuidString).jpg")
            do {
                try data.write(to: url)
                parent.onCapture(url)
            } catch {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
```

- [ ] **Step 2: Verify the package builds**

Run:
```bash
cd ios/Packages/AMUXUI && swift build
```

Expected: build succeeds. (Note: `swift build` against the iOS-only deployment target may not run device-side, but should at least typecheck. If `swift build` rejects the iOS-only deployment target, skip this step and rely on Xcode build verification in Task 9.)

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/CameraImagePicker.swift
git commit -m "feat(ios): CameraImagePicker UIKit bridge for composer drawer"
```

---

## Task 4: AttachmentDrawerSheet

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AttachmentDrawerSheet.swift`

The `+` drawer. Two sections — Attach (Files / Camera / Photos) and Model. Bindings: a list of attachment URLs and a selected model id.

- [ ] **Step 1: Implement AttachmentDrawerSheet**

Create `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AttachmentDrawerSheet.swift`:

```swift
import SwiftUI
import PhotosUI
import AMUXCore

struct AttachmentDrawerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var attachments: [URL]
    @Binding var selectedModelId: String?
    let runtime: Runtime?

    @State private var showFilePicker = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Attach") {
                    Button { showFilePicker = true } label: {
                        Label("Files", systemImage: "doc")
                    }
                    Button { showCamera = true } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                }

                if let runtime, !runtime.availableModels.isEmpty {
                    Section("Model") {
                        ForEach(runtime.availableModels) { model in
                            Button {
                                selectedModelId = model.id
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if model.id == resolvedSelection(runtime: runtime) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls where !attachments.contains(url) {
                        attachments.append(url)
                    }
                }
                dismiss()
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker(
                    onCapture: { url in
                        attachments.append(url)
                        showCamera = false
                        dismiss()
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("photo-\(UUID().uuidString).jpg")
                            try? data.write(to: url)
                            await MainActor.run { attachments.append(url) }
                        }
                    }
                    photoItems = []
                    await MainActor.run { dismiss() }
                }
            }
        }
    }

    private func resolvedSelection(runtime: Runtime) -> String? {
        if let selectedModelId, !selectedModelId.isEmpty { return selectedModelId }
        if let current = runtime.currentModel, !current.isEmpty { return current }
        return nil
    }
}
```

- [ ] **Step 2: Verify the package builds**

Run:
```bash
cd ios/Packages/AMUXUI && swift build
```

Expected: build succeeds (or is skipped per Task 3 caveat — verify in Xcode in Task 9).

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AttachmentDrawerSheet.swift
git commit -m "feat(ios): AttachmentDrawerSheet for composer + button"
```

---

## Task 5: SessionComposer

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SessionComposer.swift`

The main inline composer view: chip row above (when attachments present), one composer row with `+` left and pill (TextField + state-aware right button) right, slash command popup floating above the row when active.

This view owns its `+` drawer presentation, slash candidate state, and the pill's recording overlay. It exposes only what the parent needs: a binding for prompt text + selected model id + attachments, plus callbacks for send/cancel and a reference to the shared `VoiceRecorder`.

- [ ] **Step 1: Implement SessionComposer**

Create `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SessionComposer.swift`:

```swift
import SwiftUI
import AMUXCore
import AMUXSharedUI

struct SessionComposer: View {
    @Binding var promptText: String
    @Binding var selectedModelId: String?
    @Binding var attachments: [URL]

    let voiceRecorder: VoiceRecorder
    let runtime: Runtime?
    let isAgentActive: Bool
    let availableCommands: [SlashCommand]

    let onSend: () -> Void
    let onCancelTask: () -> Void

    @State private var showDrawer = false
    @State private var slashCandidates: [SlashCommand] = []
    @State private var hasPendingSlashCommand = false
    @FocusState private var inputFocused: Bool

    private var hasText: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rightButton: ComposerRightButton {
        ComposerState.rightButton(
            isAgentActive: isAgentActive,
            hasText: hasText,
            voiceState: voiceRecorder.state
        )
    }

    private var inputMode: ComposerInputMode {
        ComposerState.inputMode(voiceState: voiceRecorder.state)
    }

    private var slashPrefix: String? {
        guard let first = promptText.first, first == "/" else { return nil }
        let rest = promptText.dropFirst()
        guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(rest)
    }

    private var matchesKnownCommand: Bool {
        guard promptText.hasPrefix("/") else { return false }
        let after = promptText.dropFirst()
        let head = after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? String(after)
        guard !head.isEmpty else { return false }
        return availableCommands.contains(where: { $0.name == head })
    }

    var body: some View {
        VStack(spacing: 6) {
            if !slashCandidates.isEmpty {
                SlashCommandsPopup(
                    candidates: slashCandidates,
                    onTap: { cmd in
                        promptText = "/\(cmd.name) "
                        slashCandidates = []
                        hasPendingSlashCommand = true
                    }
                )
                .padding(.horizontal, 16)
                .animation(.easeInOut(duration: 0.15), value: slashCandidates)
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "doc").font(.caption)
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    attachments.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .liquidGlass(in: Capsule(), interactive: false)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                Text("attachments coming soon")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
            }

            HStack(spacing: 10) {
                Button { showDrawer = true } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle())
                .accessibilityIdentifier("composer.plusButton")

                pill
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onChange(of: promptText) { _, _ in recomputeSlashCandidates() }
        .onChange(of: availableCommands) { _, _ in recomputeSlashCandidates() }
        .onChange(of: voiceRecorder.state) { _, newState in
            if newState == .done {
                let text = voiceRecorder.transcribedText ?? ""
                if !text.isEmpty {
                    promptText = text
                }
                voiceRecorder.reset()
            }
        }
        .sheet(isPresented: $showDrawer) {
            AttachmentDrawerSheet(
                attachments: $attachments,
                selectedModelId: $selectedModelId,
                runtime: runtime
            )
            .presentationDetents([.fraction(0.4), .medium])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var pill: some View {
        HStack(spacing: 6) {
            Group {
                switch inputMode {
                case .textField:
                    TextField("Send a message…", text: $promptText, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .submitLabel(.return)
                        .accessibilityIdentifier("composer.textField")
                case .waveform:
                    RecordingWaveform(level: voiceRecorder.audioLevel)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 14)
            .padding(.vertical, 8)

            rightButtonView
                .padding(.trailing, 6)
        }
        .liquidGlass(in: Capsule())
    }

    @ViewBuilder
    private var rightButtonView: some View {
        switch rightButton {
        case .stop:
            Button {
                onCancelTask()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.stopButton")

        case .stopRecording:
            Button {
                voiceRecorder.stopRecording()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.stopRecordingButton")

        case .send:
            Button {
                onSend()
                hasPendingSlashCommand = false
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hasPendingSlashCommand ? Color.white : Color.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(SendButtonGlassModifier(emphasized: hasPendingSlashCommand))
            .accessibilityIdentifier("composer.sendButton")

        case .mic:
            Button {
                voiceRecorder.startRecording()
            } label: {
                Image(systemName: "mic")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.micButton")
        }
    }

    private func recomputeSlashCandidates() {
        if let prefix = slashPrefix {
            let lower = prefix.lowercased()
            slashCandidates = Array(
                availableCommands
                    .filter { $0.name.lowercased().hasPrefix(lower) }
                    .prefix(5)
            )
        } else {
            slashCandidates = []
        }
        hasPendingSlashCommand = matchesKnownCommand
    }
}

private struct SendButtonGlassModifier: ViewModifier {
    let emphasized: Bool
    func body(content: Content) -> some View {
        if emphasized {
            content.liquidGlass(in: Circle(), tint: .accentColor)
        } else {
            content.liquidGlass(in: Circle())
        }
    }
}
```

- [ ] **Step 2: Verify the package builds**

Run:
```bash
cd ios/Packages/AMUXUI && swift build
```

Expected: build succeeds (or skipped per Task 3 caveat — Task 9 will catch breakage).

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SessionComposer.swift
git commit -m "feat(ios): SessionComposer iMessage-style inline composer"
```

---

## Task 6: Camera + Photos permissions

**Files:**
- Modify: `ios/AMUXApp/Info.plist`

Existing entries: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`. Add camera + photo library entries so the new drawer can open them without crashing.

- [ ] **Step 1: Add the two keys**

Edit `ios/AMUXApp/Info.plist`. Insert immediately after the existing `NSSpeechRecognitionUsageDescription` block (before `SUPABASE_PUBLISHABLE_KEY`):

```xml
    <key>NSCameraUsageDescription</key>
    <string>AMUX uses the camera to attach photos to prompts you send to your AI agent.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>AMUX accesses your photo library to attach images to prompts you send to your AI agent.</string>
```

- [ ] **Step 2: Commit**

```bash
git add ios/AMUXApp/Info.plist
git commit -m "feat(ios): add camera + photo library usage descriptions"
```

---

## Task 7: Refactor RuntimeDetailView

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RuntimeDetailView.swift`

This is the biggest task — it deletes a large amount of code and rewires the view. Done as a single edit since the changes are interdependent (top toolbar / bottom inset / removed sheets / removed inits all touch the same struct).

- [ ] **Step 1: Replace the entire RuntimeDetailView.swift file**

Overwrite `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RuntimeDetailView.swift` with the new contents:

```swift
import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

// MARK: - RuntimeDetailView (iMessage-style chat detail)

public struct RuntimeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: RuntimeDetailViewModel
    @State private var promptText = ""
    @State private var selectedModelId: String?
    @State private var attachments: [URL] = []
    @State private var showSettings = false
    @State private var showMembers = false
    @State private var collaborators: [CachedActor] = []
    @State private var voiceRecorder = VoiceRecorder(contextualStrings: [
        "Claude", "Claude Code", "Sonnet", "Opus", "Haiku",
        "MQTT", "protobuf", "SwiftUI", "SwiftData",
        "agent", "daemon", "worktree", "workspace",
        "commit", "push", "merge", "pull request",
        "API", "JSON", "YAML", "REST", "gRPC",
    ])

    let connectedAgentsStore: ConnectedAgentsStore?

    public init(runtime: Runtime, mqtt: MQTTService, peerId: String,
                connectedAgentsStore: ConnectedAgentsStore? = nil) {
        _viewModel = State(initialValue: RuntimeDetailViewModel(
            runtime: runtime, mqtt: mqtt, peerId: peerId,
            connectedAgentsStore: connectedAgentsStore))
        self.connectedAgentsStore = connectedAgentsStore
    }

    public init(session: Session, mqtt: MQTTService, peerId: String,
                teamclawService: TeamclawService?,
                connectedAgentsStore: ConnectedAgentsStore? = nil) {
        _viewModel = State(initialValue: RuntimeDetailViewModel(
            runtime: nil, mqtt: mqtt, teamID: session.teamId,
            peerId: peerId, session: session,
            teamclawService: teamclawService,
            connectedAgentsStore: connectedAgentsStore))
        self.connectedAgentsStore = connectedAgentsStore
    }

    private var agentLogoName: String {
        switch viewModel.runtime?.agentType {
        case 1: "ClaudeLogo"
        case 2: "OpenCodeLogo"
        case 3: "CodexLogo"
        default: "ClaudeLogo"
        }
    }

    private var memberBadgeCount: Int {
        let collab = viewModel.participantCount
        return collab > 0 ? collab : collaborators.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isDaemonOnline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").font(.caption)
                    Text("Daemon offline").font(.caption).fontWeight(.medium)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .liquidGlass(in: Capsule(), tint: .orange, interactive: false)
                .padding(.vertical, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.events.isEmpty && !viewModel.isStreaming {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.quaternary)
                                Text("No messages yet")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        }

                        ForEach(viewModel.groupedEvents) { item in
                            switch item {
                            case .single(let event):
                                EventBubbleView(
                                    event: event,
                                    runtime: viewModel.runtime,
                                    onGrant: { id in Task { try? await viewModel.grantPermission(requestId: id) } },
                                    onDeny: { id in Task { try? await viewModel.denyPermission(requestId: id) } }
                                ).id(event.id)
                            case .toolRun(let id, let events):
                                ToolRunSummaryBar(events: events)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 2)
                                    .id(id)
                            }
                        }

                        if viewModel.isStreaming {
                            StreamingTextView(content: viewModel.streamingText)
                                .id("streaming")
                        }

                        if viewModel.isActive {
                            TypingIndicatorView()
                                .id("typing")
                        }

                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.top, 8)
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: viewModel.events.count) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: viewModel.streamingText) {
                    if viewModel.isStreaming {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle(viewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showMembers = true } label: {
                    Image(systemName: "person.2")
                        .font(.title3)
                        .overlay(alignment: .topTrailing) {
                            if memberBadgeCount > 0 {
                                Text("\(memberBadgeCount)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue, in: Capsule())
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
                .accessibilityIdentifier("runtime.membersButton")

                if viewModel.hasRuntime {
                    Button { showSettings = true } label: {
                        Image(agentLogoName, bundle: .module)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityIdentifier("runtime.agentSettingsButton")
                }
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            SessionComposer(
                promptText: $promptText,
                selectedModelId: $selectedModelId,
                attachments: $attachments,
                voiceRecorder: voiceRecorder,
                runtime: viewModel.runtime,
                isAgentActive: viewModel.isActive,
                availableCommands: viewModel.availableCommands,
                onSend: {
                    let text = promptText
                    let modelId = resolvedModelId
                    promptText = ""
                    attachments = []
                    Task {
                        try? await viewModel.sendPrompt(text, modelId: modelId, modelContext: modelContext)
                    }
                },
                onCancelTask: {
                    Task { try? await viewModel.cancelTask() }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            if let runtime = viewModel.runtime {
                RuntimeSettingsSheet(
                    runtime: runtime,
                    onSync: { Task { try? await viewModel.requestIncrementalSync(modelContext: modelContext) } },
                    isSyncing: viewModel.isSyncing
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showMembers) {
            let accessible: Set<String> = {
                var s = Set(connectedAgentsStore?.agents.map(\.id) ?? [])
                if let current = viewModel.runtime?.runtimeId { s.insert(current) }
                return s
            }()
            MemberListView(
                selected: Set(collaborators.map(\.actorId)),
                accessibleAgentIDs: accessible,
                currentPrimaryAgentID: viewModel.runtime?.runtimeId
            ) { selected in
                collaborators = selected
                if !selected.isEmpty {
                    forkToCollab(members: selected)
                }
            }
            .task { await connectedAgentsStore?.reload() }
        }
        .task { viewModel.start(modelContext: modelContext) }
        .onDisappear { viewModel.stop() }
    }

    private var resolvedModelId: String? {
        if let selectedModelId, !selectedModelId.isEmpty { return selectedModelId }
        if let current = viewModel.runtime?.currentModel, !current.isEmpty { return current }
        return nil
    }

    private func forkToCollab(members: [CachedActor]) {
        guard let runtime = viewModel.runtime else { return }
        let daemonDeviceId = viewModel.daemonDeviceIdRef
        guard !daemonDeviceId.isEmpty else { return }
        let summary = runtime.lastOutputSummary.isEmpty
            ? "Forked from agent session: \(runtime.sessionTitle.isEmpty ? runtime.runtimeId : runtime.sessionTitle)"
            : runtime.lastOutputSummary

        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = viewModel.session?.teamId ?? ""
        createReq.title = runtime.sessionTitle.isEmpty
            ? "Collab: \(runtime.worktree.split(separator: "/").last.map(String.init) ?? runtime.runtimeId)"
            : "Collab: \(runtime.sessionTitle)"
        createReq.summary = summary
        createReq.inviteActorIds = members.map(\.actorId)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = daemonDeviceId
        rpcReq.method = .createSession(createReq)

        let topic = MQTTTopics.deviceRpcRequest(
            teamID: viewModel.session?.teamId ?? "",
            deviceID: daemonDeviceId
        )
        Task {
            if let data = try? rpcReq.serializedData() {
                try? await viewModel.mqttRef.publish(topic: topic, payload: data, retain: false)
            }
        }
    }

    // MARK: - RuntimeSettingsSheet

    private struct RuntimeSettingsSheet: View {
        let runtime: Runtime
        let onSync: () -> Void
        var isSyncing: Bool
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    Section("Agent") {
                        LabeledContent("ID", value: runtime.runtimeId)
                        LabeledContent("Type", value: runtime.agentTypeLabel)
                        HStack { Text("Status"); Spacer(); StatusBadge(status: runtime.status) }
                        LabeledContent("Worktree", value: runtime.worktree)
                    }
                    if !runtime.branch.isEmpty {
                        Section("Git") {
                            LabeledContent("Branch", value: runtime.branch)
                        }
                    }
                    Section {
                        Button {
                            onSync()
                        } label: {
                            HStack {
                                Label("Sync History", systemImage: "arrow.clockwise")
                                Spacer()
                                if isSyncing {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isSyncing)
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
```

Note what is removed compared to the original:
- `import UniformTypeIdentifiers` — no longer needed; the file importer is now in `AttachmentDrawerSheet`
- `allAgentIds: [String]`, `@Binding var navigationPath: [String]`, `currentIndex`, `canGoUp`, `canGoDown`, `goUp()`, `goDown()` — prev/next nav deleted
- `showReplySheet`, `ReplySheet` definition — replaced inline
- `RecordButton` definition — superseded by `SessionComposer`'s right-button branch
- The transcribed-voice review bubble (with Edit/Send buttons) — voice → text directly via `onChange(of: voiceRecorder.state)` inside `SessionComposer`
- The three glass-capsule bottom toolbar — replaced by `SessionComposer`
- `SendButtonGlassModifier` — moved into `SessionComposer.swift`

- [ ] **Step 2: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RuntimeDetailView.swift
git commit -m "refactor(ios): RuntimeDetailView — iMessage-style toolbar + composer"
```

---

## Task 8: Update RuntimeDetailView callers

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Root/SessionsTab.swift` (3 call sites)
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Root/IdeasTab.swift` (2 call sites)

Drop the removed `allAgentIds:` and `navigationPath:` parameters from every `RuntimeDetailView(...)` invocation. Also remove any now-unused `allAgentIds` local computations and `navigationPath` props that were threaded only to feed those parameters — but only if they are unused after removal; some callers also pass `navigationPath` to other views.

- [ ] **Step 1: Update SessionsTab.swift**

Find and replace each `RuntimeDetailView(...)` invocation in `SessionsTab.swift`.

Replace the block at lines ~166-173 (session-only call):

```swift
                RuntimeDetailView(
                    session: session,
                    mqtt: mqtt,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    teamclawService: nil,
                    navigationPath: $navigationPath,
                    connectedAgentsStore: connectedAgentsStore
                )
```

with:

```swift
                RuntimeDetailView(
                    session: session,
                    mqtt: mqtt,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    teamclawService: nil,
                    connectedAgentsStore: connectedAgentsStore
                )
```

Replace the block at lines ~176-183 (runtime call):

```swift
                RuntimeDetailView(
                    runtime: runtime,
                    mqtt: mqtt,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    allAgentIds: allAgentIds,
                    navigationPath: $navigationPath,
                    connectedAgentsStore: connectedAgentsStore
                )
```

with:

```swift
                RuntimeDetailView(
                    runtime: runtime,
                    mqtt: mqtt,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    connectedAgentsStore: connectedAgentsStore
                )
```

Replace the block at lines ~240-244 (collab destination, session call):

```swift
                    RuntimeDetailView(session: session, mqtt: mqtt,
                                      peerId: "ios-\(pairing.authToken.prefix(6))",
                                      teamclawService: teamclawService,
                                      navigationPath: $navigationPath,
                                      connectedAgentsStore: connectedAgentsStore)
```

with:

```swift
                    RuntimeDetailView(session: session, mqtt: mqtt,
                                      peerId: "ios-\(pairing.authToken.prefix(6))",
                                      teamclawService: teamclawService,
                                      connectedAgentsStore: connectedAgentsStore)
```

After the edits, search the file for `allAgentIds`. If any computed property or local variable now has zero references (dead code), delete it. Keep `navigationPath` — other call sites in this file may still need it for routing into the destination view itself.

- [ ] **Step 2: Update IdeasTab.swift**

Find and replace each `RuntimeDetailView(...)` invocation in `IdeasTab.swift`.

Replace the session call (~lines 77-84):

```swift
                                RuntimeDetailView(
                                    session: session,
                                    mqtt: mqtt,
                                    peerId: "ios-\(pairing.authToken.prefix(6))",
                                    teamclawService: teamclawService,
                                    navigationPath: $navigationPath,
                                    connectedAgentsStore: connectedAgentsStore
                                )
```

with:

```swift
                                RuntimeDetailView(
                                    session: session,
                                    mqtt: mqtt,
                                    peerId: "ios-\(pairing.authToken.prefix(6))",
                                    teamclawService: teamclawService,
                                    connectedAgentsStore: connectedAgentsStore
                                )
```

Replace the runtime call (~lines 90-97):

```swift
                        RuntimeDetailView(
                            runtime: runtime,
                            mqtt: mqtt,
                            peerId: "ios-\(pairing.authToken.prefix(6))",
                            allAgentIds: sessionViewModel.runtimes.map(\.runtimeId),
                            navigationPath: $navigationPath,
                            connectedAgentsStore: connectedAgentsStore
                        )
```

with:

```swift
                        RuntimeDetailView(
                            runtime: runtime,
                            mqtt: mqtt,
                            peerId: "ios-\(pairing.authToken.prefix(6))",
                            connectedAgentsStore: connectedAgentsStore
                        )
```

- [ ] **Step 3: Verify build**

Run from repo root:
```bash
xcodebuild -project ios/AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -40
```

Expected: `BUILD SUCCEEDED`. If a callers-file still references the removed parameters, fix them and re-run.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/Root/SessionsTab.swift ios/Packages/AMUXUI/Sources/AMUXUI/Root/IdeasTab.swift
git commit -m "refactor(ios): drop allAgentIds/navigationPath from RuntimeDetailView callers"
```

---

## Task 9: Build verification + manual smoke test

**Files:** None modified (verification only).

The unit test (`ComposerStateTests`) already covers the state machine. SwiftUI assembly + UIKit bridging + sheet presentation can only really be verified by running the app.

- [ ] **Step 1: Run all unit tests**

Run from repo root:
```bash
cd ios/Packages/AMUXUI && swift test 2>&1 | tail -20
cd ../AMUXCore && swift test 2>&1 | tail -20
```

Expected: existing tests still pass. `ComposerStateTests` passes.

- [ ] **Step 2: Build the iOS app**

Run from repo root:
```bash
xcodebuild -project ios/AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Boot simulator and smoke-test the new composer**

Manually verify in iPhone 16 simulator (boot via Xcode, install built app):

Top toolbar:
- Open any agent's session detail screen.
- Trailing toolbar shows: members (`person.2`) on the left of the trailing group, agent logo on the right.
- Tap members → `MemberListView` sheet appears.
- Tap agent logo → `RuntimeSettingsSheet` appears with id/type/status/worktree.
- Sessions without a runtime (collab-only) show only the members button.
- Members badge count appears when collaborators > 0.

Bottom composer:
- With empty input: pill shows "Send a message…" placeholder. Right side shows mic icon.
- Type some text. Right side becomes ↑ send button.
- Tap return on the keyboard. A newline is inserted (text does NOT send).
- Tap send. Message is sent (or attempted). Input clears.
- Type `/`. Slash command popup appears above the composer when there are matching commands.
- Tap a slash command in the popup. Text becomes `/cmdname `. Send button glass tint emphasizes (accent color).
- Empty the input. Tap mic → input pill content swaps to a red `RecordingWaveform`. Right side shows red `mic.fill`.
- Tap red mic.fill → recording stops. Once `voiceRecorder.state == .done`, transcribed text is written into the input field; right side becomes the ↑ send button.
- Tap `+`. AttachmentDrawerSheet slides up at 40% detent. Sections "Attach" and "Model" appear. Files / Camera / Photos cells. Model section lists `runtime.availableModels` with current model checked. Tap a model → checkmark moves; closing drawer keeps selection.
- Add an attachment via Files or Photos. Chip appears above composer with the file name. The "attachments coming soon" hint is visible. Send → input + chip both clear.
- Start an agent task. While it is streaming/running, the right-side button becomes red `stop.fill`. Tapping it cancels.
- During a running task, the `+` button is still tappable.

If any verification fails, return to the relevant task and fix.

- [ ] **Step 4: Manual smoke pass complete**

No code change, no commit — this step is just acknowledging the manual test passed.

---

## Self-Review Notes

Spec coverage check:

- Spec §"Top toolbar": Task 7 (toolbar block in body) + Task 8 (caller cleanup) ✓
- Spec §"Bottom composer (single row)": Task 5 (SessionComposer.swift) + Task 7 (safeAreaInset wiring) ✓
- Spec §"Right-side state-aware button": Task 1 (state machine) + Task 5 (rightButtonView) ✓
- Spec §"Keyboard behaviour" (return = newline): Task 5 — `axis: .vertical` TextField, no `.onSubmit` binding, `submitLabel(.return)` ✓
- Spec §"Slash commands": Task 5 — `recomputeSlashCandidates`, `SlashCommandsPopup`, `SendButtonGlassModifier` migrated ✓
- Spec §"Voice recording": Task 5 — `onChange(of: voiceRecorder.state)` writes transcript into `promptText`, resets recorder; `RecordingWaveform` overlay ✓
- Spec §"Attachment drawer": Task 4 (AttachmentDrawerSheet) + Task 3 (CameraImagePicker) + Task 6 (Info.plist permissions) ✓
- Spec §"Attachment transport — out of scope": Task 5 — chip row + "attachments coming soon" hint, no model id payload change ✓
- Spec §"File Structure": Tasks 1–7 create/modify each listed file ✓
- Spec §"Risks / Open Questions" — `hasRuntime == false` only shows members button + composer with no model picker: Task 7 — agent settings button is gated on `viewModel.hasRuntime`; Task 4 — model section gated on `runtime.availableModels` non-empty ✓

Type / name consistency check:

- `ComposerRightButton` cases (.stop, .stopRecording, .send, .mic) used identically in Task 1 (state machine), Task 1 (tests), Task 5 (rightButtonView switch) ✓
- `ComposerInputMode` (.textField, .waveform) consistent across Task 1 + Task 5 ✓
- `VoiceRecorder.State` cases (`.idle`, `.recording`, `.done`, `.denied`, `.error(String)`) match real source in `AMUXCore/Voice/VoiceRecorder.swift` ✓
- `RuntimeDetailView` two `init` signatures consistent across Task 7 (definition) and Task 8 (call sites). The Task 8 deletions match exactly the parameters the Task 7 inits no longer accept (`allAgentIds:`, `navigationPath:`) ✓
- `SessionComposer` parameter list (in Task 5 view definition) matches the call site in Task 7 (`promptText`, `selectedModelId`, `attachments`, `voiceRecorder`, `runtime`, `isAgentActive`, `availableCommands`, `onSend`, `onCancelTask`) ✓
- `AttachmentDrawerSheet` parameter list (`attachments`, `selectedModelId`, `runtime`) matches its call site in Task 5 ✓
- `CameraImagePicker(onCapture:onCancel:)` matches its call in Task 4 ✓
- `viewModel.sendPrompt(_, modelId:, modelContext:)` signature in Task 7 matches the existing `RuntimeDetailViewModel` API used by the original `ReplySheet` (verified in `RuntimeDetailView.swift:290-293` of original) ✓

No placeholders remain.
