import SwiftUI

/// 自动换源的提示：搜寻中显示转圈，失败时显示原因一段时间后收起。
///
/// 跟书签提示同一条顶端带状区，不挡手；VoiceOver 在出现时听到公告，不当焦点。
struct ReaderAutoChangeSourceBanner: View {
    let notice: ReaderViewModel.AutoChangeSourceNotice
    /// The reader theme's scheme, not the system's (see `ReaderBookmarkToastView`).
    let colorScheme: ColorScheme
    let onExpire: () -> Void

    /// How long a failure stays up — the message's own lifetime, not a wait for state.
    static let failureDisplayDuration: Duration = .milliseconds(3200)

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            switch notice {
            case .changing:
                ProgressView()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DSColor.warning)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(.primary)
        }
        .font(DSFont.subheadline.weight(.semibold))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: DSColor.shadow, radius: DSSpacing.sm, y: DSSpacing.xs)
        .environment(\.colorScheme, colorScheme)
        .accessibilityHidden(true)
        .task(id: notice) {
            UIAccessibility.post(notification: .announcement, argument: text)
            guard case .failed = notice else { return }
            do {
                try await Task.sleep(for: Self.failureDisplayDuration)
            } catch {
                // Cancelled: a newer notice replaced this one, or the reader closed.
                return
            }
            onExpire()
        }
    }

    private var text: String {
        switch notice {
        case .changing: localized("正在自动换源…")
        case .failed(_, let message): message
        }
    }
}

#Preview("自动换源中") {
    ReaderAutoChangeSourceBanner(notice: .changing, colorScheme: .light, onExpire: {})
        .padding()
}

#Preview("自动换源失败・夜间") {
    ReaderAutoChangeSourceBanner(
        notice: .failed(id: UUID(), message: localized("自动换源失败：没有可用的来源配置")),
        colorScheme: .dark,
        onExpire: {}
    )
    .padding()
    .background(Color.black)
}
