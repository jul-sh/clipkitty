import SwiftUI

public enum SettingsStorageLoadResult: Equatable, Sendable {
    case loaded(usedBytes: Int64)
    case failed(message: String)
}

public enum SettingsActionResult: Equatable, Sendable {
    case succeeded
    case failed(message: String)
}

private enum SettingsDatabaseOperation: Equatable {
    case idle
    case pruning(previousLimitGB: Double, requestedLimitGB: Double)
    case pruneFailed(
        previousLimitGB: Double,
        requestedLimitGB: Double,
        message: String
    )
    case clearing
    case clearFailed(message: String)
}

/// Shared storage, history, and About structure, with small slots for features
/// such as Sparkle updates and build attestation that exist on only one target.
public struct SettingsAdvancedSection<AdditionalContent: View, AboutAdditionalContent: View>: View {
    @Binding private var limitGB: Double
    private let loadUsedBytes: () async -> SettingsStorageLoadResult
    private let pruneToLimit: () async -> SettingsActionResult
    private let clearHistory: () async -> SettingsActionResult
    private let appVersion: String
    private let buildNumber: String
    private let additionalContent: () -> AdditionalContent
    private let aboutAdditionalContent: () -> AboutAdditionalContent

    @State private var isExpanded = false
    @State private var storageReloadRevision = 0
    @State private var databaseOperation = SettingsDatabaseOperation.idle

    public init(
        limitGB: Binding<Double>,
        loadUsedBytes: @escaping () async -> SettingsStorageLoadResult,
        pruneToLimit: @escaping () async -> SettingsActionResult,
        clearHistory: @escaping () async -> SettingsActionResult,
        appVersion: String,
        buildNumber: String,
        @ViewBuilder additionalContent: @escaping () -> AdditionalContent,
        @ViewBuilder aboutAdditionalContent: @escaping () -> AboutAdditionalContent
    ) {
        _limitGB = limitGB
        self.loadUsedBytes = loadUsedBytes
        self.pruneToLimit = pruneToLimit
        self.clearHistory = clearHistory
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.additionalContent = additionalContent
        self.aboutAdditionalContent = aboutAdditionalContent
    }

    public var body: some View {
        Section {
            DisclosureGroup(String(localized: "Advanced"), isExpanded: $isExpanded) {
                SettingsSubsectionHeader(title: String(localized: "Storage Limit"))
                SettingsStorageView(
                    limitGB: $limitGB,
                    reloadRevision: storageReloadRevision,
                    databaseOperation: databaseOperation,
                    loadUsedBytes: loadUsedBytes,
                    requestPrune: { previousLimitGB, requestedLimitGB in
                        Task {
                            await performPrune(
                                previousLimitGB: previousLimitGB,
                                requestedLimitGB: requestedLimitGB
                            )
                        }
                    },
                    retryFailedPrune: {
                        Task { await retryFailedPrune() }
                    },
                    cancelFailedPrune: cancelFailedPrune
                )

                Divider()
                SettingsSubsectionHeader(title: String(localized: "History"))
                SettingsHistoryView(
                    databaseOperation: databaseOperation,
                    requestClear: {
                        Task { await performClear() }
                    },
                    retryFailedClear: {
                        Task { await retryFailedClear() }
                    },
                    cancelFailedClear: cancelFailedClear
                )

                additionalContent()

                Divider()
                SettingsSubsectionHeader(title: String(localized: "About"))
                LabeledContent(String(localized: "Version"), value: appVersion)
                LabeledContent(String(localized: "Build"), value: buildNumber)
                aboutAdditionalContent()
            }
        }
    }

    private func performPrune(
        previousLimitGB: Double,
        requestedLimitGB: Double
    ) async {
        switch databaseOperation {
        case .idle:
            break
        case .pruning, .pruneFailed, .clearing, .clearFailed:
            return
        }

        await runPrune(
            previousLimitGB: previousLimitGB,
            requestedLimitGB: requestedLimitGB
        )
    }

    private func retryFailedPrune() async {
        guard case let .pruneFailed(previousLimitGB, requestedLimitGB, _) =
            databaseOperation
        else {
            return
        }

        await runPrune(
            previousLimitGB: previousLimitGB,
            requestedLimitGB: requestedLimitGB
        )
    }

    private func runPrune(
        previousLimitGB: Double,
        requestedLimitGB: Double
    ) async {
        limitGB = requestedLimitGB
        databaseOperation = .pruning(
            previousLimitGB: previousLimitGB,
            requestedLimitGB: requestedLimitGB
        )

        let result = await pruneToLimit()
        storageReloadRevision += 1
        switch result {
        case .succeeded:
            databaseOperation = .idle
        case let .failed(message):
            databaseOperation = .pruneFailed(
                previousLimitGB: previousLimitGB,
                requestedLimitGB: requestedLimitGB,
                message: message
            )
        }
    }

