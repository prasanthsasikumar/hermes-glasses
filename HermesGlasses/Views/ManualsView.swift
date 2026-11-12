//
// ManualsView.swift
//
// Machine manuals: import a PDF per machine, say what the machine looks
// like, and switch the guide on. The guide itself has no screen - it is
// heard through the glasses - so this page is setup and status only.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ManualsView: View {
    @Bindable var vm: MachineGuideViewModel
    let hermesVM: HermesSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var editing: MachineManual?

    private var guideRunning: Bool {
        vm.isActive && hermesVM.connectionState != .disconnected
    }

    var body: some View {
        NavigationStack {
            HermesScrollPage {
                guideSection
                manualsSection
                settingsSection
            }
            .navigationTitle("Manuals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
                guard case .success(let url) = result else { return }
                Task { if let manual = await vm.importDocument(at: url) { editing = manual } }
            }
            .sheet(item: $editing) { manual in ManualDetailView(vm: vm, manual: manual) }
            .alert("Manuals", isPresented: Binding(get: { vm.errorMessage != nil },
                                                   set: { if !$0 { vm.errorMessage = nil } })) {
                Button("OK") { vm.errorMessage = nil }
            } message: { Text(vm.errorMessage ?? "") }
        }
    }

    private var guideSection: some View {
        VStack(spacing: 12) {
            HermesSection(header: "Machine guide",
                          footer: "Look at a machine and ask - \"help me assemble this\". The glasses take a photo, pick the matching manual and answer out loud. Works on glasses with no display.") {
                if guideRunning {
                    HermesRow(vm.activeManual?.displayName ?? "Waiting for a machine",
                              icon: vm.activeManual == nil ? "viewfinder" : "wrench.and.screwdriver",
                              subtitle: vm.activeManual == nil
                                  ? "Identifies it on your next question"
                                  : (vm.working ? "Answering…" : "Answering from this manual"),
                              showsChevron: false)
                } else {
                    HermesRow("Guide is off", icon: "wrench.and.screwdriver", mutedIcon: true,
                              subtitle: vm.manuals.isEmpty ? "Import a manual to begin" : "Start it here, or by voice",
                              showsChevron: false)
                }
            }
            if guideRunning {
                HermesDestructiveButton(title: "End guide") { vm.end() }
                    .padding(.horizontal, 16)
            } else {
                HermesPrimaryButton(title: "Start guide", systemImage: "play.fill",
                                    enabled: !vm.manuals.isEmpty) {
                    Task { await vm.start() }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var manualsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HermesSection(header: "Machines",
                          footer: "Manuals stay on this iPhone. When you ask, the photo and the relevant manual text go to \(DirectClient.provider.displayName), your AI provider.") {
                ForEach(vm.manuals) { manual in
                    Button { editing = manual } label: {
                        HermesRow(manual.displayName, icon: "doc.text",
                                  subtitle: subtitle(for: manual))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Use for the guide now") { Task { await vm.start(with: manual) } }
                        Button("Delete", role: .destructive) { vm.delete(manual) }
                    }
                    HermesDivider()
                }
                Button { showImporter = true } label: {
                    HermesRow("Import a manual", icon: "doc.badge.plus", subtitle: "PDF, text or Markdown - one per machine")
                }
                .buttonStyle(.plain)
                .disabled(vm.importing)
            }
            if vm.importing {
                HStack { ProgressView(); Text("Reading the manual…").foregroundStyle(.secondary) }
                    .padding(.horizontal, 32)
            }
        }
    }

    private var settingsSection: some View {
        HermesSection(header: "Voice",
                      footer: "Off = the guide starts from this screen only. \"What can I say?\" in Settings lists every phrase.") {
            HermesRow(title: "Start by voice", subtitle: "\"Help me assemble this\", \"which machine is this\"",
                      showsChevron: false) {
                Toggle("", isOn: $vm.voiceStartEnabled).labelsHidden().tint(HermesTheme.accent)
            }
        }
    }

    private func subtitle(for manual: MachineManual) -> String {
        var parts = ["\(manual.pageCount) page\(manual.pageCount == 1 ? "" : "s")"]
        if manual.referencePhotoFilenames.isEmpty && manual.profile.isEmpty {
            parts.append("no picture or description - hard to recognise")
        } else if manual.referencePhotoFilenames.isEmpty {
            parts.append("no picture")
        }
        return parts.joined(separator: " · ")
    }
}

/// One machine: its name (what the engineer says), what it looks like, and
/// reference pictures. Edits are saved on Done.
struct ManualDetailView: View {
    let vm: MachineGuideViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var manual: MachineManual
    @State private var pickerItem: PhotosPickerItem?
    @State private var capturing = false
    /// Photos added in this sheet; removed again if the sheet is cancelled.
    @State private var addedPhotos: [String] = []
    /// Photos removed in this sheet; deleted from disk only on Done.
    @State private var removedPhotos: [String] = []

    init(vm: MachineGuideViewModel, manual: MachineManual) {
        self.vm = vm
        _manual = State(initialValue: manual)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Machine name", text: $manual.name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("What your engineers call it. They can say \"this is \(manual.displayName)\" if the camera can't tell.")
                }

                Section {
                    TextEditor(text: $manual.profile).frame(minHeight: 110)
                } header: {
                    Text("What it looks like")
                } footer: {
                    Text("Used to recognise the machine: model number on the nameplate, colour, shape, distinctive parts.")
                }

                Section {
                    if !manual.referencePhotoFilenames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(manual.referencePhotoFilenames, id: \.self) { file in
                                    photoTile(file)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if manual.referencePhotoFilenames.count < MachineManual.maxReferencePhotos {
                        Button {
                            capture()
                        } label: {
                            Label(capturing ? "Taking a photo…" : "Take a photo of the machine", systemImage: "camera")
                        }
                        .disabled(capturing)
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Choose from the photo library", systemImage: "photo")
                        }
                    }
                } header: {
                    Text("Pictures")
                } footer: {
                    Text("The first picture is the one compared with what the glasses see - tap another to make it first. A photo of the real machine beats the manual's cover page.")
                }

                Section {
                    LabeledContent("Pages", value: "\(manual.pageCount)")
                    LabeledContent("Text", value: "\(manual.characterCount.formatted()) characters")
                    if manual.characterCount > ManualExcerpt.defaultBudget {
                        Text("This manual is long, so each question is answered from its most relevant pages rather than the whole document.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Use for the guide now") {
                        commit()
                        let chosen = manual
                        dismiss()
                        Task { await vm.start(with: chosen) }
                    }
                    Button("Delete manual", role: .destructive) {
                        vm.delete(manual)
                        dismiss()
                    }
                }
            }
            .hermesFormStyle()
            .tint(HermesTheme.accent)
            .navigationTitle("Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        addedPhotos.forEach(vm.store.removePhoto)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); dismiss() }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        add(image)
                    }
                    pickerItem = nil
                }
            }
        }
        // Cancel and Done are the exits; a stray swipe must not drop edits
        // or strand photos already written to disk.
        .interactiveDismissDisabled()
    }

    private func photoTile(_ file: String) -> some View {
        let isFirst = manual.referencePhotoFilenames.first == file
        return ZStack(alignment: .topTrailing) {
            Group {
                if let image = vm.referenceImage(file) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    HermesTheme.mediaPlaceholder
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFirst ? HermesTheme.accent : .clear, lineWidth: 3)
            )
            .onTapGesture {
                manual.referencePhotoFilenames.removeAll { $0 == file }
                manual.referencePhotoFilenames.insert(file, at: 0)
            }
            Button {
                manual.referencePhotoFilenames.removeAll { $0 == file }
                removedPhotos.append(file)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Remove picture")
        }
    }

    private func capture() {
        capturing = true
        Task {
            if let image = await vm.captureReferenceFromCamera() { add(image) }
            capturing = false
        }
    }

    private func add(_ image: UIImage) {
        guard manual.referencePhotoFilenames.count < MachineManual.maxReferencePhotos,
              let name = vm.storeReferencePhoto(image) else { return }
        manual.referencePhotoFilenames.append(name)
        addedPhotos.append(name)
    }

    private func commit() {
        removedPhotos.forEach(vm.store.removePhoto)
        vm.save(manual)
    }
}
