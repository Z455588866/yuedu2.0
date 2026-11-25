import AVFoundation
import CoreGraphics

/// 画面在播放器窗口里的摆放方式。
///
/// 四档完整对齐 ijkplayer 的 `IJKMPMovieScalingMode`（它又沿自 Apple 的
/// `MPMovieScalingMode`），也是 tvbox-silicon / VLC / Infuse 给用户的通用档位：
/// - `original`：原画，等比完整显示、不裁切，且不放大超过片源的 1:1 像素；
/// - `fit`：适应，等比缩放到装下，完整画面，多出的方向留黑边；
/// - `fill`：铺满（裁剪），等比缩放到铺满窗口，某一维被裁掉；
/// - `stretch`：拉伸，非等比拉伸，两维都精确贴合窗口。
///
/// 矩形计算整套照搬成熟项目 tvbox-silicon 的 `SubtitleOverlay`：用 Apple 官方
/// `AVMakeRect(aspectRatio:insideRect:)`，并区分两个矩形——
/// - `pictureRect`：画面的「可见区域」，弹幕容器、外挂字幕按它摆放；铺满/拉伸后
///   整窗都是画面，所以它返回整窗（旧实现错误地返回超出屏幕的放大矩形，弹幕会
///   跑到屏外，这正是「铺满档没优化好」的根因）；
/// - `videoRect`：片源的「完整矩形」（含被裁掉的部分），画面层（VLC drawable）
///   按它铺满，需要把片源坐标映射到屏幕时用。
///
/// 画面层与弹幕/字幕层的矩形都由本枚举同一套算法算出，严格对应各自的
/// `videoGravity` / libvlc aspect，因此画面与弹幕永远对得上。
enum VideoScalingMode: String, CaseIterable, Identifiable {
    /// 原画：等比完整显示、不裁切，且不放大超过 1:1 像素。
    case original
    /// 适应：等比缩放到装下，完整画面，多出的方向留黑边。
    case fit
    /// 铺满（裁剪）：等比缩放到铺满窗口，某一维被裁掉。
    case fill
    /// 拉伸：非等比拉伸，两维都精确贴合窗口。
    case stretch

    var id: String { rawValue }

    /// 本地化 key。调用方用 `localized(mode.labelKey)` 取文案。
    var labelKey: String {
        switch self {
        case .original: return "原画"
        case .fit: return "适应"
        case .fill: return "铺满（裁剪）"
        case .stretch: return "拉伸"
        }
    }

    var systemImage: String {
        switch self {
        case .original: return "square.dashed"
        case .fit: return "rectangle.center.inset.filled"
        case .fill: return "arrow.up.left.and.arrow.down.right"
        case .stretch: return "arrow.left.and.right"
        }
    }

    /// 给 `AVPlayerLayer.videoGravity` 用。四档映射照搬 tvbox-silicon 的
    /// `VideoFill.gravity`（fit=.resizeAspect / fill=.resizeAspectFill /
    /// stretch=.resize），原画档同 fit，用等比装下保证完整不裁切。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .original, .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    /// 等比装下（AspectFit）的矩形，用 Apple 官方 `AVMakeRect`。
    /// `capAtNative` 为 true 时缩放上限 1：片源大于窗口就缩小装下，片源小于窗口
    /// 保持原始像素不放大——这是「原画」相对「适应」的唯一区别，避免小片源被
    /// 拉成大块而糊掉。画面层与弹幕层共用它，保证两者严格一致。
    private func fittedRect(native: CGSize, in bounds: CGSize, capAtNative: Bool) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        let fit = AVMakeRect(aspectRatio: native, insideRect: whole)
        guard capAtNative, native.width > 0, native.height > 0,
              fit.width > 0, fit.height > 0 else { return fit }
        let scale = min(1, fit.width / native.width, fit.height / native.height)
        let size = CGSize(width: native.width * scale, height: native.height * scale)
        return CGRect(x: whole.midX - size.width / 2,
                      y: whole.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 画面在窗口里「可见」的矩形——弹幕容器、外挂字幕按它摆放。
    /// 照搬 tvbox-silicon 的 `pictureRect(in:fills:)`：
    /// - 等比装下（原画/适应）用 `AVMakeRect` 算出带黑边的画面矩形；
    /// - 铺满/拉伸后整窗都是画面，可见区域即整窗，弹幕铺满全屏。
    /// 片源尺寸未知时退回整窗，避免第一帧闪一下空白。
    func pictureRect(native: CGSize, in bounds: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        guard native.width > 0, native.height > 0,
              bounds.width > 0, bounds.height > 0 else { return whole }
        switch self {
        case .original:
            return fittedRect(native: native, in: bounds, capAtNative: true)
        case .fit:
            return fittedRect(native: native, in: bounds, capAtNative: false)
        case .fill, .stretch:
            // 铺满/拉伸：画面铺满整窗，可见区域就是整窗。
            // 旧实现返回放大矩形（超过 bounds），弹幕帧被放到屏幕外——已修正。
            return whole
        }
    }

    /// 片源的「完整矩形」（含被裁掉的部分）——VLC 画面层按它铺满，
    /// 需要把片源坐标映射到屏幕时也用它（如 ASS 脚本字幕按片源分辨率定位）。
    /// 照搬 tvbox-silicon 的 `videoRect(in:fills:stretches:)`。
    func videoRect(native: CGSize, in bounds: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        guard native.width > 0, native.height > 0,
              bounds.width > 0, bounds.height > 0 else { return whole }
        if self == .stretch { return whole }
        let fit = fittedRect(native: native, in: bounds, capAtNative: self == .original)
        guard self == .fill, fit.width > 0, fit.height > 0 else { return fit }
        let scale = max(bounds.width / fit.width, bounds.height / fit.height)
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        return CGRect(x: whole.midX - size.width / 2,
                      y: whole.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
