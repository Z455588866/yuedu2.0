import AVFoundation
import CoreGraphics

/// 画面在播放器窗口里的摆放方式。
///
/// 四档不是随手定的，直接照搬播放器行业的既有定义：
/// Bilibili ijkplayer 的 `IJKMPMovieScalingMode`（`IJKMediaPlayback.h`）——
/// `None` / `AspectFit` / `AspectFill` / `Fill`，其注释原文是
/// "No scaling"、"Uniform scale until one dimension fits"、
/// "Uniform scale until the movie fills the visible bounds. One dimension may have clipped
/// contents"、"Non-uniform scale. Both render dimensions will exactly match the visible bounds"。
/// 这套枚举又是从 Apple 早已废弃的 `MPMovieScalingMode` 沿用下来的，所以主流播放器
/// （ijkplayer、VLC、MX Player、nPlayer）给用户的就是这四档。
///
/// 弹幕与字幕的跟随方式同样是照搬：
/// - 字节 `DanmakuRenderEngine`：弹幕视图的尺寸必须与视频画面尺寸一致；
/// - `CommentCoreLibrary`：画面缩放时不要逐条改弹幕，而是拉伸弹幕容器，
///   字号随之等比放大（"弹幕大了自然速度就慢了，没必要继续降低速度"）。
///
/// 因此本枚举同时负责三件事：给 `AVPlayerLayer` 的 `videoGravity`、
/// 算出画面实际矩形（弹幕/字幕层照着摆放）、算出字号该乘的倍数。
enum VideoScalingMode: String, CaseIterable, Identifiable {
    /// `IJKMPMovieScalingModeAspectFit`：等比缩放到某一维刚好装下，完整画面，多出的方向留黑边。
    case fit
    /// `IJKMPMovieScalingModeAspectFill`：等比缩放到铺满窗口，某一维被裁掉。
    case fill
    /// `IJKMPMovieScalingModeFill`：非等比拉伸，两维都精确贴合窗口。
    case stretch
    /// `IJKMPMovieScalingModeNone`：不缩放，按原始像素尺寸居中（画面通常大于窗口）。
    case actual

    var id: String { rawValue }

    /// 本地化 key。调用方用 `localized(mode.labelKey)` 取文案——
    /// 不在这里直接调 `localized`，新文件就不依赖它的可见性。
    var labelKey: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "铺满（裁剪）"
        case .stretch: return "拉伸"
        case .actual: return "原始尺寸"
        }
    }

    var systemImage: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "rectangle.expand.vertical"
        case .actual: return "square.dashed"
        }
    }

    /// 给 `AVPlayerLayer.videoGravity` 用。`actual` 没有对应档位：先按适应渲染，
    /// 再由 `pictureRect` 摆成原始大小（`AVPlayerLayer` 只认三种重力）。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit, .actual: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    /// 画面在窗口里实际占的矩形。弹幕层、字幕层都按这个矩形摆放，
    /// 于是画面怎么放大/裁剪，它们就跟着怎么动。
    /// 片源尺寸未知时退回整窗，避免第一帧闪一下空白。
    func pictureRect(native: CGSize, in bounds: CGSize) -> CGRect {
        guard native.width > 0, native.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let drawn: CGSize
        switch self {
        case .fit:
            let scale = min(bounds.width / native.width, bounds.height / native.height)
            drawn = CGSize(width: native.width * scale, height: native.height * scale)
        case .fill:
            let scale = max(bounds.width / native.width, bounds.height / native.height)
            drawn = CGSize(width: native.width * scale, height: native.height * scale)
        case .stretch:
            drawn = bounds
        case .actual:
            drawn = native
        }
        return CGRect(x: (bounds.width - drawn.width) / 2,
                      y: (bounds.height - drawn.height) / 2,
                      width: drawn.width,
                      height: drawn.height)
    }

    /// 弹幕字号要乘的倍数：画面放大多少，字就放大多少（CommentCoreLibrary 的做法）。
    /// 我们按固定时长跨屏，字变大后自然变慢，所以速度不用另调。
    /// 拉伸模式下两维比例不同，取较小的一维，免得字幕被拉成巨字。
    func textScale(native: CGSize, in bounds: CGSize) -> CGFloat {
        guard native.width > 0, native.height > 0,
              bounds.width > 0, bounds.height > 0 else { return 1 }
        let sx = bounds.width / native.width
        let sy = bounds.height / native.height
        switch self {
        case .fit: return min(sx, sy)
        case .fill: return max(sx, sy)
        case .stretch: return min(sx, sy)
        case .actual: return 1
        }
    }
}
