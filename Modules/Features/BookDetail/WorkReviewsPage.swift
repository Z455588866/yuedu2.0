import SwiftUI

/// 读者评论, pushed from 作品详情's section: the work's rating as a whole when the module gave
/// one, then every review, as Apple Books' store lists them. The reviews are the ones the
/// section showed, frozen at the tap: the page asks no site again.
struct WorkReviewsPage: View {
    let reviews: WorkReviewSet
    @State private var order = WorkReviewOrder.site
    @Environment(\.locale) private var locale

    private var orders: [WorkReviewOrder] { WorkReviewOrder.available(for: reviews.reviews) }
    private var sorted: [WorkReview] { order.sorted(reviews.reviews) }

    var body: some View {
        List {
            Section {
                if let rating = reviews.rating {
                    WorkRatingSummary(rating: rating)
                        .reviewRow()
                }
                header
                    .reviewRow()
                // By position: two readers can write the same words.
                ForEach(sorted.indices, id: \.self) { index in
                    WorkReviewCard(review: sorted[index])
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(sorted[index].spokenText(locale: locale))
                        .accessibilityIdentifier("reviews.card")
                        .reviewRow()
                }
                // Where the words came from: the module's site, not the app. A row in the
                // footer's style, not the section's footer: a plain list paints its footer with a
                // band of its own, which breaks a themed page's background (design.md §4.1).
                Text(String(format: localized("评论来自 %@"), reviews.moduleTitle))
                    .dsSectionFooter()
                    .accessibilityIdentifier("reviews.source")
                    .reviewRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // A white page under quiet grey cards, as Apple Books' own 读者评论 (maintainer,
        // 2026-11-14: 「这个背面颜色和 Apple Books 的也不一样」), as 探索's home is white under its
        // shaded sections. A theme's own page colour and picture still paint it.
        .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
        .pageBackgroundToolbar(for: .global)
        .navigationTitle(localized("读者评论"))
        .toolbarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(localized("评论"))
                .font(DSFont.title3.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DSSpacing.sm)
            // Offered only where the reviews can be put in another order.
            if orders.count > 1 {
                Menu {
                    Picker(localized("排序"), selection: $order) {
                        ForEach(orders, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    // The word, then its arrows, as the store's own 排序 reads.
                    HStack(spacing: DSSpacing.xs) {
                        Text(localized("排序"))
                        Image(systemName: "arrow.up.arrow.down")
                            .accessibilityHidden(true)
                    }
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
                    .frame(minHeight: DSLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(localized("排序"))
                .accessibilityValue(order.title)
                .accessibilityIdentifier("reviews.sort")
            }
        }
    }
}

private extension View {
    /// A row of the page: no separator, no row colour of its own over the page's background.
    func reviewRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DSSpacing.sm, leading: DSSpacing.lg, bottom: DSSpacing.sm, trailing: DSSpacing.lg))
    }
}

/// The order 读者评论 lists its reviews in.
enum WorkReviewOrder: Hashable, CaseIterable {
    /// As the site listed them.
    case site
    case newest
    case mostHelpful

    var title: String {
        switch self {
        case .site: localized("预设")
        case .newest: localized("最新")
        case .mostHelpful: localized("最有帮助")
        }
    }

    /// The site's order always; by day when a review has one, by helpfulness when one was marked.
    static func available(for reviews: [WorkReview]) -> [WorkReviewOrder] {
        var orders: [WorkReviewOrder] = [.site]
        if reviews.contains(where: { $0.date != nil }) { orders.append(.newest) }
        if reviews.contains(where: { $0.likes != nil }) { orders.append(.mostHelpful) }
        return orders
    }

    /// Stable: reviews the order cannot tell apart keep the site's order, and one without the
    /// value comes last.
    func sorted(_ reviews: [WorkReview]) -> [WorkReview] {
        switch self {
        case .site:
            return reviews
        case .newest:
            return reviews.enumerated().sorted { lhs, rhs in
                let left = lhs.element.date ?? .distantPast, right = rhs.element.date ?? .distantPast
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        case .mostHelpful:
            return reviews.enumerated().sorted { lhs, rhs in
                let left = lhs.element.likes ?? 0, right = rhs.element.likes ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
    }
}

/// The work's rating as a whole: the average large, then a bar per star and how many ratings
/// there are, each only when the site gave it.
struct WorkRatingSummary: View {
    let rating: WorkRating
    @Environment(\.locale) private var locale

    private var spoken: String {
        var parts = [WorkRating.spoken(rating.score, locale: locale)]
        if let count = rating.count { parts.append(String(format: localized("%d 则评分"), count)) }
        return parts.joined(separator: "，")
    }

    var body: some View {
        HStack(alignment: .center, spacing: DSSpacing.lg) {
            VStack(spacing: DSSpacing.xs) {
                Text(verbatim: WorkRating.text(rating.score, locale: locale))
                    .font(DSFont.largeTitle.weight(.bold))
                    .foregroundStyle(DSColor.textPrimary)
                    .monospacedDigit()
                Text(String(format: localized("满分 %d 颗星"), WorkRating.stars))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .fixedSize()
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: DSSpacing.xs) {
                if let distribution = rating.distribution {
                    WorkRatingBars(distribution: distribution)
                }
                if let count = rating.count {
                    Text(String(format: localized("%d 则评分"), count))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: DSLayout.ratingBarMaxWidth, alignment: .trailing)
        }
        .padding(.vertical, DSSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("reviews.rating")
    }
}

/// A bar per star, the highest first: each as full as its share of every rating.
private struct WorkRatingBars: View {
    let distribution: [Int]

    var body: some View {
        let total = max(distribution.reduce(0, +), 1)
        Grid(alignment: .trailing, horizontalSpacing: DSSpacing.sm, verticalSpacing: DSSpacing.xs) {
            ForEach(distribution.indices, id: \.self) { index in
                GridRow {
                    HStack(spacing: 0) {
                        ForEach(0..<(distribution.count - index), id: \.self) { _ in
                            Image(systemName: "star.fill")
                        }
                    }
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                    ProgressView(value: Double(distribution[index]), total: Double(total))
                        .tint(DSColor.textSecondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("读者评论页") {
    NavigationStack {
        WorkReviewsPage(reviews: .preview)
    }
}

#Preview("读者评论页 · 只有内文") {
    NavigationStack {
        WorkReviewsPage(reviews: WorkReviewSet(moduleID: "preview", moduleTitle: "范例", reviews: [
            WorkReview(text: "从这本开始入坑。"), WorkReview(text: "good book, recommend to read", author: "scouthe"),
        ], rating: nil))
    }
}
#endif