    private func cancelFailedPrune() {
        guard case let .pruneFailed(previousLimitGB, _, _) = databaseOperation else {
            return
        }
        limitGB = previousLimitGB
        databaseOperation = .idle
        storageReloadRevision += 1
    }

    private func performClear() async {
        switch databaseOperation {
        case .idle:
            break
        case .pruning, .pruneFailed, .clearing, .clearFailed:
            return
        }

        await runClear()
    }

    private func retryFailedClear() async {
        guard case .clearFailed = databaseOperation else { return }
        await runClear()
    }

    private func runClear() async {
        databaseOperation = .clearing
        let result = await clearHistory()
        storageReloadRevision += 1
        switch result {
        case .succeeded:
            databaseOperation = .idle
        case let .failed(message):
            databaseOperation = .clearFailed(message: message)
        }
    }

    private func cancelFailedClear() {
        guard case .clearFailed = databaseOperation else { return }
        databaseOperation = .idle
    }
}

/// A consistently separated, titled subsection inside the Advanced disclosure.
/// Platform-only features use this wrapper so they do not recreate Advanced's
/// divider and heading layout.
public struct SettingsAdvancedSubsection<Content: View>: View {
    private let title: String
    private let content: () -> Content

    public init(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        Divider()
        SettingsSubsectionHeader(title: title)
        content()
    }
}

private struct SettingsSubsectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

private struct SettingsStorageView: View {
    private struct ReloadID: Hashable {
        let parentRevision: Int
        let localRevision: Int
    }

    private enum State: Equatable {
        case loading
        case ready(
            usedBytes: Int64,
            committedLimitGB: Double,
            draftLimitGB: Double
        )
        case confirmingShrink(
            usedBytes: Int64,
            previousLimitGB: Double,
            requestedLimitGB: Double
        )
        case loadFailed(message: String)
    }

    @Binding private var limitGB: Double
    private let reloadRevision: Int
    private let databaseOperation: SettingsDatabaseOperation
    private let loadUsedBytes: () async -> SettingsStorageLoadResult
    private let requestPrune: (_ previousLimitGB: Double, _ requestedLimitGB: Double) -> Void
    private let retryFailedPrune: () -> Void
    private let cancelFailedPrune: () -> Void
    private let scale = StorageLimitScale()

    @State private var state = State.loading
    @State private var localReloadRevision = 0

    init(
        limitGB: Binding<Double>,
        reloadRevision: Int,
        databaseOperation: SettingsDatabaseOperation,
        loadUsedBytes: @escaping () async -> SettingsStorageLoadResult,
        requestPrune: @escaping (
            _ previousLimitGB: Double,
            _ requestedLimitGB: Double
        ) -> Void,
        retryFailedPrune: @escaping () -> Void,
        cancelFailedPrune: @escaping () -> Void
    ) {
        _limitGB = limitGB
        self.reloadRevision = reloadRevision
        self.databaseOperation = databaseOperation
        self.loadUsedBytes = loadUsedBytes
        self.requestPrune = requestPrune
        self.retryFailedPrune = retryFailedPrune
        self.cancelFailedPrune = cancelFailedPrune
    }

