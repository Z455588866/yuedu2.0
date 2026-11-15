# Yuedu Reader — iOS 原生设计规范 (design.md)

> 本档是 Yuedu Reader（阅读）所有 UI 设计与实作必须遵守的单一准则。
> 目标：做出「**成熟的大型 iOS 原生阅读器**」，而不是网页后台、Landing Page、Dashboard 或 Android App。
> 实作入口见 `.claude/skills/yuedu-ios-design/SKILL.md` 与 `.agents/skills/yuedu-ios-design/SKILL.md`；两份 skill 必须同步维护，规则以本档为准。

合成来源（依优先序）：
1. **Apple Human Interface Guidelines / Apple 平台文件** — 平台行为与元件的最高权威。
2. **Yuedu 专案规范与既有设计系统** — 在不违反 Apple 规范下维持产品一致性。
3. **通用可用性建议** — 例如 Nielsen 启发法，作为设计检查而非平台行为依据。

### 规则权威层级

- **[Apple]**：Apple HIG、Accessibility、SwiftUI API 与官方设计资源；若规则冲突，以此层为准。
- **[Yuedu]**：本专案的产品决策、元件惯例与 `DS*` token；仅能在 Apple 允许的范围内加严或具体化。
- **[建议]**：Nielsen 等通用可用性原则与设计经验；不能覆盖 [Apple] 或 [Yuedu]。

优先序为 **[Apple] > [Yuedu] > [建议]**。下文未标示时，硬规则视为 [Yuedu]；涉及系统元件语意与行为时仍以 [Apple] 为准。

---

## 0. 最高原则

1. 一切以 **Apple HIG** 为准；不确定时选「最像系统内建 App」的做法。
2. **阅读体验 > 视觉花俏**。任何装饰不得伤害正文可读性。
3. **原生元件优先**。先问「系统内建 App 会怎么做」，再动手。
4. 每个画面都必须支援 **深色模式、Dynamic Type、VoiceOver、单手操作**。
5. **不要重造系统能力**：能用 `List`/`Sheet`/`Menu`/`Toolbar` 就不要自刻。

---

## 1. 不可违反的硬规则（Hard Rules）

这些是 PR review 会直接挡下的红线：

| # | 规则 | 正确 | 错误 |
|---|------|------|------|
| H1 | title mode：仅主界面根目录（Tab 根页）用大标题，一律经 `rootTabTitle(_:onScroll:)`；其余一律 `.inline` | 见 §2 矩阵 | 在 pushed / sheet 用 `rootTabTitle(_:onScroll:)`，或使用 `.automatic` / `.large` / `.inlineLarge` |
| H2 | 所有对使用者显示的文字走 `localized("…")`，且每个 lproj 同步（目前为 zh-Hant、zh-Hans、en、ja、ko，含 `InfoPlist.strings` 的权限提示） | `Text(localized("书架"))` | `Text("Bookshelf")` |
| H3 | 颜色、字级、间距、圆角、动画一律用 `DS*` token | `DSColor.textSecondary` | `Color.gray` / 写死 hex |
| H4 | 图示优先 SF Symbols，且与文字字重/字级一致 | `Image(systemName: "trash")` | 自制 PNG icon |
| H5 | icon-only 按钮必须有 `accessibilityLabel` | `.accessibilityLabel(localized("删除"))` | 只有图示无语意 |
| H6 | 颜色不得作为唯一状态提示（需文字/图示辅助） | 「失败」红字+`xmark` | 只靠红色 |
| H7 | 一般互动的 **hit region** 预设至少 **44×44pt**；**28×28pt** 只描述受限 compact 情境的最小 visible control size，必须搭配充分 spacing，不能当作缩小一般 hit target 的理由；reader chrome 与 primary actions 维持至少 44×44pt hit region | 扩大 hit region 且控制间保留间距 | 把 28pt visible control 直接当一般 hit target |
| H8 | 每个资料画面都要设计 **空 / 载入 / 错误** 三态 | 见 §9 | 只做 happy path |
| H9 | 不得做成网页式 UI（dashboard 卡片墙、侧栏、Landing） | 见 §13 | Tailwind 风格 |
| H10 | accessibility modifier 只能加在**该元素本身**，不能加在容器上（会往下传给每个子元素） | 每颗 `Button` 各自 `.accessibilityLabel` | 在包住三颗按钮的 `HStack` 上加一个 label |
| H11 | 区块底部说明一律收拢为原生 `Section { ... } footer: { Text(...) }` 并套用 `.dsSectionFooter()`（Apple HIG 13pt Footnote + `DSColor.textSecondary`） | `Section { ... } footer: { Text(localized("...")).dsSectionFooter() }` | 在 Section 内用普通 Row 当说明、用 `VStack` 塞副标题、或单独开说明 Section |
| H11b | footer 只写控制项看不出来的事（代价／风险／副作用／资料来源），一句话，最多两句 | 「删除帐号无法复原。」 | 复述按钮标签（「重新整理名单」配上一段解释它会重新整理名单）、描述实作、解释功能存在的理由 |

---

## 2. 页面标题、Toolbar 与 Sheet

### 2.1 标题模式矩阵

先判断画面是否为「主界面根目录」（Tab 根页）；规则只有两种状态，toolbar 是否存在不是决定条件。

| 情境 | title mode | 原因 / 注意事项 |
|------|------------|-----------------|
| **主界面根目录**（Tab 根页） | `rootTabTitle(_:onScroll:)` | 唯一用大标题的层级：导览列左侧的粗体大标题，和右侧按钮同一行，iOS 17 起每个版本都一样。 |
| Pushed detail（导航堆叠内的详情、设定子页） | `.inline` | 维持清楚的返回层级，为导览与动作保留空间。 |
| Sheet / modal task | `.inline` | 标题精简，leading / trailing 分别容纳取消与完成。 |
| Reader / immersive surface | `.inline` | 依沉浸状态与 chrome 显示需求决定呈现；不使用大标题。 |

**主界面根目录白名单**：书架 `HomeView`、探索 `ExploreHome`、资源库 `LibraryTabRoot`、设定 `SettingsView`、搜索 tab 根页（`SearchView(isTabRoot: true)`；同一页被推入时仍是 `.inline`）。名单以外的页面一律 `.inline`。

