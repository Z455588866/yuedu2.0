# 模组开发文件

模组是一个 JSON 档：它告诉「阅读」去哪个网站拿书单、怎么搜寻、怎么用 ISBN 补资料、怎么一章一章读。
它**不执行 JavaScript**，只用规则引擎的规则（CSS、XPath、JSONPath、正则，和 `||` `&&` `%%` `##`），
所以汇入前就能完整检查：哪个栏位有问题，汇入画面会直接说。

App 内建的官方模组（`Resources/Assets/official-module-<id>.json`）跟你写的模组是**同一种档案、同一个验证器**，
官方模组做得到的，你的模组也做得到。下面的范例都取自这些档案：

| 档案 | 示范 |
|------|------|
| `official-module-narou.json` | 排行清单、`offset` 分页、搜寻、`reading`（在 App 内读书）、`singleChapter` |
| `official-module-bangumi.json` | POST + `bodyEncoding: json`、`tags`、`aliases`、`excludeTags`、`contentKind` |
| `official-module-anilist.json` | GraphQL（POST JSON）、`localizations` |
| `official-module-openbd.json` | `lookup`（以 ISBN 补资料）、`isbnPrefixes` |

本文件有测试把关（`ModuleFormatDocumentationTests`）：格式多了栏位而这里没写，测试就会失败。

---

## 1. 最小的模组

```json
{
  "id": "example.newbooks",
  "title": "新书速报",
  "version": "1.0",
  "hosts": ["example.com"],
  "modules": [
    {
      "id": "new",
      "title": "新书",
      "request": { "url": "https://example.com/new.html" },
      "list": { "items": "li.book", "title": "h3@text", "url": "a@href" }
    }
  ]
}
```

加入方式：资源库 ••• → 新增模组（从网址／从档案／从剪贴簿），或 `yuedu://module?src=<网址>` 连结，
或设定 → 来源配置管理 → 模组 → 右上角。加入前会先显示模组的作者、清单和**会连线的网站**，按 ✓ 才写入。

---

## 2. 顶层栏位

| 栏位 | 必填 | 说明 |
|------|------|------|
| `id` | ✓ | 代号，只能用 `A-Z a-z 0-9 . _ -`，最长 128 字。它是模组资料夹的名字，也是更新时认同一个模组的依据。官方模组的代号（`bangumi`、`anilist`、`openbd`、`openlibrary`、`narou`、`trends`、`zlibrary`、`rakuten-books`）不能用。 |
| `title` | ✓ | 名称。 |
| `description` |  | 一两句说明，显示在模组页和仓库列表。 |
| `author` |  | 作者。 |
| `site` |  | 网站首页，显示在模组页。 |
| `version` | ✓ | 数字点分版本（`1.0`、`1.2.10`）。「检查更新」只接受比已安装的**更高**的版本。 |
| `requiredVersion` |  | 能读这个档案的最低 App 版本。用到 3.0 栏位（见 §8）时至少要写 `3.0`。 |
| `hosts` | ✓ | 模组**唯一**能连线的主机名称。每个 `request.url` 的主机都必须列在这里，封面也只从这些主机载入。HTTP 转址和页面 `<head>` 里的 `<meta http-equiv="refresh">`（GET 才跟、只跟一次）也只会跟到这些主机；转到别的主机时就照原页读，封面则当作没有封面。写成 `*.archive.org` 的项目只放行**转址**：那个网域本身和它底下所有主机（Open Library 的封面会转到 `iaNNNNNN.us.archive.org`），`request.url` 不能直接连；至少两段（`*.org` 会被拒绝）。3.0。 |
| `rateLimit` |  | 请求频率，跟来源配置的 `concurrentRate` 同语法：`1/1000` 是每 1000 毫秒 1 次。 |
| `modules` | ✓ | 清单（§3），可以是空阵列；最多 50 个。 |
| `search` |  | 搜寻（§3，没有 `id`），会加进统一搜寻。 |
| `lookup` |  | 以 ISBN 查一本书（§5），用来补资料。3.0。 |
| `reading` |  | 怎么读它的书（§6）。没有它，模组的书只有资料、不能读。3.0。 |
| `reviews` |  | 读者对一本书的评论和评分（§5.2），显示在作品详情的「读者评论」。3.0.1。 |
| `detail` |  | 打开这个模组的书时，那本书自己的页面（§5.3）：补清单没给的简介和标签。3.0.2。 |
| `related` |  | 网站列的相关作品（§5.4），显示在作品详情的「相关作品」。3.0.2。 |
| `genre` |  | 一个分类的书（§5.5）：作品详情点这个模组的书的分类时打开。3.0.2。 |
| `attribution` |  | 网站条款要求的署名（§7）。3.0。 |
| `icon` |  | 模组图示的网址，主机必须在 `hosts`，不能用 `{{…}}`。显示在资源库的模组卡片、模组页、选择内容来源和搜寻来源清单；没有或读不到时用大家共用的拼图符号。3.0.2。 |
| `globalParams` |  | 整个模组的参数（§3.1，写法相同），读者在模组页的「设定」改一次。清单、搜寻、`lookup`、`detail`、`reviews` 的请求都能用 `{{name}}` 取它（`reading` 的页面不带）。只能是 `input`、`count`、`enumeration`、`constant`，不能 `followsLanguage`；名称不能跟任何清单的参数相同，也不能是 `page`、`offset`、`keyword`、`isbn`、`id`、`url`、`tag`。3.0.2。 |
| `localizations` |  | 其他语言的名称和说明（§7）。3.0。 |

