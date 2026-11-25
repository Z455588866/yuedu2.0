import AVFoundation
import CoreGraphics

/// 画面在播放器窗口里的摆放方式。
///
/// 四档完整照搬 ijkplayer 的 `IJKMPMovieScalingMode`（它又沿自 Apple 的
/// `MPMovieScalingMode`），这是 ijkplayer / VLC / MX Player / nPlayer 给用户的
/// 通用档位，也是用户认可的成熟项目标准：
/// - `Original`：`None`，保持片源比例、完整显示、不放大超过原始像素；
/// - `Fit`：`AspectFit`，等比缩放到某一维刚好装下，完整画面，多出的方向留黑边；
/// - `Fill`：`AspectFill`，等比缩放到铺满窗口，某一维被裁掉；
/// - `Stretch`：`Fill`，非等比拉伸，两维都精确贴合窗口。
///
/// 说明：ijkplayer 的 `None` 严格语义是 1:1 原始像素、居中、超出裁切。移动端片源
/// 普遍大于屏幕，1:1 会把画面裁成中间一块特写（用户明确反馈过这是「原始比例有问题」）。
/// 因此这里把 `original` 落地为「等比完整显示、且绝不放大超过 1:1」：片源大于窗口时
/// 等比缩小装下（完整不裁切），片源小于窗口时保持原始像素不放大。既保留了原画档，
/// 又不会出现裁成特写的 bug；「严格 1:1 裁切」若确实需要，可由后续版本再补。
///
/// 弹幕与字幕的跟随方式照搬成熟引擎：
/// - 字节 `DanmakuRenderEngine`：弹幕视图尺寸必须与视频画面尺寸一致；
/// - `CommentCoreLibrary`：画面缩放时拉伸弹幕容器、字号等比放大。
/// 所以本枚举同时决定三件事：`AVPlayerLayer.videoGravity`、画面实际矩形（弹幕/字幕
/// 照着摆放）、以及字号倍数。三者用同一套缩放，保证画面和弹幕永远对得上。
enum VideoScalingMode: String, CaseIterable, Identifiable {
    /// 原画：保持片源比例、完整显示、不放大超过原始像素。
    case original
    /// 适应：等比缩放到某一维刚好装下，完整画面，多出的方向留黑边。
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
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "rectangle.expand.vertical"
        }
    }

    /// 给 `AVPlayerLayer.videoGravity` 用。AVPlayerLayer 没有 1:1 档，
    /// `original` 用 `.resizeAspect`（等比装下），配合 `pictureRect` 的「不放大」
    /// 上限，实际表现就是等比完整、不超原始像素。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .original, .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    /// 画面在窗口里实际占的矩形。弹幕层、字幕层都按这个矩形摆放。
    /// 片源尺寸未知时退回整窗，避免第一帧闪一下空白。
    func pictureRect(native: CGSize, in bounds: CGSize) -> CGRect {
        guard native.width > 0, native.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let drawn = drawnSize(native: native, in: bounds)
        return CGRect(x: (bounds.width - drawn.width) / 2,
                      y: (bounds.height - drawn.height) / 2,
                      width: drawn.width,
                      height: drawn.height)
    }

    /// 实际绘制尺寸，四档共用；`pictureRect` 和 `textScale` 都基于它，确保一致。
    private func drawnSize(native: CGSize, in bounds: CGSize) -> CGSize {
        let sx = bounds.width / native.width
        let sy = bounds.height / native.height
        switch self {
        case .original:
            // 等比装下，但缩放上限为 1：片源大于窗口时缩小装下（完整不裁切），
            // 片源小于窗口时保持 1:1 不放大。
            let scale = min(1, sx, sy)
            return CGSize(width: native.width * scale, height: native.height * scale)
        case .fit:
            let scale = min(sx, sy)
            return CGSize(width: native.width * scale, height: native.height * scale)
        case .fill:
            let scale = max(sx, sy)
            return CGSize(width: native.width * scale, height: native.height * scale)
        case .stretch:
            return bounds
        }
    }

    /// 弹幕字号要乘的倍数：画面放大多少，字就放大多少（CommentCoreLibrary 的做法）。
    /// 拉伸模式下两维比例不同，取较小的一维，免得字幕被拉成巨字。
    func textScale(native: CGSize, in bounds: CGSize) -> CGFloat {
        guard native.width > 0, native.height > 0,
              bounds.width > 0, bounds.height > 0 else { return 1 }
        let drawn = drawnSize(native: native, in: bounds)
        return min(drawn.width / native.width, drawn.height / native.height)
    }
}
