import SwiftUI
import UIKit

struct ContentView: View {
    private let health = HealthKitManager.shared
    private let supabase = SupabaseService.shared
    private let engine = HealthSyncEngine.shared
    private let background = BackgroundSyncCoordinator.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var pendingWindow: HistoryWindow?

    var body: some View {
        NavigationStack {
            Form {
                if supabase.isRestoring {
                    Section { HStack(spacing: 12) { ProgressView(); Text("Restoring session…") } }
                } else if supabase.isSignedIn {
                    accountSection
                    healthAccessSection
                    dashboardSection
                    syncSection
                    historySection
                    backgroundSection
                    dataTypesSection
                } else {
                    signInSection
                }
            }
            .navigationTitle("Health Sync")
            .task {
                await supabase.restore()
                await health.refreshRequestStatus()
            }
        }
    }

    // MARK: - Sign in

    private var signInSection: some View {
        Section {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Password", text: $password)
                .textContentType(.password)

            Button {
                Task {
                    isSigningIn = true
                    await supabase.signIn(email: email, password: password)
                    isSigningIn = false
                    if supabase.isSignedIn { password = "" }
                }
            } label: {
                if isSigningIn {
                    HStack(spacing: 12) { ProgressView(); Text("Signing in…") }
                } else {
                    Text("Sign In")
                }
            }
            .disabled(isSigningIn || email.isEmpty || password.isEmpty)

            if let error = supabase.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Supabase")
        } footer: {
            Text("Sign in once — the session is stored in the Keychain and refreshed automatically, including when HealthKit wakes the app in the background.")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Signed in", value: supabase.email ?? "—")
            Button("Sign Out", role: .destructive) {
                Task { await supabase.signOut() }
            }
            .disabled(engine.isSyncing)
        }
    }

    // MARK: - Health access

    @ViewBuilder
    private var healthAccessSection: some View {
        Section("Health Access") {
            switch health.authState {
            case .unavailable:
                Label("HealthKit isn't available on this device.", systemImage: "xmark.octagon")
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                authorizeButton("Try Again")

            case .requesting:
                HStack(spacing: 12) { ProgressView(); Text("Waiting for Health…") }

            case .notDetermined:
                authorizeButton("Allow Health Access")

            case .requested:
                Label("Health access requested", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }

            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings → Health", destination: url)
            }
        }
    }

    private func authorizeButton(_ title: String) -> some View {
        Button {
            Task { await health.requestAuthorization() }
        } label: {
            Label(title, systemImage: "heart.text.square")
        }
    }

    // MARK: - Dashboard

    private var dashboardSection: some View {
        Section {
            NavigationLink {
                DashboardView()
            } label: {
                Label("View Dashboard", systemImage: "chart.xyaxis.line")
            }
        } footer: {
            Text("Charts are drawn from what reached Supabase, not from HealthKit \u{2014} so they double as a check that the sync worked.")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Button {
                Task { await engine.syncAll() }
            } label: {
                if engine.isSyncing {
                    HStack(spacing: 12) { ProgressView(); Text(syncingLabel) }
                } else {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(engine.isSyncing || !health.isAvailable)

            statusRow
        } header: {
            Text("Sync")
        } footer: {
            Text("The first sync reaches back 30 days. After that only samples HealthKit hasn't handed over yet are sent, tracked per type with an anchor.")
        }
    }

    private var syncingLabel: String {
        if case .syncing(let metric) = engine.status { return "Syncing \(metric.displayName)…" }
        return "Syncing…"
    }

    @ViewBuilder
    private var statusRow: some View {
        switch engine.status {
        case .idle:
            EmptyView()

        case .syncing:
            EmptyView()

        case .finished(let uploaded, let deleted, let at):
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    uploaded == 0 && deleted == 0
                        ? "Already up to date"
                        : "\(uploaded) uploaded\(deleted > 0 ? ", \(deleted) deleted" : "")",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                Text(at.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    // MARK: - History window

    private var historySection: some View {
        Section {
            Picker("Reach back", selection: windowBinding) {
                ForEach(HistoryWindow.allCases) { window in
                    Text(window.rawValue).tag(window)
                }
            }
            .disabled(engine.isSyncing)
        } header: {
            Text("History")
        } footer: {
            Text("How far back to pull from the Health app. Widening this clears the sync anchors so the next sync re-reads the whole window — already-uploaded samples update in place rather than duplicating. A year or more can mean hundreds of thousands of samples, so run it on Wi-Fi and leave the app open.")
        }
        .confirmationDialog(
            "Re-read \(pendingWindow?.rawValue ?? "") of history?",
            isPresented: Binding(get: { pendingWindow != nil }, set: { if !$0 { pendingWindow = nil } }),
            titleVisibility: .visible
        ) {
            Button("Re-read and Sync") {
                if let pendingWindow {
                    engine.setHistoryWindow(pendingWindow)
                    Task { await engine.syncAll() }
                }
                pendingWindow = nil
            }
            Button("Cancel", role: .cancel) { pendingWindow = nil }
        } message: {
            Text(pendingWindow?.isLarge == true
                 ? "This can take a while and use a lot of data."
                 : "The next sync will re-read this window.")
        }
    }

    private var windowBinding: Binding<HistoryWindow> {
        Binding(
            get: { pendingWindow ?? engine.historyWindow },
            set: { pendingWindow = ($0 == engine.historyWindow) ? nil : $0 }
        )
    }

    // MARK: - Automatic sync

    @ViewBuilder
    private var backgroundSection: some View {
        Section {
            if background.isEnabled {
                Label("Automatic sync is on", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Types watched", value: "\(background.enabledTypeCount)")
                LabeledContent(
                    "Last automatic sync",
                    value: background.lastBackgroundSync?
                        .formatted(.relative(presentation: .numeric)) ?? "Not yet"
                )
            } else {
                Button {
                    Task { await background.enableBackgroundDelivery() }
                } label: {
                    Label("Turn On Automatic Sync", systemImage: "bolt.badge.clock")
                }
                .disabled(!health.isAvailable)
            }

            if let error = background.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Automatic Sync")
        } footer: {
            Text("HealthKit wakes the app when new samples arrive — including overnight — so your data syncs without opening it. iOS decides the timing and batches updates to protect battery, so expect it hourly rather than instantly.")
        }
    }

    // MARK: - Per-type status

    private var dataTypesSection: some View {
        Section {
            ForEach(HealthMetric.allCases) { metric in
                HStack {
                    Label(metric.displayName, systemImage: metric.symbolName)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(lastSyncText(for: metric))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let count = engine.syncedCounts[metric] ?? 0
                        if count > 0 {
                            Text("\(count) sent")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } header: {
            Text("Last Synced")
        }
    }

    private func lastSyncText(for metric: HealthMetric) -> String {
        guard let date = engine.lastSyncDates[metric] else { return "Never" }
        return date.formatted(.relative(presentation: .numeric))
    }
}

#Preview {
    ContentView()
}