`modules`、`search`、`lookup` 至少要有一个，不然会被拒绝（「模组没有任何清单」）。
档案最大 256 KB。

---

## 3. 清单（`modules[]`、`search`）

| 栏位 | 必填 | 说明 |
|------|------|------|
| `id` | 清单 ✓ | 清单代号，同一模组内不能重复；`search` 没有 `id`。首页栏目用它记住是哪个清单。 |
| `title` | 清单 ✓ | 清单名称。 |
| `description` |  | 说明。 |
| `cacheDuration` |  | 秒数：这段时间内同一页直接用快取，不再请求。模组的 `version` 一变，旧版规则抓的快取就不再使用。 |
| `params` |  | 参数（§3.1）。 |
| `request` | ✓ | 请求（§3.2）。 |
| `list` | ✓ | 从回应取出书的规则（§3.3）。 |
| `contentKind` |  | `text`（预设）或 `comic`：整个清单是漫画。3.0。 |
| `excludeTags` |  | 这个网站的 `tags` 里不算题材的字（如 `漫画`、`单行本`），使用标签时排除。3.0。 |
| `isbnPrefixes` |  | 只用在 `lookup`（§5）。3.0。 |
| `detail` |  | 只用在 `search` 和 `lookup`：那本书自己的页面，补清单没给的简介或标签（§5.1）。3.0。 |
| `minKeywordLength` |  | 只用在 `search`：关键字至少几个字才送出（Open Library 是 `3`）。更短的不送：搜寻时这个模组不出现，补资料时也不用书名查。3.0。 |
| `searchesAuthors` |  | 只用在 `search`：写 `true` 表示关键字可以是作者名、会搜出这位作者的书。作品详情的「作者其他作品」会用作品的第一位作者搜一次，只留作者相同的结果。不写就只用书名搜。3.0.1。 |

### 3.1 参数 `params[]`