大标题是主界面根目录的固定样式（Apple Music / App Store 式的大型标题、同时保留完整 toolbar），**不是全域预设**：根目录以外任何层级都禁用。不用系统的 `.inlineLarge`：它在 iOS 17 的 iPhone 上只画成置中的 `.inline` 小标题（iOS 17.5 模拟器实测），iOS 18 起才是大标题。`rootTabTitle(_:onScroll:)` 改用自己的 `.topBarLeading` toolbar item 画标题（iOS 26 起关掉它的玻璃底），系统标题藏起来但仍设定，推入页的返回键照样显示「‹ 探索」；字级固定在预设大小（系统的列内大标题也不随字级放大，iOS 27 实测），长按显示大型内容检视器，VoiceOver 读成标题。根页的 leading item 会排在大标题右边，加之前要验证可用宽度与本地化。卷动行为分两种，都是原生导览列、原生 toolbar、原生 `.searchable`。书架用 `rootTabTitle(_:onScroll: .fadesTitle)`：页面在卷动内容里放 `rootTabTitleScrollAnchor()`（内容堆叠、格状、列表第一列，没得卷的空状态也放），往下卷 10pt 起标题淡出、再 30pt 完全消失，右侧按钮常驻，不管怎么回到顶端标题都会回来。探索、资源库、设定、搜索用 `.minimizesBar`，即 iOS 27 的导览列缩起（`toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)`，WWDC26〈Modernize your UIKit app〉）：往下卷，整条导览列──标题和按钮一起──滑走，`.navigationBarDrawer(displayMode: .always)` 的搜寻框升到状态列下方；往上卷再回来（Apple Music 的分页，iOS 27 模拟器实测）。探索、搜索的卷动视图用 `rootTabSearchScrollEdges()` 取代 `softScrollEdges()`：iOS 27 用系统自己的边缘，导览列在时是柔和的，搜寻框升上去后它正下方的内容清楚（Apple Music 也是）；强制 `.soft` 会把那段内容糊掉。资源库、设定没有搜寻框，系统边缘会变成硬边，所以维持 `softScrollEdges()`（以上都是 iOS 27 模拟器实测；Apple 也请导览列会缩起的 app 重新评估 `.soft` 覆写）。书架（分页器、各页的列表与格状，含资料夹页）完全不加卷动边缘，用 `hiddenScrollEdges()`：柔和边缘会把卷到导览列下的封面糊掉，系统的硬边又是一条跟页面背景不同色的淡色带加细线（使用者 2026-10-21 选定；系统内建样式没有「颜色一致又不模糊」的选项）。内容不到一屏多时系统不缩起导览列。iOS 17–26 没有导览列缩起：`.minimizesBar` 退回标题淡出，按钮和搜寻框留在原位，所以这几页也放 scroll anchor。不要把标题列或搜寻框画进页面：自制的搜寻框和按钮不是原生的（使用者否决）。系统标题模式也做不到：`.inlineLarge` 卷动后缩成置中小标题、搜寻框留在原位；`.large` 配常驻搜寻框一开始就是小标题（iOS 27 实测）。不用 UIKit `hidesBarsOnSwipe`：卷回顶端时导览列不会自己回来（使用者回报），搜寻框也跟著藏起来。

### 2.2 Toolbar 动作位置与语意

- 主要页面动作放在 trailing（通常是 `.topBarTrailing`）；返回由导航容器提供，避免自行复制。
- Sheet 的 **Cancel / Close** 放 leading：立即关闭且不储存未确认的变更。
- Sheet 的 **Done** 放 trailing：完成流程，并在有编辑内容时储存或提交。
- **Back** 只用于 sheet 内部多步导航，不代表取消或完成。
- 同一层级不要同时呈现 Back、Cancel / Close、Done 三者；先厘清当前步骤的退出与提交语意。
- [Yuedu] 可见的 modal / toolbar chrome 使用 `xmark` 与 `checkmark`，并提供 `localized(...)` 的 `accessibilityLabel`。系统 alert / confirmation dialog 中 `role: .cancel` 的动作保留文字，维持清楚语意。
- Toolbar 图示优先跟随相邻 semantic text style 或系统控制 sizing；`DSFont.toolbarIcon` / `DSFont.toolbarIconLarge` 是固定尺寸例外，只能用于不承载文字的 chrome，且必须以最大 Dynamic Type 验证。颜色使用 `DSColor.accent` 或 `DSColor.textSecondary`。

```swift
// Pushed detail
BookDetailView()
    .navigationTitle(localized("书籍详情"))
    .toolbarTitleDisplayMode(.inline)

// Editable sheet
EditSourceView()
    .navigationTitle(localized("编辑来源配置"))
    .toolbarTitleDisplayMode(.inline)
    .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(localized("取消"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { saveAndDismiss() } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel(localized("完成"))
        }
    }
```

---

## 3. 设计系统 Token（绑定 `Modules/SharedUI/DesignSystem/DesignTokens.swift`）

**禁止写死颜色 / 字体 / 间距 / 圆角 / 动画时间。** 一律引用 token；缺的 token 先补进 `DesignTokens.swift` 再用。

### 颜色 `DSColor`
| 用途 | Token |
|------|-------|
| 主色（按钮、连结、选取） | `accent` |
| 成功 / 警告 / 破坏性 | `success` / `warning` / `destructive` |
| 主文字 / 次文字 / 停用 | `textPrimary` / `textSecondary` / `textDisabled` |
| 页背景 / 卡片 / 巢状 / 分组背景 | `background` / `surface` / `surfaceTertiary` / `groupedBackground` |
| 分隔线 / 边框 | `separator` / `border` |
| 选取高亮 / 浅底 / 阴影 | `highlight` / `accentLight` / `shadow` |
| 书封渐层 | `coverGradients` |

> `text*`、`background`、`surface*`、`separator` 等 system-backed tokens 会随系统 appearance 适应。`accentLight`、`highlight`、`shadow`、`coverGradients` 与任何 brand RGB 并非因此自动 adaptive；必须逐一在 Light、Dark 与 Increase Contrast 验证，必要时先新增对应的 adaptive token。不要在使用端直接写 `Color.gray`、`Color(hex:)` 或品牌硬色。

### 字体 `DSFont`
`caption2 / caption / subheadline / body / bodyBold / headline / title2 / title / largeTitle`，等宽 `monospaced(size:)`，toolbar `toolbarIcon / toolbarIconLarge`。
- `caption2` 至 `largeTitle` 等 semantic tokens 支援 Dynamic Type；`monospaced(size:)`、`toolbarIcon`、`toolbarIconLarge` 是固定 size 例外，不会自动取得同等缩放行为。
- User-visible text 不得使用固定 size token。若内容必须采 custom 或 monospaced 字体，先新增相对于 semantic text style 的 token，再验证最大 accessibility size 与 Bold Text。
- Toolbar icon 优先跟随相邻 semantic text style 或 system sizing；使用固定 icon token 时，必须确认放大字级下不会失衡、遮挡或缩小 hit region。

### 间距 `DSSpacing`
`xs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32`。页面外距用 `xl`，群组间 `lg`，元素内 `sm`。

### 圆角 `DSRadius`
`sm=6（标签/小按钮） / md=8（按钮/输入框） / lg=12（卡片/对话框） / xl=16（图片容器）`。

### 动画 `DSAnimation`
`fast=0.15（即时回馈） / standard=0.28（转场） / slow=0.4（展开）`。不要硬写 duration。

专用 token：`readerChrome`（阅读选单显示／隐藏，以及跟著它动的元件；`showBars` 一律经 `setReaderChromeVisible(_:)` 写入）、`press`（按压回弹）、`dragSettle`（拖曳放手后回到界内）、`splashFade`（启动图淡出）。开书卡片转场的时长 `readerBookTransitionDuration`（0.62s）是定案，不要因为「超过 300ms」去改短。

`DSAnimation` 只是时序 token，不会自行读取 Reduce Motion；每个含位移、缩放或连续运动的 view 都必须依环境值切换动画策略。

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

