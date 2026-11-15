import SwiftUI

/// 云端语音的服务选择页：从「语音朗读设置」右上角的云朵按钮进入。
///
/// 三家服务各自使用读者自己存放在本机 Keychain 的金钥，音色与区域在各自的设置页里
/// 挑选；这里只做入口，不改动本地已有的语音源汇入流程。
struct CloudVoiceServiceChooser: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(CloudTTSService.allCases, id: \.rawValue) { service in
                    NavigationLink {
                        TTSCloudVoiceSettingsView(service: service)
                    } label: {
                        Label {
                            Text(localized(service.displayNameKey))
                        } icon: {
                            Image(systemName: "waveform")
                        }
                    }
                }
            } header: {
                Text(localized("云端语音服务"))
            } footer: {
                Text(localized("金钥只存在这台装置，语音费用由你的账号计算。选好音色后可在朗读声音里设为当前语音源。"))
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("云端语音"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(localized("关闭"))
            }
        }
    }
}