| 栏位 | 必填 | 说明 |
|------|------|------|
| `name` | ✓ | 在 `request` 里写成 `{{name}}`。 |
| `title` |  | 首页栏目设定画面显示的名称。 |
| `type` | ✓ | 见下表。 |
| `description` |  | 说明。 |
| `value` |  | 预设值。数字会读成文字。`page`／`offset` 参数的 `value` 是**第一页的位置**（整数，3.0）；不写时 `page` 从 1、`offset` 从 0 开始。 |
| `enumOptions` | `enumeration` ✓ | 选项阵列：`{ "title": "显示名称", "value": "送出的值" }`。选项可以加 `language`（语言标签，3.0），见下方「跟随语言」。 |
| `followsLanguage` |  | 只用在 `enumeration`：`true` 时，读者没选过就用读者「中继资料语言偏好推荐」那个语言的选项。3.0。 |
| `belongTo` |  | 只在另一个参数是某些值时才显示：`{ "paramName": "sort", "value": ["genre"] }`。`paramName` 必须是同一份清单（或同在 `globalParams`）的另一个参数，不能指回自己或绕成一圈。藏起来时送它的预设值，不送读者之前填的。3.0.2。 |
| `placeholders` |  | 只用在 `input`：建议值阵列 `{ "title": "显示名称", "value": "填入的值" }`，栏位旁的选单点了就填入。3.0.2。 |

| `type` | 意思 |
|--------|------|
| `input` | 读者在栏目设定里自己输入。 |
| `count` | 数字。 |
| `constant` | 固定值。 |
| `enumeration` | 从 `enumOptions` 选一个。 |
| `page` | 分页页码，卷到底时自动加一。 |
| `offset` | 分页位移，每次加上一页的笔数。 |

**跟随语言**：`followsLanguage` 的参数，选项的语言是它的 `language`，没写就是 `value`（例如 `zh-Hant`、`en`）。
App 先找语言完全相同的选项，再找同一语言其他文字或地区的（`zh-Hans` 代替 `zh-Hant`）；都没有就用 `value`，再没有就用第一个选项。
栏目设定的选单第一项是「跟随中继资料语言偏好推荐」，读者选了其他选项后也能选回来。

```json
{ "name": "region", "title": "地区", "type": "enumeration", "followsLanguage": true, "value": "en",
  "enumOptions": [{ "title": "华语（繁）", "value": "zh-Hant" }, { "title": "日本", "value": "ja" },
                  { "title": "英语", "value": "en" }] }
```

`{{page}}`、`{{offset}}` 不必宣告就能用；`search` 另外可用 `{{keyword}}`，`lookup` 可用 `{{isbn}}`。
其他 `{{…}}` 都必须是宣告过的参数，否则拒绝。

### 3.2 请求 `request`

| 栏位 | 必填 | 说明 |
|------|------|------|
| `url` | ✓ | `http://` 或 `https://`，主机必须在 `hosts`。主机不能由参数组成（`https://{{site}}/` 会被拒绝）。不支援 Legado 的 `url,{…}` 选项尾巴——方法、内容、标头各写在自己的栏位。 |
| `method` |  | `GET`（预设）或 `POST`。 |
| `body` |  | POST 内容，可用 `{{…}}`。 |
| `headers` |  | 标头物件，值可用 `{{…}}`。 |
| `charset` |  | 回应编码（如 `gbk`），不写就照回应自己说的。 |
| `bodyEncoding` |  | `form`（预设，百分号编码）或 `json`（值会照 JSON 字串跳脱），例如 `{"keyword":"{{keyword}}"}`。3.0。 |

### 3.3 取书规则 `list`

每个值都是一条规则；`items` 先选出每一本书，其余规则都在那一本的范围里读。