private func updateExpandedState() {
    withAnimation(reduceMotion ? nil : DSAnimation.standard) {
        isExpanded.toggle()
    }
}
```

Reduce Motion 开启时，移除非必要位移与缩放；需要保留状态转换提示时，改用 opacity 或无动画的即时结果。

---

## 3.1 iPad / 自适应布局

iPad 是同一个 iOS app 的原生自适应版，不是另一个 app root。共享资料模型与 reader engine 在 `Modules/Core` / `Modules/Services`，feature UI 与设定在 `Modules/Features`，design token 在 `Modules/SharedUI/DesignSystem`；iPad 专属 shell 放 `Targets/Yuedu/iPad/`、iPad reader UI 放 `Modules/Features/Reader/iPad/` 等明确目录，避免散落机型判断。

- 布局用 size class、scene/window size 与 readable width 驱动；不要散落 `UIDevice.model` 或机型字串判断。
- 内容必须尊重 safe areas 与 system margins；除非是刻意的沉浸式背景，不要用负间距或硬编码 inset 盖过系统区域。
- 以实际 window size 自适应，不以装置名称推测空间；多工、Stage Manager、Split View 与旋转都可能改变可用尺寸。
- 延后切换到 compact 版型，直到目前版型真的无法维持可读性与操作间距；不要只因单一 size class 或任意 breakpoint 过早缩减资讯。
- iPhone 维持 compact/portrait 的底部 Tab Bar；iPad regular 使用系统 `TabView.sidebarAdaptable` 或 `NavigationSplitView` 等 HIG 原生容器，不自刻侧栏。
- 底部 Tab Bar 照 HIG 常驻：一般 push 进去的页面、sheet、全萤幕、popover 都不收（使用者定，2026-10-15，推翻 2026-10-03 的「只在分页根页显示」：收起的 Tab Bar 返回时会突然冒出来，SwiftUI `TabView` 没有让它跟著页面一起滑走的做法——UIKit `hidesBottomBarWhenPushed` 被它忽略，iOS 26 实测）。只有这些自己的页面用 `.hidesRootTabBar()` 收：阅读器、固定版面阅读器、RSS 文章、RSS 订阅列表、作品详情、个人资料页、来源配置管理（使用者点名，2026-10-16）、书架选取模式（让位给底部操作列）、探索的编辑首页、栏目设定页和它再推的子页（使用者点名，2026-10-17；设定页从长按「设定」进也收，同一页）。收 Tab Bar 的页面推入／返回时，iOS 27 上 Tab Bar 跟著显示它的那一页一起被盖住、一起露出来，像 UIKit 的 `hidesBottomBarWhenPushed`（使用者定 2026-11-14；`RootTabBarTransitionCover` 在转场期间把 Tab Bar 的画面贴进那一页，SwiftUI 仍是 Tab Bar 显示与否的唯一主人；iOS 26.5 拍不到玻璃胶囊，所以 iOS 26 以下维持 SwiftUI 原本的行为：推入时立刻消失、返回动画结束后才出现）。这些页面的卷动内容底部不留边缘模糊——隐藏的 Tab Bar 仍会让系统在底部画模糊；页面自己在底部有列时用 `.hidesRootTabBar(hasBottomBar: true)` 保留（iOS 26+）。被盖住的页面 `onDisappear` 会撤回要求，所以从收起的页面再推出去的页面要自己再要求一次，否则 Tab Bar 在下一层冒出来。每个分页有自己的 `NavigationStack`（2026-10-16 试过一个 stack 包在 `TabView` 外、让 push 自然盖住 Tab Bar，2026-10-17 使用者决定改回这个结构：分页根页的 `.searchable` 到不了外层导览列）。分页顺序是探索・书架・资源库・设定・搜寻，搜寻在最右（使用者定 2026-10-16，取代决策 30 的「搜寻・设定」）；探索在最左、App 开在探索（使用者定 2026-10-25）。Tab Bar 也不缩小：不用 iOS 26 的 `tabBarMinimizeBehavior`，永远完整大小（使用者定 2026-10-15，苹果没有建议要缩小）。
- 书架的 stack 只能用 `navigationDestination(item:)`／`(isPresented:)`，**不要加型别式 `navigationDestination(for:)`**：开书的卡片阅读器由 UIKit（`ReaderNavigationTransitionDriver`）推进这个 stack，页面里自带 `NavigationStack`；iOS 18 起，stack 只要有型别式 destination，就会在 push 结束后把这种页面移掉，开书直接闪回书架（17.5 不会；2026-10-17 实测，`DetailReaderBackSwipeUITests` 书架开书的测试会抓到）。driver 只在阅读器还在 stack 上时接管 delegate 和边缘返回手势，阅读器离开后交还，不然书架上 SwiftUI 自己 push 的页面会没有动画、不能左滑返回。
- iPad 横竖向与视窗 resize 都要能重排；需要 reader 重分页时，以 SwiftUI 已量到的 viewport size 作为唯一触发来源。
- 宽萤幕设定页、sheet、清单与 reader overlay 使用 `DSLayout.readable*Width` token 限制行长；不要直接写 640/760/960 等 magic number。
- 阅读器横向双页是 reader 专属模式：iPad regular + landscape 才自动启用；切回直向或 iPhone 时回单页，阅读位置以 `(spineIndex, charOffset)` 保持。
- iPad 专属档案可以包装共享 view，但不得复制业务逻辑；状态、同步、来源配置、阅读进度仍由共享 model / coordinator 负责。
- 自适应验收至少涵盖：不同 window size、横直向、本地化长字串，以及最大 Dynamic Type / accessibility size。

---

## 4. iOS 原生元件选型

| 需求 | 用 | 不要用 |
|------|-----|--------|
| 页面导航 | `NavigationStack` + `navigationDestination` | 自刻 push 动画 |
| 主分页 | `TabView`（底部 Tab Bar） | 自刻底部列 / 侧栏 |
| 清单 / 设定 | `List`（`.plain` 或 `.insetGrouped`）+ `Section` + `ForEach` row | `ScrollView`+`VStack`/`HStack` 手刻 row、网页表单 |
| 设定行内容 | `Toggle` / `Picker` / `Stepper` / `NavigationLink` / `Slider` | 自刻开关、自刻下拉 |
| 短流程 / 次要任务 | `.sheet`（可加 `.presentationDetents`） | 全萤幕挡住 |
| 重任务 / 沉浸（阅读器） | `.fullScreenCover` | sheet 硬塞 |
| 就地选择 | `Menu` / `Picker` | 自刻下拉 |
| 工具列 / 页面动作 | `.toolbar { ToolbarItem }` | 自刻按钮列、`ZStack` overlay 伪工具列 |
| 长按操作 | `.contextMenu` | 自刻浮层 |
| 列项滑动操作 | `.swipeActions` | 自刻手势 |
| 破坏性确认 | `.confirmationDialog` / `.alert` | 自刻弹窗 |
| 搜寻 | `.searchable` 或既有 `DSSearchBar` | 网页式 search box |
| 载入 | `ProgressView` | 自刻 spinner |

设定页一律 **iOS Settings 风格**（`Form` / `List` `.insetGrouped` 分组 + section header），不要做成网页表单。

**设定列一律用 `SettingsRows`**（`Modules/SharedUI/Components/SettingsRows.swift`）：`SettingsRowLabel`（图示＋标题，与「设定」主页 `DSSettingsRow` 同一个 `IconConsistentLabelStyle`）、`SettingsValueLabel`（推页列＋右侧目前值）、`SettingsSliderRow`（标题与值一行、滑杆在下）、`SettingsLockedRow`（Pro 锁定列）。原生控制项照用，只把 label 换成这些，同一页的每一列才会是同一个图示大小、颜色与对齐。

- 同一页要嘛每列都有图示，要嘛都没有；同一个设定在不同页（例如阅读设定与排版生效范围）用同一个 SF Symbol。
- 列图示避开 SF Symbols 会换成在地化字形的符号：`textformat` 在中文会变成「格式」两个字、`textformat.size`、`character.textbox` 等同理（CoreGlyphs 里有 `.zh` 变体的都是）。`a.magnify` 也会把 a 换成「字」。字体用 `f.cursive`、字级用 `plus.magnifyingglass`。
- 列的角色：一般设定 `.standard`；点了就执行的动作（汇出、汇入、重设单一值）`.action`；会覆盖使用者一组设定或删除东西的 `.destructive`，并先用 alert 确认。
- 推进去的页面标题要和列名相同（列叫「段评气泡」，页就叫「段评气泡」）。
- 繁中用语（2026-09-28 统一）：汇入／汇出（不用导入／导出）、自订（不用自定义）、介面（不用界面）、储存（不用保存）、重设（不用重置／还原）、阅读背景（不用阅读主题）、页首页尾（不用页眉页脚）、全域（不用全局；既有功能名如「全局翻页」照旧，不自行改名）。改既有字串时**只改 zh-Hant 的值、不改 key**（例：「全局默认」＝「全域预设」），其他语系的值照各自惯例。

### 4.1 主题背景与 List/Form 背景连续性

- `.scrollContentBackground(.hidden)` 只会隐藏 `List` / `Form` 的卷动容器背景，**不会自动清除每个 row / section 的系统背景**。如果外层已绘制 `PageBackgroundView`、`themedAppSurface` 或其他主题背景，保留预设 row 背景会形成上方有色、下方纯白等意外色块断裂。
- 页面背景应连续透出时，所有内容列、section、空状态、载入状态与错误状态都必须明确使用 `.listRowBackground(Color.clear)`；不能只处理正常资料列。
- 若产品刻意让 row 与页面背景形成层级，必须明确使用 `DSColor.surface` / `DSColor.surfaceTertiary` 等语意 token。禁止依赖未指定的系统白色或只在目前 Light Mode 看起来刚好一致。
- Review 时必须同时检查 navigation bar、固定摘要区、scroll content 与所有 row 的背景是否属于同一套语意层级，并在 Light、Dark、自订主题与页面背景图片下验证。

```swift
List(items) { item in
    ItemRow(item: item)
        .listRowBackground(Color.clear) // 让 PageBackgroundView 连续透出
}
.scrollContentBackground(.hidden)
.background(PageBackgroundView(scope: .settings))
```

若 row 应为卡片层级，则改用明确语意色：

```swift
ItemRow(item: item)
    .listRowBackground(DSColor.surface)
