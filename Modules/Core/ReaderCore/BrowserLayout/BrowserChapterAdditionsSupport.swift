import Foundation

/// 上游参考实现未随提交给出（上游仓库缺失该定义），此处补最小定义：
/// 段评徽章/卡片以 `<img>` 追加进章节正文，其属性名即由此提供。
enum BrowserAddedContent {
    /// 追加 `<img>` 元素的属性名：没有哪个出版物资源会使用该名。
    nonisolated static let attributeName = "yd-added-content"
}

extension BrowserChapterLayout {
    /// 纯追加图片页的页起始索引（上游实现未提交，恒为空）：
    /// 追加图片卡片所在页不计入阅读位置映射。
    var pageAddedStarts: [Int] { [] }
}