| 栏位 | 必填 | 说明 |
|------|------|------|
| `items` | ✓ | 每一本书。 |
| `title` | ✓ | 书名。 |
| `author` |  | 作者。规则读到好几个值（例如 JSON 阵列）时是好几位作者，最多 5 位。 |
| `cover` |  | 封面网址（只从 `hosts` 载入）。 |
| `intro` |  | 简介。 |
| `url` |  | 书的网址。有 `reading` 时是书的目录页。 |
| `kind` |  | 分类。 |
| `language` |  | 语言。 |
| `aliases` |  | 其他书名（可多个值）。3.0。 |
| `tags` |  | 题材、标签（可多个值）。3.0。 |
| `publisher` |  | 出版社。3.0。 |
| `isbn` |  | ISBN-10 或 -13；检查码不对的会被丢掉。可以读到好几个值（一个版本的 ISBN-10 和 -13），`lookup` 时任一个跟书架那本相同就算；搜寻结果最多留 5 个。网站把几个 ISBN 写在同一个值里（`9787309138856,7309138856`，用 `,` `;` `/` `|` 隔开）也会分开读。3.0。 |
| `series` |  | 系列。3.0。 |
| `seriesCovers` |  | 同系列其他册的封面网址（可多个值），照系列顺序排在这一笔后面：这一笔代表整个系列（趋势用系列第一册）。作品详情把它们扇形叠在封面后面，最多 4 张。只从 `hosts` 载入。这一笔本身就是整个系列时（书名就是系列名）可以不给 `series`。3.0。 |
| `contentKind` |  | 读到 `comic` 时这本是漫画，其他值照清单的 `contentKind`。3.0。 |
| `id` |  | 这笔纪录在网站上的代号。有些网站查评论用的是代号、不是书的网址；`reviews` 的请求用 `{{id}}` 取它（§5.2）。3.0.1。 |
| `volumes` |  | 这一笔代表一个系列时，系列里的每一册（含这一笔自己那一册），照系列顺序。写一条在这一笔里面选出各册的规则（例如 `$.volumes[*]`），每一册再用这份 `list` 自己的规则读（`title`、`author`、`cover`、`url`…）。有 `volumes` 的卡片点下去先开系列页、列出各册；有 `url` 的那一册可以点进去当成一部作品，没有的只列出书名和封面。最多 60 册；一册里面再写的 `volumes` 不读。3.0.1。 |

规则里的 `{{…}}` 只能放一条规则（例如 `https://ncode.syosetu.com/{{$.ncode}}/`），由规则引擎就地读出；
不能放参数。

---

## 4. 不允许的写法

验证器会拒绝，并在汇入画面说出是哪个栏位：

- `@js:`、`<js>…</js>`、`{{ }}` 里的 JavaScript —— 模组不执行 JavaScript。
- `@get:`、`@put:` —— 模组没有变数。
- 没宣告的 `{{…}}`。
- `request.url` 连到 `hosts` 没列的主机，或主机由参数组成。
- 非 `http`／`https` 网址、Legado 的 `,{…}` 网址选项。
- `GET`／`POST` 以外的方法。
- 不认得的 `type`、`contentKind`、`bodyEncoding`、`localizations` 语言标签。
- 清单代号重复、超过 50 个清单、档案超过 256 KB。
- 用了 3.0 栏位但 `requiredVersion` 低于 `3.0` 或没写。
- `requiredVersion` 比使用者的 App 版本新（会请使用者更新 App）。

---

## 5. 以 ISBN 补资料 `lookup`

书架上的书有 ISBN、但缺封面、简介或出版社时，「阅读」会用 `lookup` 查。
`lookup` 是一个清单（§3），另外：

- `request.url` 或 `request.body` 必须含 `{{isbn}}`。
- `list.isbn` 必填：回应里的 ISBN 要跟书架那本一致才采用。
- `isbnPrefixes`：网站有的 ISBN-13 前缀（openBD 是 `9784`）。其他书的 ISBN **不会离开装置**。

可以补的栏位：`cover`、`intro`、`publisher`、`series`、`tags`、`aliases`。模组的 `search` 也会用书名补资料。
使用者在 设定 → 聚合设定 → 资料来源 取消勾选就不会用它补资料（搜寻在同一页的「搜寻来源」），或在模组页按「停用」整个关掉。

### 5.1 书的详情页 `detail`

有些网站的搜寻结果没有简介，要再开那本书自己的页面才有（Open Library 的简介在 `/works/<编号>.json`）。
`search` 或 `lookup` 可以加 `detail`：

```json
"detail": {
  "request": { "url": "{{url}}.json" },
  "intro": "$.description.value||$.description",
  "tags": "$.subjects[*]"
}
```

- `request` 跟 §3.2 一样，但只能用 `{{url}}`：那笔结果的 `url`（所以 `list.url` 必填）。
  放在网址开头时照原样代入，放在其他地方会百分号编码。代入后的网址一样只能连到 `hosts`。
