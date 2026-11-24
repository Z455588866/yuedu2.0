import SwiftUI
import UIKit

/// 猫元的封面图加载。
///
/// 原来用 `AsyncImage`：滚过去的封面上下一滚回来就要重新下载，点进详情再返回
/// 还会白一下。SwiftUI 内部走 `URLSession.shared`，缓存策略不受我们控制，而本
/// App 的其它网络请求刻意不带 `URLCache`（见 `URLSession.savedDownloads`），
/// 共享缓存因此长期接近冷启动。这里给封面单独两层：
///
/// - 内存存**解码后**的 `UIImage`，同一张封面不再重复解码；
/// - 磁盘存原始字节（独立的 192MB `URLCache`），重进 App 也不用重下；
/// - 同一个 URL 的在途请求合并成一次，网格里十张同款海报不会发十个请求。
@MainActor
final class CatVodCoverStore {
    static let shared = CatVodCoverStore()

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// 封面 CDN 与源站不同域，也不经过源站的 TLS 兼容层；这里只服务图片。
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                          diskCapacity: 192 * 1024 * 1024,
                                          diskPath: "CatVodCovers")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 12
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    private var inflight: [String: Task<UIImage?, Never>] = [:]

    /// 同步读内存，只用于首帧：命中就先用，没命中再去加载。
    func cached(_ url: String) -> UIImage? {
        images.object(forKey: url as NSString)
    }

    func image(for url: String) async -> UIImage? {
        guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else { return nil }
        if let hit = images.object(forKey: url as NSString) { return hit }
        if let running = inflight[url] { return await running.value }

        let task = Task<UIImage?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: parsed)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }
                // 解码放在后台并做降采样：`UIImage(data:)` 本身是惰性的，真正的
                // 解码发生在第一次上屏那一帧的主线程上。海报网格一屏十几张、
                // 一滚就是几十张，全都挤在渲染前解码，滚动就掉帧。这里直接
                // 用 ImageIO 生成thumbnail，既在后台完成解码，又只保留网格
                // 需要的那点像素（原图常是 1000×1500，实际只画 130×190）。
                return await Task.detached(priority: .utility) { Self.downsample(data) }.value
            } catch {
                return nil
            }
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image {
            let pixels = image.size.width * image.size.height * image.scale * image.scale
            images.setObject(image, forKey: url as NSString, cost: Int(pixels) * 4)
        }
        return image
    }

    /// ImageIO 降采样：在后台线程完成解码，只产出网格实际需要的像素量。
    /// 失败时退回 `UIImage(data:)`——某些源给的是 webp 之外的怪格式，
    /// ImageIO 认不出，但 UIKit 认得。
    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat = 900) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

/// 海报位置统一用它：尺寸与圆角由调用方给，这里只管「有图显示图，没图不闪」。
struct CatVodCoverImage: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // `scaledToFill` 只报告被提议的尺寸，画面却按自身比例画出去。
                    // 少这一刀，横版剧照就会爬出单元格盖住邻列——网格"错乱"的根源。
                    .clipped()
                    .transition(.opacity)
            } else {
                ZStack {
                    DSColor.surfaceTertiary
                    Image(systemName: "film")
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .task(id: url) {
            if let cached = CatVodCoverStore.shared.cached(url) {
                image = cached
                return
            }
            let loaded = await CatVodCoverStore.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