    var body: some View {
        Group {
            switch databaseOperation {
            case .pruning:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            case let .pruneFailed(_, _, message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack {
                        Button(String(localized: "Retry")) {
                            retryFailedPrune()
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {
                            cancelFailedPrune()
                        }
                    }
                }
            case .clearing, .clearFailed:
                storageContent
                    .disabled(true)
            case .idle:
                storageContent
            }
        }
        .task(
            id: ReloadID(
                parentRevision: reloadRevision,
                localRevision: localReloadRevision
            )
        ) {
            state = .loading
            if limitGB <= 0 {
                limitGB = scale.minGB
            }
            await load(committedLimitGB: limitGB)
        }
        .alert(
            String(localized: "Reduce Storage Limit?"),
            isPresented: Binding(
                get: {
                    if case .confirmingShrink = state { return true }
                    return false
                },
                set: { isPresented in
                    guard !isPresented else { return }
                    restorePreviousLimit()
                }
            )
        ) {
            Button(String(localized: "Remove Oldest Items"), role: .destructive) {
                startPruning()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                restorePreviousLimit()
            }
        } message: {
            Text(
                String(
                    localized:
                    "History already uses more space than the new limit. The oldest items will be removed to fit."
                )
            )
        }
    }

    @ViewBuilder
    private var storageContent: some View {
        switch state {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        case let .ready(usedBytes, _, _), let .confirmingShrink(usedBytes, _, _):
            storageControls(usedBytes: usedBytes)
        case let .loadFailed(message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button(String(localized: "Retry")) {
                    localReloadRevision += 1
                }
            }
        }
    }

    private func storageControls(usedBytes: Int64) -> some View {
        VStack(spacing: 10) {
            StorageBarView(
                limitGB: draftLimitBinding,
                usedBytes: usedBytes,
                scale: scale,
                onEditingEnded: handleStorageLimitEdit
            )

            Text(
                String(
                    localized:
                    "Drag the handle to set how much space history can use. When it fills, the oldest items are overwritten."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private func handleStorageLimitEdit() {
        switch state {
        case let .ready(usedBytes, committedLimitGB, draftLimitGB):
            if usedBytes > Utilities.bytes(fromGB: draftLimitGB) {
                state = .confirmingShrink(
                    usedBytes: usedBytes,
                    previousLimitGB: committedLimitGB,
                    requestedLimitGB: draftLimitGB
                )
            } else {
                limitGB = draftLimitGB
                state = .ready(
                    usedBytes: usedBytes,
                    committedLimitGB: draftLimitGB,
                    draftLimitGB: draftLimitGB
                )
            }
        case .loading, .confirmingShrink, .loadFailed:
            break
        }
    }

    private func restorePreviousLimit() {
        guard case let .confirmingShrink(usedBytes, previousLimitGB, _) = state else {
            return
        }
        limitGB = previousLimitGB
        state = .ready(
            usedBytes: usedBytes,
            committedLimitGB: previousLimitGB,
            draftLimitGB: previousLimitGB
        )
    }

    private func startPruning() {
        guard case let .confirmingShrink(
            usedBytes,
            previousLimitGB,
            requestedLimitGB
        ) = state else {
            return
        }
        state = .ready(
            usedBytes: usedBytes,
            committedLimitGB: requestedLimitGB,
            draftLimitGB: requestedLimitGB
        )
        requestPrune(previousLimitGB, requestedLimitGB)
    }

    private func load(committedLimitGB: Double) async {
        let result = await loadUsedBytes()
        guard !Task.isCancelled else { return }

        switch result {
        case let .loaded(usedBytes):
            state = .ready(
                usedBytes: usedBytes,
                committedLimitGB: committedLimitGB,
                draftLimitGB: committedLimitGB
            )
        case let .failed(message):
            state = .loadFailed(message: message)
        }
    }

    private var draftLimitBinding: Binding<Double> {
        Binding(
            get: {
                switch state {
                case let .ready(_, _, draftLimitGB):
                    return draftLimitGB
                case let .confirmingShrink(_, _, requestedLimitGB):
                    return requestedLimitGB
                case .loading, .loadFailed:
                    return limitGB
                }
            },
            set: { newValue in
                switch state {
                case let .ready(usedBytes, committedLimitGB, _):
                    state = .ready(
                        usedBytes: usedBytes,
                        committedLimitGB: committedLimitGB,
                        draftLimitGB: newValue
                    )
                case .loading, .confirmingShrink, .loadFailed:
                    break
                }
            }
        )
    }
}

private struct SettingsHistoryView: View {
    private enum Confirmation: Equatable {
        case idle
        case confirmingClear
    }

    private let databaseOperation: SettingsDatabaseOperation
    private let requestClear: () -> Void
    private let retryFailedClear: () -> Void
    private let cancelFailedClear: () -> Void

    @State private var confirmation = Confirmation.idle

    init(
        databaseOperation: SettingsDatabaseOperation,
        requestClear: @escaping () -> Void,
        retryFailedClear: @escaping () -> Void,
        cancelFailedClear: @escaping () -> Void
    ) {
        self.databaseOperation = databaseOperation
        self.requestClear = requestClear
        self.retryFailedClear = retryFailedClear
        self.cancelFailedClear = cancelFailedClear
    }

    var body: some View {
        Group {
            switch databaseOperation {
            case .clearing:
                HStack {
                    Text(String(localized: "Clearing…"))
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            case let .clearFailed(message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Clear failed"))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "Retry"), role: .destructive) {
                            retryFailedClear()
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {
                            cancelFailedClear()
                        }
                    }
                }
            case .pruning, .pruneFailed:
                Button(String(localized: "Clear History"), role: .destructive) {}
                    .disabled(true)
            case .idle:
                confirmationControl
            }
        }
        .onChange(of: databaseOperation) { _, operation in
            if case .pruning = operation {
                confirmation = .idle
            }
        }
    }

    @ViewBuilder
    private var confirmationControl: some View {
        switch confirmation {
        case .idle:
            Button(String(localized: "Clear History"), role: .destructive) {
                confirmation = .confirmingClear
            }
        case .confirmingClear:
            Button(String(localized: "Tap Again to Confirm"), role: .destructive) {
                confirmation = .idle
                requestClear()
            }
        }
    }
}