- `intro`、`tags`：在详情页上直接读的规则（没有 `items`），至少要有一个。
- 只在补资料时、而且只对确定是那本书的那一笔结果请求一次，不会每一列都开；
  清单已经给了简介和标签、或书架那本不缺这两项时就不请求。
- 首页清单（`modules[]`）不能用 `detail`。旧版 App 会忽略它，只是补不到这两项。

### 5.2 读者评论 `reviews`

作品详情打开时，「阅读」会问模组有没有这本书的评论，有就在简介和目录下面显示「读者评论」，
点标题进去看全部。**只画网站有给的东西**：没有 `rating` 规则的评论不画星星，没有 `title` 就没有标题，
没有评论（或请求失败）整个区段不出现。

```json
"reviews": {
  "request": { "url": "https://example.com/api/books/{{id}}/reviews?limit=100" },
  "cacheDuration": 86400,
  "ratingScale": 10,
  "list": {
    "items": "$.reviews[*]",
    "text": "$.content",
    "title": "$.headline",
    "author": "$.user.name",
    "date": "$.created_at",
    "rating": "$.score",
    "likes": "$.helpful"
  },
  "rating": {
    "score": "$.summary.average",
    "count": "$.summary.total",
    "distribution": "$.summary.stars[*]"
  }
}
```

| 栏位 | 必填 | 说明 |
|------|------|------|
| `request` | ✓ | 跟 §3.2 一样，但只能用 `{{id}}`（那笔纪录的 `list.id`）和 `{{url}}`（它的 `list.url`），至少要用一个。`{{url}}` 放在网址开头时照原样代入。代入后的网址一样只能连到 `hosts`。 |
| `cacheDuration` |  | 秒数：这段时间内同一本书直接用上次的结果，「没有评论」也算。建议设一天以上，否则每次打开作品详情都会请求。 |
| `ratingScale` |  | 网站的评分满分是多少（Bangumi 是 `10`），预设 `5`。App 一律换算成五颗星显示。 |
| `list` | ✓ | 每一则评论的规则，见下表。 |
| `rating` |  | 这本书的整体评分，在同一页上直接读（没有 `items`），见下表。 |

`list`：

| 栏位 | 必填 | 说明 |
|------|------|------|
| `items` | ✓ | 每一则评论。想排除「回复别人的留言」就在这里筛掉。 |
| `text` | ✓ | 内文。会转成纯文字，最长 2000 字；空的那一则略过。 |
| `title` |  | 评论自己的标题。 |
| `author` |  | 写的人，照网站显示的名称。 |
| `date` |  | 日期：`2025-01-02 15:43:23`、ISO 8601、`2025-01-02`，或 1970 年起的秒数（毫秒也可以）。读不懂的格式就不显示日期。 |
| `rating` |  | 这位读者给的分数，数字，满分是 `ratingScale`。0 当作没评分。 |
| `likes` |  | 多少人觉得有帮助，数字。有的话评论页可以依「最有帮助」排序。 |

`rating`：

| 栏位 | 必填 | 说明 |
|------|------|------|
| `score` | ✓ | 平均分，数字，满分是 `ratingScale`。 |
| `count` |  | 评分人数。 |
| `distribution` |  | 每一种星数各有几人，**五个值、五星在前**。不是刚好五个值就不画分布条。 |

**哪一本书**：模组必须有 `search` 或 `lookup`，而且其中至少一个读得到请求用到的 `{{id}}`／`{{url}}`。
App 照这个顺序找纪录：

1. 这本书本来就是从这个模组开的：直接用那一笔。
2. 书架那本有 ISBN：用 `lookup` 查，ISBN 相同的那一笔。
3. 用书名搜 `search`：书名（或 `aliases`）相同、作者相容、同一种内容的结果，**最多前 3 笔**，评论合在一起
   （同一本书的不同版本或不同上传）。没有作者的书不搜：只有书名不足以认定是同一本。

一次最多留 100 则。使用者在 设定 → 聚合设定 → 资料来源 取消勾选这个模组，或在模组页按「停用」，就不会问它。
请在模组的 `description` 写明：打开作品详情时会把 ISBN 或书名送到你的网站。

