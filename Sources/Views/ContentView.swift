import SwiftUI
import UIKit

struct ContentView: View {
    private let health = HealthKitManager.shared

    var body: some View {
        NavigationStack {
            Form {
                authorizationSection
                if health.isAvailable {
                    dataTypesSection
                }
            }
            .navigationTitle("Health Sync")
            .task { await health.refreshRequestStatus() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var authorizationSection: some View {
        Section {
            switch health.authState {
            case .unavailable:
                Label("HealthKit isn't available on this device.", systemImage: "xmark.octagon")
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                authorizeButton(title: "Try Again")

            case .requesting:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for Health…")
                }

            case .notDetermined:
                Text("This app reads heart rate, steps, active energy, blood oxygen, HRV, and workouts.")
                    .foregroundStyle(.secondary)
                authorizeButton(title: "Allow Health Access")

            case .requested:
                Label("Health access has been requested.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                authorizeButton(title: "Review Health Access")
            }
        } header: {
            Text("Health Access")
        } footer: {
            if case .requested = health.authState {
                Text("Tapping again won't re-show the sheet once every type has been decided. Use the Health app to change your choices.")
            }
        }
    }

    private var dataTypesSection: some View {
        Section {
            ForEach(HealthMetric.allCases) { metric in
                HStack {
                    Label(metric.displayName, systemImage: metric.symbolName)
                    Spacer()
                    statusIcon(for: metric)
                }
            }

            Button {
                Task { await health.probeReadAccess() }
            } label: {
                if health.isProbing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking…")
                    }
                } else {
                    Text("Check for readable data")
                }
            }
            .disabled(health.isProbing)

            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings → Health", destination: url)
            }
        } header: {
            Text("Data Types")
        } footer: {
            Text("A green check means at least one sample of that type is visible to this app. HealthKit never reports read permission directly, so an empty row means either access was denied or you have no samples of that type yet.")
        }
    }

    // MARK: - Pieces

    private func authorizeButton(title: String) -> some View {
        Button {
            Task { await health.requestAuthorization() }
        } label: {
            Label(title, systemImage: "heart.text.square")
        }
    }

    @ViewBuilder
    private func statusIcon(for metric: HealthMetric) -> some View {
        if health.lastProbeDate == nil {
            Text("—").foregroundStyle(.tertiary)
        } else if health.metricsWithData.contains(metric) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
