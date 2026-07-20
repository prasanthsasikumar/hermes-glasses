//
// PeopleView.swift
//
// End-of-day review of the people met: photo + spoken note, grouped by
// day. Reads straight through the view model to EncounterStore and
// re-reads whenever `encounterRevision` changes.
//

import SwiftUI

struct PeopleView: View {
    let hermesVM: HermesSessionViewModel

    @Environment(\.dismiss) private var dismiss

    private var days: [(label: String, encounters: [Encounter])] {
        let all = hermesVM.allEncounters()  // newest first
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [Encounter]] = [:]
        for encounter in all {
            let day = calendar.startOfDay(for: encounter.timestamp)
            if groups[day] == nil {
                groups[day] = []
                order.append(day)
            }
            groups[day]?.append(encounter)
        }
        return order.map { (label: Self.dayLabel($0), encounters: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(days, id: \.label) { day in
                            Section(day.label) {
                                ForEach(day.encounters) { encounter in
                                    NavigationLink {
                                        EncounterDetailView(
                                            hermesVM: hermesVM, encounter: encounter
                                        )
                                    } label: {
                                        EncounterRow(hermesVM: hermesVM, encounter: encounter)
                                    }
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        hermesVM.deleteEncounter(id: day.encounters[index].id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Re-read the store after a save/edit/delete.
            .id(hermesVM.encounterRevision)
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(HermesTheme.accent)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No one yet")
                .font(.headline)
            Text("Say \"remember this person\" while wearing the glasses. Hermes takes a photo and saves the note you speak next.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct EncounterRow: View {
    let hermesVM: HermesSessionViewModel
    let encounter: Encounter

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(encounter.note.isEmpty ? "No note" : encounter.note)
                    .font(.subheadline)
                    .foregroundStyle(encounter.note.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                Text(encounter.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = hermesVM.encounterPhoto(encounter),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(HermesTheme.chipFill)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct EncounterDetailView: View {
    let hermesVM: HermesSessionViewModel
    let encounter: Encounter

    @State private var note: String = ""
    @Environment(\.dismiss) private var dismiss

    /// All photos on the entry - one for a classic capture, several for a
    /// recorded conversation.
    private var photos: [UIImage] {
        hermesVM.encounterPhotos(encounter).compactMap(UIImage.init(data:))
    }

    var body: some View {
        Form {
            let photos = self.photos
            if photos.count == 1, let image = photos.first {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .listRowInsets(EdgeInsets())
            } else if photos.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 180, height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Note") {
                TextField("Name, where you met, follow-up…", text: $note, axis: .vertical)
                    .lineLimit(3...10)
            }

            Section {
                LabeledContent(
                    "Met",
                    value: encounter.timestamp.formatted(
                        date: .abbreviated, time: .shortened
                    )
                )
            }

            Section {
                Button("Delete", role: .destructive) {
                    hermesVM.deleteEncounter(id: encounter.id)
                    dismiss()
                }
            }
        }
        .navigationTitle("Person")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { note = encounter.note }
        .onDisappear {
            // Swipe-back must not discard an edit (same contract as Settings).
            if note != encounter.note {
                hermesVM.updateEncounterNote(id: encounter.id, note: note)
            }
        }
    }
}