### 5.3 打开一本书 `detail`（顶层）

点开这个模组列出的书时，「阅读」会用顶层的 `detail` 读那本书自己的页面，补上清单没给的简介和标签
（Forward 的 `loadDetail`）。跟 §5.1 写法一样，另外：

- `request` 必须用 `{{url}}`（那本书的 `url`，所以至少一份清单要有 `list.url`），也可以用 `globalParams`。
- `cacheDuration`：秒数，这段时间内同一本书直接用上次读到的。只有顶层的 `detail` 读它。
- 只问「从这个模组打开的那一本」，每次打开一次；请求失败就照清单给的显示。

### 5.4 相关作品 `related`

```json
"related": {
  "request": { "url": "https://example.com/api/books/{{id}}/related" },
  "cacheDuration": 86400,
  "list": { "items": "$.works[*]", "title": "$.title", "author": "$.author", "cover": "$.cover", "url": "$.href" }
}
```

| 栏位 | 必填 | 说明 |
|------|------|------|
| `request` | ✓ | 跟 `reviews` 一样：只能用 `{{id}}`、`{{url}}`（至少一个）和 `globalParams`。 |
| `cacheDuration` |  | 秒数：这段时间内同一本书直接用上次的结果。 |
| `list` | ✓ | 每一部相关作品，跟 §3.3 的规则一样（`items`、`title` 必填）。 |

找「哪一本书」的方式跟读者评论（§5.2）相同。最多 30 部；那本书自己会被拿掉；网站没给就整区不出现。

### 5.5 分类 `genre`

作品详情会把这个模组的书的 `tags` 列成可以点的分类。点了打开一页，列出这个模组那个分类的书：

- 有 `genre`：它是一份清单（§3，没有 `id`），`request` 必须用 `{{tag}}`（分类的文字），可以有 `page`／`offset` 分页。
- 没有 `genre`：用模组的 `search` 搜这个词（关键字太短、不到 `minKeywordLength` 的不搜）。
- 两个都没有：分类只显示、不能点。

---

## 6. 在 App 内读书 `reading`

有 `reading` 的模组，书可以加进书架、一章一章读（`official-module-narou.json`）。
清单里书的 `url` 是目录页。

| 栏位 | 必填 | 说明 |
|------|------|------|
| `headers` |  | 每一页都带的标头（如 `User-Agent`），不能用 `{{…}}`。 |
| `charset` |  | 页面编码。 |
| `toc` | ✓ | 目录规则，见下表。 |
| `content` | ✓ | 内文规则，见下表。 |

`toc`：

| 栏位 | 必填 | 说明 |
|------|------|------|
| `items` | ✓ | 每一章（或卷名）。 |
| `title` | ✓ | 章名。有章名没网址的是卷名。 |
| `url` | ✓ | 章节网址。 |
| `nextPage` |  | 目录下一页的网址；空了、重复了、或读满 300 页就停。 |
| `singleChapter` |  | 只有「整本只有一章」的页面才对得上的规则（なろう的短篇：`.p-novel__body`）。先检查它：一本书只有在页面这么说时才算单章，不会因为目录读空就当成单章。 |

`content`：

| 栏位 | 必填 | 说明 |
|------|------|------|
| `text` | ✓ | 内文，保留 HTML（`@html`），跟来源配置的正文规则一样。 |
| `title` |  | 章名。 |
| `nextPage` |  | 一章分好几页时的下一页。 |

---

## 7. 署名与多语言

`attribution`：网站条款要求的署名，显示在模组页。

| 栏位 | 必填 | 说明 |
|------|------|------|
| `text` | ✓ | 照网站的写法，例如 `Supported by Rakuten Developers`。 |
| `url` |  | 署名连结，`http`／`https`。 |

`localizations`：以语言标签（`en`、`zh-Hans`、`ja`）为键，值可以有 `title`、`description`，
以及 `entries`（以清单 `id` 为键，各自的 `title`、`description`）。App 用相同语言和文字（繁／简）的那一份，
没有就照原文：`zh-Hans` 不会代替 `zh-Hant`，`en` 也不会代替其他语言。`entries` 的键必须是存在的清单 `id`。

