//
// RegistrationView.swift
//
// Overlay view shown during Meta AI companion app registration flow.
// Appears as a sheet when the user is registering their glasses.
//

import MWDATCore
import SwiftUI

struct RegistrationView: View {
    let viewModel: WearablesViewModel

    var body: some View {
        Group {
            switch viewModel.registrationState {
            case .notRegistered, .unavailable:
                EmptyView()

            case .registering:
                RegistrationInProgressView(viewModel: viewModel)

            case .registered:
                EmptyView()
            }
        }
    }
}

// MARK: - Registration In Progress

struct RegistrationInProgressView: View {
    let viewModel: WearablesViewModel

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Connect Your Glasses")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Follow the prompts in the Meta AI app\nto register your Ray-Ban glasses.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ProgressView()
                    .scaleEffect(1.2)

                Text("Waiting for Meta AI...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Cancel") {
                    viewModel.disconnectGlasses()
                }
                .buttonStyle(.bordered)
                .padding(.top)
            }
            .padding()
        }
    }
}