```

Review 时同时检视 surface 层级是否「从背景中看得出」：容器色必须明显区分于页背景与兄弟容器，几乎同色的容器等于没有层级（曾发生审查没抓到、bubble 与背景同色的真实案例）。

### 4.2 区块底部说明（Section Footer）规范

- **统一原生 footer**：所有针对 Section 或整组设定的提示、说明、限制条件，一律使用原生 `Section { ... } footer: { Text(...) }`。
- **严禁自刻说明列**：严禁在 Section 内部使用普通 Row 放说明文字（会变成卡片 row 外观与过大行高）、严禁在 Toggle 的 label `VStack` 内手动塞说明文字充当区块附注、严禁单独开一个没有内容的 Section 专门放说明 Text。
- **统一字级与颜色**：Apple HIG 规范 Section footer 为 **13pt Footnote** 与 **次要颜色（`DSColor.textSecondary`）**。因为最外层环境可能注入全域字体，为避免字级被放大成 17pt 正文，所有 footer 内的 `Text` 一律呼叫 `.dsSectionFooter()`（错误/警示讯息传入 `.dsSectionFooter(color: DSColor.destructive)`）。
- **写得出理由才写 footer**：footer 只写控制项本身看不出来的事——代价、风险、副作用、不明显的前提，或这份资料从哪来。**标签已经讲完的就不要再写一次**：「重新整理名单」不需要一段说明它会重新整理名单。
- **长度上限一句，最多两句**：不要复述按钮、不要描述实作、不要解释这个功能为什么存在。动手前先问「不写这句，使用者会误会什么？」——答案是「不会」就删掉。

```swift
Section {
    Toggle(localized("自动同步"), isOn: $autoSync)
} footer: {
    Text(localized("开启后，App 启动与切到背景时会自动与云端合并同步。"))
        .dsSectionFooter()
}
.interfaceSectionSurface()
```

---

## 5. 排版与字级

- 用语义 text styles 表达层级：`largeTitle` / `title` 标题 → `headline` 区块标题 → `body` 正文 → `subheadline` / `caption` 辅助；不要用固定 pt 模拟层级。
- **支援 Dynamic Type 到最大 accessibility size**：优先让内容换行与容器增高，不以截断掩盖关键文字。
- 大字级时将 metadata（作者、来源、时间、状态）改为垂直 stacking；grid 逐步减栏，必要时降为单栏，避免压缩文字与点击区。
- 自订字体必须以语义 metrics 缩放，并在 **Bold Text** 开启时维持可辨识的粗细差异；没有原生粗体字面时提供经验证的 fallback。
- SF Symbols 跟随相邻语义字级与 Dynamic Type scaling，不用固定 frame 锁死图示；固定尺寸的 toolbar icon 是需单独验证的例外，不代表自动支援 Dynamic Type。
- 三行以上的文字避免 tight leading；正文与说明文字需保留足以扫读的行距。
- 对齐与留白胜过分隔线；分隔线只在 `List` 语义需要时出现。
- 字级数量克制：同一画面维持 ≤5 种不同字级，层级靠字重与字轴建立，不是堆叠更多尺寸；`tracking` 最多 2 种值且只用于大写标签。
- 需要字体对比时优先使用 SF 字轴（`.fontDesign(.serif)` / `.rounded` / `.monospaced`）建立层次（如标题用 serif、数值用 monospaced），不要为此引入自订字体；自订字体仍必须以语义 metrics 缩放。
- 不要用 `minimumScaleFactor` 硬缩文字救版面；让容器重排或换行。

---

## 6. SF Symbols / 视觉一致性

- 图示**优先 SF Symbols**；字重、尺寸、语意与相邻文字一致（同一列图示风格统一，不混 fill / outline）。
- 不自创不必要的 icon style；功能性图示服务「阅读、选书、搜寻、设定」，不装饰。
- 用 system colors 与 `DSColor`，不硬写网页品牌色（搜寻引擎 brand 色已有专属 token）。
- 书封缺图用 `DSColor.coverGradients` 生成渐层占位，不要空白方块。

---

## 7. 无障碍 Accessibility（阅读器必做）

每个画面都要过这份清单：
- [ ] 正文、设定项、按钮文字支援 **Dynamic Type** 到最大 accessibility size，内容仍可读、可操作。
- [ ] 所有 **icon-only 按钮** 有 `accessibilityLabel`（用 `localized`）。
- [ ] 一般互动的 **hit region** 至少 **44×44pt**。受限 compact 情境可让 **visible control** 最小为 **28×28pt**，但需以 padding / frame 扩大版面并用 `contentShape` 定义完整可点区域，同时在相邻 controls 间保留充分 spacing；28pt 不是一般 hit-target 例外，reader chrome 与 primary actions 仍维持至少 44×44pt。
- [ ] 状态与错误不是 color-only：颜色之外另有文字、图示、形状或位置提示。
- [ ] Light / Dark Mode 与 **Increase Contrast** 下皆可辨识；不要以低对比透明叠色承载必要资讯。
- [ ] **Reduce Motion** 开启时停用非必要位移、缩放与连续动画，改用 opacity 或无动画结果；实作用 `@Environment(\.accessibilityReduceMotion)` 选择动画，不能只套 `DSAnimation` token。
- [ ] VoiceOver 能依合理 order 朗读标题、内容与动作，并在储存、删除、载入或错误后说明 outcome；必要时用 announcement 或 focus 管理。
- [ ] 阅读页避免动画、透明、背景纹理干扰文字辨识。
- [ ] 纯装饰元素使用 `.accessibilityHidden(true)`；同一语意的标题、metadata 与状态适当 grouping（例如 `.accessibilityElement(children: .combine)`），但不要合并需要独立操作的控制。

### 7.1 SwiftUI 已经踩过的三个坑

这三个不是理论风险，都是实际出货后由使用者回报的 VoiceOver bug（TTS 迷你播放器与语速滑杆）：

- **accessibility modifier 加在容器上会往下传。** 套在 `HStack` / `VStack` 上的 `.accessibilityLabel`、`.accessibilityHint` 会传给底下**每一个**子元素。迷你播放器因此把封面、播放/暂停、关闭三颗按钮全部命名成书名，旁白连念三次同一个名字。→ 标在各自的 `Button` 上（见 H10）。
- **`Image(systemName:)` 预设就是可聚焦元素。** SF Symbol 自带名称，旁白会念出「speedometer」这种符号名。装饰用的图示（滑杆两端的慢/快图示、列尾自绘的 `chevron.right`）一律 `.accessibilityHidden(true)`。
  **只在 `Button` 上加 `.accessibilityLabel` 不够。** 阅读器经典底栏的换源钮就是 `Button { Image(systemName: "arrow.left.and.right") } .accessibilityLabel(localized("换源"))`，旁白仍念「arrow.left.and.right」——符号在按钮旁自成一个元素，把按钮的名字盖掉了。**icon-only 按钮要两件事一起做**：图示 `.accessibilityHidden(true)` ＋ 按钮 `.accessibilityLabel`。改用 `Label(text, systemImage:).labelStyle(.iconOnly)` 也可以，它念的是 text 不是符号名。
- **`Slider` 不会自己有语意。** 预设 label 是空的、value 是「相对于 range 的百分比」，跟画面上显示的数值对不上（语速 range 是 0.1–2.5，画面却显示 `rate / 0.5 * 100`%）。务必自己给 `.accessibilityLabel` 与 `.accessibilityValue`，且 value 与画面上那行说明文字**共用同一个计算属性**，不要各算各的。

```swift
HStack {
    Image(systemName: "tortoise")
        .accessibilityHidden(true)          // 装饰用，不进 VoiceOver
    Slider(value: $rate, in: 0.1...2.5, step: 0.05)
        .accessibilityLabel(localized("语速"))
        .accessibilityValue(speechRateText) // 与下方说明文字同一来源
    Image(systemName: "hare")
        .accessibilityHidden(true)
}
Text("\(localized("当前速度"))：\(speechRateText)")
```

---

## 8. 可用性（Nielsen 十大启发）

每个页面自问：
- **系统状态可见**：使用者知道现在在哪、在载入/成功/失败吗？
- **贴近真实世界**：用「书架/来源配置/章节/订阅」这类使用者语言，不用技术黑话。
- **使用者掌控**：返回、取消、复原清楚可达。
- **一致性**：同类操作在全 App 位置/命名/图示一致。
- **错误预防**：破坏性操作前确认；输入即时验证。
- **辨识胜于记忆**：选项可见，不要逼使用者记指令。
- **弹性效率**：常用操作有捷径（swipe、长按、Menu）。
- **美学与简约**：一页不塞太多资讯/按钮/层级。
- **错误可复原**：错误讯息说明「发生什么 + 怎么修」。
- **说明文件**：必要处提供轻量提示，不喧宾夺主。

补充准则（跨框架通用，源于外部 skill 审计，详见参考章节）：
- **权限请求**：在功能发生的当下才请求权限，绝不在启动时一起问；系统对话框前先用说明画面解释原因与用途；被拒后提供前往系统设定的路径，并设计被拒后的降级体验。
- **回馈强度匹配**：`alert` / `confirmationDialog` 只用于需要使用者决定的关键时刻（2 键为佳，最多 3 键）；非关键提示用 inline 提示、banner 或状态列呈现，不要用 alert 打断。
- **手势有替代**：任何自订手势（滑动、长按、双击）必须同时有可见的按钮或选单入口；系统手势（左缘返回、下拉通知/控制中心）不得拦截。
- **触觉与数字回馈**：重要动作（储存、删除、完成、状态翻转）给 `.sensoryFeedback`；变动中的数字用 `.contentTransition(.numericText())` 呈现；两者皆遵守 Reduce Motion。

---

## 9. 状态设计（每页必备三态）

| 状态 | 必含 | 范例 |
|------|------|------|
| **空状态 Empty** | 图示 + 一句说明 + 明确下一步 CTA | 「尚无书籍 / 汇入第一本书」按钮 |
| **载入 Loading** | `ProgressView` + 必要时骨架；长任务可取消 | 搜寻来源配置中… |
| **错误 Error** | 发生什么 + 如何修 + 重试入口 | 「载入失败：网路逾时 / 重试」 |

空状态不可只是一片空白；错误不可只 print log。可参考既有 `TTSSettingsView` 的 `emptyView`、`TTSPanelView` 的提示列写法。

- 空状态优先 `ContentUnavailableView`（iOS 17+）＋本地化 CTA。
- 长任务（TTS、下载、同步、汇入）除三态外，还需涵盖 **offline / 慢网路 / 权限被拒 / 中断恢复**：播放与同步类任务要验证完整生命周期（启动→播放/下载→暂停→背景→中断（电话/通知）→恢复→完成），恢复后进度不丢失。

---

## 10. 页面原型（Page Archetypes）

设计任一页前，先判断它属于哪种原型，套对应重点：

| 原型 | 目的 / 重点 | 关键元件 |
|------|-------------|----------|
| **书架 Library** | 最近阅读、封面、进度、分组、搜寻 | `List`/grid、进度条、`contextMenu`、`searchable` |
| **阅读器 Reader** | 文字可读性、翻页/卷动、章节、进度、亮度/字体/行距/背景 | `fullScreenCover`、底部控制列、设定 sheet |
| **发现 Discover** | 首页参照 Emby／Jellyfin：由使用者排序的栏目组成，可以跨来源聚合（「全部」），也可以只看单一来源。每一列标出出处，只显示来源自己提供的排行与数字，不捏造排行或评分；单一来源页照该来源作者的分类呈现。（2026-10-08 维护者决定；改版设计见 `Technotes/UnifiedLibrary-2026-10-08-design.md` §13。以下描述现行页面。）探索首页是一列列栏目，右上「范围」选单筛选全部、公有书库、远端书库或单一来源配置，最后是浏览器（一律显示、没有开关，使用者定 2026-10-17）；没有全域的探索设定，栏目怎么呈现由栏目自己决定（2026-10-11 维护者决定）。首页配置在右上 ••• 左边自己一颗按钮，推入「首页配置」页（使用者定 2026-10-22，照 Rex「管理配置」）：「配置列表」每列是圆形照片（每套自选、预设也能设；没照片是名称首字灰底）、名称（预设有副标）和使用中的勾，点一下切换并留在这页（切换过去的那套从首页最上面开始，2026-10-23）；右上「编辑」能把预设和自己建的一起排序（使用者定 2026-10-23），只删自己建的（预设不能删），编辑中点一列、或左滑「编辑」进照片与名称页（改名只在这里，返回或 Return 就存），左滑「删除」先确认；「从设定范本新增」有「空白模板」「预设配置」两列（带图示）：空白模板没有栏目，预设配置是 App 维护的那套预设栏目（跟新安装拿到的一样，不是复制使用者改过、甚至清空的预设，使用者定 2026-10-23），只问名称（留空叫「首页配置」、重名加数字）；没有内建的「空白」首页（使用者定 2026-10-23：旧版存过、有栏目的空白留成自己的一套，空的就拿掉）；照片存本机 `HomeConfigurationPhotos/`、不同步；「编辑首页」照参考 App：栏目变卡片、右上原生「完成」不随卷动收起、底部中间一颗 ＋ 新增栏目（取代 Tab Bar 的位置），最下面的「编辑首页」变「完成」，卡片之后没有其他卡片；进入和完成都停在首页最底下（使用者定 2026-10-17）；编辑首页、栏目名称长按和聚合设定的首页栏目都改目前这一套；旧的自订页 5d-4 起搬成首页配置（元件对应五种呈现方式），全部存在本机 `explore_home.json`；分类标题长按与分类页右上角的「加入首页配置」把分类加在那一套最后当横向单排书架；排名徽章前三名红／青／橘底白字、其余灰底；卡片走 `interfaceCardSurface`：白底，开「分组卡片」时是玻璃；按下即缩、减少动态时改淡出；来源配置页的筛选、网页连结和各处的分组／分类标签都用共用胶囊 `DSCapsuleLabel`（未选中接界面效果的玻璃、选中主题色；subheadline 中等字重，跟著动态字级），筛选写成「线路：目前值」；搜书在「搜索」分页，一个搜寻同时搜来源配置和公有书库（结果下方的「公有书库」区块；没有搜寻范围切换列，也不显示搜索范围的文字）；来源配置页直接是该源全部分类，右上角齿轮开「发现页设定」（照参考的分类筛选：每个来源配置分组一张卡片，标题照来源配置原样（☆ 排行榜 ☆，只是一条线的分隔标题改叫「分类」），分区是一列四格的胶囊 `DSCapsuleLabel(fillsWidth:onCard:)`，名称一格放不下就占两格（再长就占更多，最多一整列）、不换行；选了就只显示选中的、都不选就全部显示，「快捷操作」卡有「全部显示」、来源配置的按钮／输入框／开关（legado-E、MD3 的 button／text／toggle：点了跑来源配置的 action 脚本，值存在来源配置的 infoMap；输入框在名称后面同一行接灰色的目前值）和网页连结，连结等 sheet 收起后才开浏览器；可搜寻；存在 `discover.shownCategories.<来源配置网址>`，旧的 `discover.categorySelection.<来源配置 id>` 读一次），头像开来源配置登入页；分类标题含榜单关键词（榜、排行、热门、完本、top 等）的走竖排序号、每栏四本，其余是横滑书架；浏览器全萤幕开、照 Safari：上方只有 ✕ 回探索、没有标题，网址栏在下方（白底圆角加阴影，起始页左边是放大镜、网页时是转码键），工具列能按的键用主题色；空白时是 Safari 式起始页（书签、最近浏览的 64pt 图示格带阴影，没有图示的网站灰底白字，白色「编辑」胶囊），第一页按 ‹ 回起始页；来源配置页版面照 Apple Books 书店：区段标题本身就是「查看全部」连结（标题＋`chevron.right`），推荐分类是横向书架，榜单是可横滑的排行栏（纯数字名次，不上色） | `LazyVStack` 栏目、范围 `Menu`、`fullScreenCover`、分类 section、`scrollTargetBehavior(.viewAligned)` |
| **搜寻 Search** | 书名/作者/URL/来源配置搜寻，状态清楚（搜寻中/无结果/错误）。列表照 Apple Books 搜寻（iOS 26 截图量测）：左右 29pt、2:3 小封面（近直角＋短阴影）、旁边置中三行——书名（粗，最多两行）、作者、灰字「类型 · 几源」，没有简介、没有右侧按钮与箭头，分隔线从文字起到右边界；有声书在书名后接灰色标签（取代封面耳机徽章），第三行只写「几源」不再重复类型；英文的源数走 `en.lproj/Localizable.stringsdict` 分单复数（1 source／2 sources）。搜寻栏启用且空白时列「最近搜索」「最近阅读」：粗衬线标题＋同基线的「清除」，下方一条通栏分隔线；最近搜索是放大镜＋关键字（最多 5 笔，点了重搜），最近阅读是最近读过的 3 本（同一种书籍列）：书架上的书第三行是阅读进度、点了接著读；不在书架上的读过的书（没加书架就读／听过的线上书，或读过后从书架删掉的书）照 legado 阅读记录的做法，书照旧删、只留书名作者封面（`OffShelfReadRecords`，最多 10 笔，只有 App 自己的书库会写），第三行是多久前读的、点了用书名重新搜寻，之后加进书架就只以书架那本出现；它的「清除」只清搜寻页这份清单，不动书架的阅读纪录；「全部来源配置」那一列下面没有分隔线（iOS 26 靠列表的柔和卷动边缘）；这两区是一般列不分 `Section`（iOS 26 的 Section 会在上方多空一段、多画一条线）。搜寻进度与暂停照 App Store 下载钮：在「全部来源配置」那一列右端放圆圈（圈＝已回应比例，中间 ‖ 点了暂停、变 ▶ 再点继续），左边「18/27 · 失败 4」，搜完一起消失；全页只有这一个暂停控制，不另开灰色带、不用胶囊按钮 | `searchable`、`SearchBookListRow`（UIKit 版 `IOS17SearchResultTableCell` 同样式）、`SearchIdleContent`、`SearchProgressControl`、三态 |
| **设定 Settings** | iOS Settings 风格、分组清楚 | `Form`/`List` insetGrouped、`Toggle`/`Picker`/`NavigationLink` |
| **来源配置 Source** | 区分来源管理、测试、启用状态、错误状态 | `List` + 状态徽章 + `swipeActions` + 测试入口 |
| **详情 Detail** | 书籍资讯、章节目录、开始阅读；照 Apple Books 书店的书籍页（2026-11-12 起）：大封面置中，站在一整块封面色上（深色、白字，底色压深到文字对比足够；增加对比时更深），下面书名、作者、一行分类（放不下的收进「+N」选单）；再一张「来源卡」写目前来源（点了换源）、来源数或搜寻状态、一行格式／章数／进度，以及两颗等高的按钮：书架（「加入书架」／「已在书架」）在左、阅读（白底）在右，永远同一排。卷走后书名与主按钮缩进导览列。下半部在页面自己的底上：简介（灰字、四行、「更多」）、目录（标题可点开完整目录＋章数；线上的书列「最新」与「读到／开头」，档案列前三章，不画分隔线和箭头）、相关作品、作品资讯（粗体标签叠灰字内容）；区段之间才有细线，不用强调色 | `BookDetailComponents.swift`（两种详情页共用，不另画一份） |
| **汇入 Import** | 清楚处理本地档案 / URL / Legado 来源配置 / 剪贴簿 | `fileImporter`、分流选单、进度与结果 |
| **TTS / 听书** | 朗读控制、语音源/离线语音、章节、睡眠定时 | 控制列、`Slider`、语音选单 |
| **AI 助手 Assistant** | 针对这本书的问答：答案好读、依据可查、模型与范围随手切换 | `Modules/Features/AI/AIChatComponents.swift` 的对话元件（见 §10.1） |

### 10.1 AI 对话介面

阅读助手的对话画面参考 OpenMinis 的聊天版面，元件集中在 `AIChatComponents.swift`，新的 AI 对话画面沿用这一套，不另刻：

- **只有读者的提问用气泡**（`AIChatUserBubble`，靠尾端）；AI 回答是页面上的内文，前面一行「✦ AI 助手」标头（VoiceOver 标题），不包卡片。
- **次要资讯收进一个控制项**：回答下方只有「复制」与一个「回答范围／未附书中引用」按钮，点开才显示说明卡；不要在每则回答下堆多行提示。
- **输入框是唯一的浮动层**（`AIChatComposer`）：以 `safeAreaInset(edge: .bottom)` 浮在对话上，内含模型选单、阅读范围选单与送出钮；表面用 `floatingSurfaceBackground`（iOS 26 为 Liquid Glass），**不带光晕**——光晕在玻璃后面会把整个输入框染成主色，看起来像已聚焦、也压低 placeholder 对比。
- 选单里的单选一律用 `Picker`（附勾选）。选单不会显示 inline `Picker` 的 label，也不会显示包住它的 `Section` 标题（iOS 27 实测），所以需要分组名称时改用 `.menu` 样式的子选单：模型选单只有一个服务时 inline 列出模型，多个服务时每个服务一个以服务名称命名的子选单。
- `DisclosureGroup` 只用在 `List`/`Form` 里。放在一般 `VStack` 时，展开内容的多行 `Text` 会置中排列成倒三角形。
- **AI 批次工作先确认再送出**：「整理已读人物」「全书与分卷摘要」这类会分批传送正文的功能，开始前一律列出服务、模型与预计模型呼叫次数让读者确认；只处理已读且本机有正文的章节；离开页面或退到背景就暂停，已完成的部分保留；用完确认的次数就停下，再次确认才继续。
- **AI 入口的位置**：经典阅读器顶部的三横线选单放「AI 助手」「AI 翻译」，线上书再加「书籍详情」；经典底部的圆钮只留刷新／换源／下载／听书。Apple Books 的「AI 助手」是选单的第五排（目录、书签、搜寻、主题与设定之后），「AI 翻译」留在下方按钮列；该列一次最多四颗，超过改成横向卷动，从尾端（听书）开始显示。现代介面维持在书卡里。
- **AI 全部属于阅读Pro**（`PremiumFeature.aiReading`，是否可用一律问 `ReaderPremiumVisibilityPolicy.allowsAI`）。没有 Pro 时只留上面这些顶部入口、书架选单的「AI 整理书架」和设定的「AI 助手设定」：选单列换成锁头并加副标「需要 Pro」，Apple Books 那一排用 `ProLockBadge`，设定列是「需要 Pro」＋列尾锁头（`DSSettingsRow(isLocked:)`，同外观的「启动图」），点了都开付费页；选字选单不放 AI 项目，Apple Books 下方列不放 AI 翻译。会开 sheet 的选单项目在 iOS 17 走 `DismissalSequencedActionChooser`（见 `Technotes/iOS17MenuModalPresentation.md`）。
- **AI 设定类页面只往下一层**：「书中人物」是入口页，底下的「整理已读人物」「人物卡与朗读别称」不再互相连结，也不连回「AI 状态与诊断」（它在 AI 面板的「更多」里）。批次数、UTF-16、token 这类帐面数字收进「详细资料」`DisclosureGroup`；互斥的查看范围用一个 `Picker`，不用两个 `Toggle`。

### 10.2 付费页与 Pro 入口

- **Pro 功能没 Pro 也看得到，上锁**：在会用到它的地方照常显示，列尾「需要 Pro」＋锁头，选单列用锁头图示＋副标「需要 Pro」（按钮 label 直接放两个 `Text`），点了开付费页并带上对应的 `PremiumFeature`。不要整块藏起来——没看过的功能没人会买。唯一例外是选字选单：不放 AI 项目，免得每次划线都看到付费项目。已产生的资料（字体、笔记、主题）过期后照常可用，只锁入口。
- **付费页由上而下**：情境标题（从哪个功能点进来就讲哪个，`PremiumPitch`）＋那一类的示意图（`PaywallShowcase`）→ 方案 → 三大类好处（`PremiumPillar`，点进来的那类排第一）→ 恢复购买与条款；购买按钮用 `safeAreaInset` 固定在底部，按钮上写价格，下面一行回答那个方案最常见的顾虑。
- **诚实**：没有真实数据就不放评价、使用人数；不写「开发中、敬请期待」；AI 那一类注明要用自己的 AI 服务金钥。永久会员的划算用月费换算（`PaywallPricing`），不虚构原价。
- 付费页从 sheet 里的控制项开启时，iOS 17 交给第一层呈现者（先关 sheet，从它的 `onDismiss` 开）；从选单开启则等选单真的消失。见 `Technotes/iOS17MenuModalPresentation.md`。
- **阅读Pro 只有一页**：设定的「阅读Pro」列永远开付费页；那一列用 App 图示（`AppIconImage`），副标没 Pro 讲「解锁 AI 阅读助手与高级个人化」，有 Pro 依方案说「永久会员／已订阅」——永久不是订阅。没 Pro 看到方案；有 Pro 就是它的会员页（`PaywallMemberPage`）：目前方案、月费用户的「升级为永久会员」与管理订阅、恢复购买，三大类用同一套卡片标成已解锁（`PaywallPlanCard`、`PaywallPillarList` 两边共用）。不要另做状态页——买完点进去换成另一种长相的页面，看起来像两个产品。
- **购买成功是最该记住的一刻**：同一个会员页当谢谢页——页首是 App 自己的图示（`AppIconImage`，素材 `YueduAppIcon` 深色模式用黑底版；Pro 的识别一律用 App 图示，不用皇冠之类的 SF Symbol），图示弹出＋两圈同形状的光圈＋一阵彩纸约 2 秒（时间轴随最后一片结束）、成功触觉、VoiceOver 播报「已解锁 阅读Pro」；方案卡附价格当收据；底部固定「开始使用」，关掉回到原处，刚才点的功能已经解锁。只在付费页开著时刚解锁才出现（购买、延后核准、兑换码、恢复购买、月费升级永久都算）；减少动态效果时只淡入、不洒彩纸。月费升级永久一定要提醒取消月订阅。

---

## 11. 阅读器专属约束（Reading-first）

- 正文可读性最高优先：字体、行距、字距、边距、背景对比可调，且预设舒适。
- 阅读页 chrome（工具列/控制列）**可隐藏**，点击唤出；沉浸时不干扰。
- 翻页/卷动动画要稳定、不弹跳；位置以 `(spineIndex, charOffset)` 为准（见 CLAUDE.md）。
- 背景纹理/透明度不得降低文字对比；深色模式有专属阅读背景，不直接拿系统色硬套。
- **深色模式是阅读器自己的状态**（`GlobalSettings.readerDarkMode`）：三种阅读介面都有「深色／白天」——经典、现代在工具列，Apple Books 是选单最后一排（点了不收选单）。按钮的图示和文字读这个状态，不读背景是不是黑色。没开「绑定阅读主题」时自订背景一律属于浅色模式、深色模式是黑色；开了之后浅色／深色阅读主题各管一个模式。「跟随装置深浅色」只在绑定时显示，手动切到跟装置相反的模式会自动关掉。
- 朗读（TTS）高亮以「段」为单位与正文同步，不闪烁。
- 中断恢复：TTS 播放与下载任务在背景、电话、通知中断后恢复时，保持章节与进度不丢；阅读位置一律以 `(spineIndex, charOffset)` 恢复（见 CLAUDE.md）。

---

## 12. 设计产出检查清单

动手前先写一句**设计方向**（产品对象、主要使用者流程、视觉语言、「使用者最常做的一件事」），再进入以下产出。

每次提出 UI 设计或实作，输出必含：
1. **页面目的**（属于哪种原型）
2. **资讯架构**（主要区块与层级）
3. **iOS 元件选型**（为何选这些原生元件）
4. **互动流程**（进入 → 操作 → 结果 → 返回）
5. **空 / 载入 / 错误** 三态（长任务另涵盖 offline / 权限被拒 / 中断恢复，见 §9）
6. **深色模式** 注意事项
7. **无障碍**（Dynamic Type / VoiceOver / 点击区 / 对比）
8. **SwiftUI 实作建议**（依 §2 选择情境正确的 title mode，并使用 `DS*` token、`localized()`）
9. **使用者模拟走查**：以三种视角各走一遍流程——主要目标使用者、受限使用者（最大 Dynamic Type / VoiceOver / 单手）、边缘资料使用者（超长书名、空书架、坏档）——再判定画面完成。
10. **渲染证据**：以模拟器/真机截图验证各状态与断点（三态、深色、最大字级、长本地化字串、键盘弹出），不只依赖代码审查。
11. **可持久修复**：重复出现的设计失败要沉淀回本文件或检查规则，不要每次当新问题重讲。

---

## 13. 禁止事项

- ❌ 做成网页 UI（后台、Landing、Dashboard、Tailwind 风格）。
- ❌ 大面积 dashboard 卡片墙 / 不符 iOS 情境的侧边栏、浮动按钮。
- ❌ 把所有功能塞进同一页。
- ❌ 为了好看牺牲正文可读性。
- ❌ 忽略 iOS 导航 / 返回 / Sheet / Tab Bar 惯例。
- ❌ 写死颜色/字体/间距（绕过 `DS*` token）。
- ❌ 写死字串（绕过 `localized()`）。
- ❌ 在非主界面根目录层级使用 `rootTabTitle(_:onScroll:)`；使用 `.inlineLarge`（iOS 17 的 iPhone 只画成 `.inline`）、`.automatic`、`.large` title mode。
- ❌ 用 `ScrollView`+`VStack`/`HStack` 自刻 list / Form row、自刻 toolbar 或按钮列、自刻 Toggle / Picker / 弹窗（见 §4）。
- ❌ 互斥选项做成多个独立 `Toggle`（该用单一选取值的 `Picker` / 单选）；`Toggle` 用内建 label，不要 `.labelsHidden()` + 手刻 HStack。
- ❌ 过度装饰卡片：22pt+ 圆角、装饰性渐层/边框、自订 Divider；卡片分层用语意表面色与 `DSRadius`（见 §4.1）。
- ❌ 全萤幕 blocking spinner（用骨架或内嵌 `ProgressView`，长任务可取消）。
- ❌ 启动时一次请求所有权限（见 §8）。
- ❌ 用 `minimumScaleFactor` 缩字救版面（见 §5）。

---

## 参考

- Apple Human Interface Guidelines — https://developer.apple.com/design/human-interface-guidelines/
- HIG Toolbars — https://developer.apple.com/design/human-interface-guidelines/toolbars
- HIG Sheets — https://developer.apple.com/design/human-interface-guidelines/sheets
- HIG Accessibility — https://developer.apple.com/design/human-interface-guidelines/accessibility
- HIG Layout — https://developer.apple.com/design/human-interface-guidelines/layout
- HIG Typography — https://developer.apple.com/design/human-interface-guidelines/typography
- Apple Design Resources — https://developer.apple.com/design/resources/
- SF Symbols — https://developer.apple.com/sf-symbols/
- SwiftUI `toolbarTitleDisplayMode(_:)` — https://developer.apple.com/documentation/swiftui/view/toolbartitledisplaymode(_:)
- SwiftUI `ToolbarTitleDisplayMode.inlineLarge` — https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode/inlinelarge
- Nielsen 10 Usability Heuristics — https://www.nngroup.com/articles/ten-usability-heuristics/
- 本专案设计 token：`Modules/SharedUI/DesignSystem/DesignTokens.swift`
- 在地化规则：见 `yuedu-tour` skill 的 Localization 章节

### 外部设计 skill 参考（知识交叉比对，非本专案规则来源）

社群 app UI/UX agent skill 的**可操作准则已提炼并整合进本文件**（§4/§5/§8/§9/§11/§12/§13）；下表是来源与适用范围，作为设计决策的交叉比对与灵感来源。任何冲突仍以 [Apple] > [Yuedu] > [建议] 为准（见 §0）。星数为 2026-08 查询时约略值。

| Skill | 说明 | 适用 |
|-------|------|------|
| [razor-ai/platform-design-skills](https://github.com/razor-ai/platform-design-skills) | 官方 Apple HIG / Material 3 / WCAG 2.2 浓缩成 300+ 条规则，附 Apple HIG PDF | SwiftUI / UIKit / Compose / Web |
| [dickwu/apple-design-skill](https://github.com/dickwu/apple-design-skill)（57★） | Apple HIG 通用化设计审查与改进，53 份指南，框架无关 | Flutter / SwiftUI / RN / Electron |
| [arjitj2/swiftui-design-principles](https://github.com/arjitj2/swiftui-design-principles)（15★） | SwiftUI 原生感抛光原则（间距系统、语意色、原生分组、NavigationStack） | SwiftUI |
| [hamen/material-3-skill](https://github.com/hamen/material-3-skill)（1235★） | MD3 token / 元件 / theming / 10 类审计，次级支援 Flutter | Jetpack Compose / Flutter |
| [flutter/skills](https://github.com/flutter/skills)（2627★，官方） | Flutter 官方 agent skills（响应式布局、测试、本地化等 workflow） | Flutter |
| [SwiggitySwerve/ux-toolkit](https://github.com/SwiggitySwerve/ux-toolkit) | 25 个通用 UX skill（Nielsen、WCAG、页面型态审查），支援 OpenCode | 通用（任何框架） |
| [AjnasNB/mobile-app-ux-auditor-skill](https://github.com/AjnasNB/mobile-app-ux-auditor-skill) | 行动 app UX 审计（导航、三态、无障碍、平台适配），含静态扫描 | Flutter / RN / Swift / Compose |
| [vermont42/iOS-Design-Agent-Skill](https://github.com/vermont42/iOS-Design-Agent-Skill)（8★） | iOS/SwiftUI 反-slop 审美审查（排版、色彩、空间、动态、深度） | SwiftUI |
| [weiping/ixd-design-skill](https://github.com/weiping/ixd-design-skill) | 互动设计 8 阶段流程（IA→流程→页面规格→原型→交付） | 通用（产品设计流程） |
| [EnchStyle/ui-ux-audit-skill](https://github.com/EnchStyle/ui-ux-audit-skill) | 15 类别评分制 UI/UX 审计（含防 AI 常见失败与三态检查） | 通用（web / mobile） |