清单的参数也能翻译：在该清单底下加 `params`，以参数 `name` 为键，值可以有 `title`、`description`，
以及 `options`（以选项的 `value` 为键、翻译后的选项名为值）。键必须是那份清单有的参数和选项；
没翻到的照原文。

```json
"localizations": {
  "en": {
    "entries": {
      "year": {
        "title": "Popular This Year",
        "params": {
          "region": { "title": "Region", "options": { "zh-Hant": "Chinese (Traditional)", "ja": "Japan" } }
        }
      }
    }
  }
}
```

---

## 8. 版本

`version` 是你的模组版本；`requiredVersion` 是读它需要的 App 版本。
下列栏位是格式 3.0 才有的，用到任何一个都要 `"requiredVersion": "3.0"` 以上，
否则旧 App 会汇入后读错（例如把 JSON 内容百分号编码送出）：

`attribution`、`localizations`、`lookup`、`reading`、`contentKind`、`excludeTags`、`isbnPrefixes`、`detail`、
`minKeywordLength`、`hosts` 里的 `*.` 项目、`bodyEncoding`、`page`／`offset` 参数的 `value`、`followsLanguage`、选项的 `language`，以及 `list` 的 `aliases`、`tags`、`publisher`、`isbn`、`series`、`seriesCovers`、`contentKind`。

格式 3.0.1 才有的（要 `"requiredVersion": "3.0.1"` 以上）：`reviews`、`searchesAuthors`，以及 `list` 的 `id`、`volumes`。

格式 3.0.2 才有的（要 `"requiredVersion": "3.0.2"` 以上）：`icon`、`globalParams`、顶层的 `detail`、`related`、`genre`，以及参数的 `belongTo`、`placeholders`。
旧版 App 会拒绝用了 `globalParams` 的模组（它看不懂那些 `{{…}}`），其他几个会被忽略。

---

## 9. 模组仓库

仓库是一个列出模组的 JSON 档。使用者在 新增模组 → 从网址 贴上仓库网址就能订阅，之后在「模组」页挑选安装；
打开仓库页时会重新读一次，有新版本的模组显示「更新」，按了才换。更新若会连到新的网站，一定先让使用者看过。

```json
{
  "name": "范例仓库",
  "modules": [
    {
      "id": "example.newbooks",
      "title": "新书速报",
      "description": "范例网站的新书",
      "author": "范例作者",
      "version": "1.1",
      "url": "newbooks.json"
    }
  ]
}
```

| 栏位 | 必填 | 说明 |
|------|------|------|
| `name` | ✓ | 仓库名称。 |
| `modules` | ✓ | 模组阵列，最多 500 个；索引档最大 1 MB。 |
| `modules[].id` | ✓ | 必须跟模组档自己的 `id` 一样，否则安装时拒绝。同一仓库不能重复。 |
| `modules[].title` | ✓ | 列表上的名称。 |
| `modules[].description` |  | 说明。 |
| `modules[].author` |  | 作者。 |
| `modules[].version` | ✓ | 仓库里的版本，用来判断「更新」；实际安装的是模组档自己的 `version`。 |
| `modules[].url` | ✓ | 模组档网址，可以是相对于索引档的路径。安装后它就是模组的订阅网址，「检查更新」读它。 |

一个 JSON 若有 `modules` 而没有 `id`，就当成仓库；仓库只能用网址加入（从档案或贴上的文字没有网址可以重新读）。

---

## 10. 测试你的模组

1. 用 `python3 -m http.server 8000` 在电脑上开一个资料夹，模拟器的 App 可以用 `http://localhost:8000/…`
   （`127.0.0.1` 会被挡，要写 `localhost`；`hosts` 也写 `localhost`）。
2. 资源库 ••• → 新增模组 → 从网址，看预览列出的清单和网站对不对。
3. 探索 → 编辑首页 → 新增栏目，选你的模组清单；搜寻页试 `search`。
4. 改了档案要提高 `version`，到模组页按「检查更新」。
