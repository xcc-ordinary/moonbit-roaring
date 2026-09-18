# `moonbit-roaring` 与 `kesmeey/RoaringBitmap` 竞品证据对照

> 调研日期：2026-09-17  
> 对照版本：`moonbit-roaring` 当前 `master`（实施更新 2026-09-18）；`kesmeey/RoaringBitmap` [`f19c497`](https://github.com/kesmeey/RoaringBitmap/tree/f19c4977512aa120cd1add61e32f9dec36bd3102)。  
> 证据范围：两个仓库的源代码、测试、README、GitHub 发布记录，MoonBit 官方文档，以及 Roaring 官方格式规范/CRoaring。没有把二手文章或项目自述当作唯一证据。

## 结论先行

`moonbit-roaring` 不宜申报成“MoonBit 里第一个/唯一的 RoaringBitmap”，因为 `kesmeey/RoaringBitmap` 已经实现了完整的 32 位内存集合基础能力。更准确、也更能经受审查的定位是：

> **面向跨语言数据交换、持久化和连续区间工作负载的 MoonBit Roaring 互操作实现。**它在已有库的内存集合能力之外，补齐 Roaring 官方 portable wire format、可达的 Run 自动选型、区间写入、惰性迭代、bitmap 级 rank/select 和多路聚合，并以 CRoaring 生成的 golden fixtures 验证字节兼容性。

这个价值主张是成立的，但当前证据还不足以支持“production-ready”或“high-performance”：项目没有吞吐基准，核心集合运算会先把容器完整解码为数组再重建；portable 测试也尚未接入官方规范仓库要求的最小 `testdata`。复审材料应主动承认这些边界，并在 9 月 24 日前补齐后文列出的证据包。

## 一、逐项对照

| 维度 | `kesmeey/RoaringBitmap` | `moonbit-roaring` | 可成立的差异结论 |
|---|---|---|---|
| 基础范围 | 32 位无符号集合；add/remove/contains、四种集合运算、批量添加、min/max、subset/equality、Jaccard、范围筛选、回调遍历、统计。见其[公开 API 源码](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt)。 | 同样覆盖 32 位基础集合；另外有多路 union/intersection、区间写入、惰性 `Iter`、bitmap 级 rank/select、序列化。见[核心 API](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/roaring.mbt#L37-L525)、[区间 API](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/range.mbt#L188-L272)、[查询 API](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/iter.mbt#L94-L158)。 | 不是基础能力空白，而是互操作、批量区间和查询模型扩展。 |
| 容器类型 | 定义 Array、Bitmap、Run 三种容器；Run 结构确实存在，不能说“没有 Run”。见[类型定义](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/types.mbt#L17-L33)。 | 同样是 Array、Bitmap、Run 三种容器。见[类型定义](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/types.mbt#L15-L32)。 | 容器“种类”不是差异，Run 是否能由正常公开路径实际选中才是差异。 |
| Run 自动选型 | `optimize_container` 会评估 Run，但在该文件中只有定义，没有调用；正常 `add`/`add_many`/union 路径只做 Array↔Bitmap 或维持既有 Run。证据见[`optimize_container`](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L1047-L1100)、[`container_add`/union](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L415-L475)、[`add_many` 新建与合并容器](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L2210-L2261)。其“Run 测试”只断言集合内容，没有断言 `run_containers > 0`，见[测试](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap_test.mbt#L603-L630)。 | 每次 add/remove/union/intersect/difference/xor 都回到按字节成本选 Array/Bitmap/Run 的函数；边界测试直接断言 Run 被选中。见[优化及各 mutation 调用点](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/container.mbt#L380-L448)、[Run 选型断言](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/boundary_test.mbt#L43-L69)。 | “已有库无 Run”不成立；“已有库的公开构造/变更路径不会从 Array/Bitmap 自动产生 Run，而本项目可验证地会”成立。 |
| Portable 格式 | 对 `src` 全树检索未发现 serialize/deserialize/portable 实现；仓库源代码树只有 `RoaringBitmap.mbt`、`types.mbt` 与测试，见[源码目录](https://github.com/kesmeey/RoaringBitmap/tree/f19c4977512aa120cd1add61e32f9dec36bd3102/src)。这是“截至该提交未发现”，不是作者永久不计划实现。 | 实现官方 portable 布局与严格反序列化；API 只暴露 portable 格式，不再接受会被忽略的 Bool 参数。见[实现](https://github.com/xcc-ordinary/moonbit-roaring/blob/master/serialize.mbt)。 | 这是最强的非重复价值：让 MoonBit 数据能进入 Java/C/Go 等 Roaring 数据链路，而不只在 MoonBit 进程内使用。 |
| 官方格式依据 | 未发现格式实现，因而无格式兼容性证据。 | 官方规范定义 32 位格式由 array/bitset/run 三种 16 位容器组成，并规定 little-endian cookie/header/container layout，见[RoaringFormatSpec](https://github.com/RoaringBitmap/RoaringFormatSpec#standard-32-bit-roaring-bitmap)。本项目实现相同布局。 | 应把赛题价值写成“wire interoperability”，而不是另一套同名数据结构。 |
| 跨语言验证 | 未发现 golden fixtures 或外部实现互验。 | 直接读取官方 `RoaringFormatSpec/testdata` 的两个 Java 生成文件，检查集合内容并逐字节重编码；另有 6 组由第三方 `roaring-wasm` 生成的 fixture。见[官方 fixture 说明](https://github.com/xcc-ordinary/moonbit-roaring/tree/master/tools/official-fixtures)和[第三方生成器](https://github.com/xcc-ordinary/moonbit-roaring/tree/master/tools/crossref-fixtures)。 | 证据同时覆盖官方来源和第三方交叉参考，并准确标注来源。 |
| 区间能力 | `range(start,end)` 是从已有 bitmap 中筛出闭区间元素；实现会逐容器转数组再遍历。见[源码](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L1487-L1514)。没有发现 add/remove/contains range。 | `from_range`、`add_range`、`remove_range`、`contains_range` 使用半开区间；整 bucket 写入直接成为一个 Run，整 bucket 删除直接移除。见[实现与注释](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/range.mbt#L50-L272)。 | 两者不是同一个 API：已有库做范围查询，本项目补范围构造/变更与整 bucket 快路。申报书不要写“已有库没有 range”。 |
| 迭代 | `iter(f)` 是回调遍历，并且先把每个容器转成数组。见[源码](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L1487-L1497)。 | 返回标准 `Iter[UInt]`，一次只解码一个 bucket，调用方可组合 `take`/`find_first` 提前停止。见[源码](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/iter.mbt#L94-L123)。 | 可定位为 MoonBit 标准迭代协议和 early-stop 能力，而不是“已有库不能遍历”。 |
| Rank/select | 有 `container_rank` 和 `container_get_at`，但参数 `Container` 类型本身不公开；未发现 `RoaringBitmap::rank/select`。见[container API](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L1708-L1749)和[私有 Container](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/types.mbt#L17-L27)。 | 提供 bitmap 级 `rank(value)` 与 `select(index)`，跨 bucket 计算且不先 materialize 整体数组。见[源码](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/iter.mbt#L125-L158)。 | 可说“补齐对用户可调用的 bitmap 级 rank/select”，不可说“已有库完全没有 rank 代码”。 |
| 多路聚合 | 二元四种集合运算齐全；未发现 `union_all`/`intersect_all`。见[二元 API](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L155-L299)。 | 提供 `union_all`/`intersect_all`，见[源码](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/roaring.mbt#L443-L474)。 | 是搜索倒排表、分片合并的便利扩展；当前实现是 fold，不应宣称有专门的 heap/基数优化。 |
| 迁移便利 API | 有 `clear`、Jaccard similarity、从已有集合提取闭区间 `range`。见[API](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L129-L154)与[Jaccard](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L1516-L1527)。 | 已实现同语义的不可变 `clear`、Jaccard 和闭区间 `range`，降低迁移成本。 | 本项目保留半开区间变更 API，同时补齐已有生态的常用表面。 |
| 测试 | 仓库含 39 个 `test` block；其关闭的 PR 也报告“39 tests passing”，见[PR #1](https://github.com/kesmeey/RoaringBitmap/pull/1)。但当前工具链复测会在旧泛型语法处解析失败，详见下文。 | 2026-09-18 本地三目标均实测 131/131；新增官方格式、恶意输入语义校验和迁移 API 测试。 | 数量本身不是质量结论；更有说服力的是格式截断、语义不变量、容器边界和外部 fixture 类别。 |
| 当前 MoonBit 兼容性 | 2026-09-17 使用 `moon 0.1.20260904` 复测，因 `fn array_insert_at[T]` 等旧泛型语法发生 parse error；对应源码见[370 行](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L370-L405)。MoonBit 官方当前语法是 `fn[T] f`，见[官方方法/泛型示例](https://docs.moonbitlang.com/en/latest/language/methods.html)。 | 同一工具链在 wasm、wasm-gc、js 均通过 131/131，并加入 GitHub Actions。 | 当前可构建性是实际维护价值，但要附日期和工具链版本，不能把一次环境复测描述成永久事实。 |
| 算法/潜在性能 | Array/Bitmap/Run 的多种组合有专用运算路径，例如 bitmap×bitmap 直接位运算；见[container set operations](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L455-L537)。 | 为保证统一选型，当前 add/remove 和四种集合运算会先把容器转成排序数组，再执行操作并重选容器；见[实现](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/container.mbt#L404-L448)。 | 在没有实测前，不能声称本项目整体更快；在大 Bitmap 或重复单点写入上，本项目可能更慢。近期必须补基准并逐步引入直接容器算法。 |
| 性能基准 | README 列复杂度，但仓库未发现可运行 benchmark；见[README 性能表](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/README.md#L253-L263)。 | 已提交 MoonBit benchmark，覆盖构建、contains、union/intersect 和序列化，记录 release/wasm 基线与复现命令，见[结果](https://github.com/xcc-ordinary/moonbit-roaring/blob/master/docs/benchmarks.md)。 | 只作为本项目回归基线，不据此声称优于已有库。 |
| 发布成熟度 | 已在 Mooncakes 发布 `0.1.0`，安装页为 [`kesmeey/RoaringBitmap@0.1.0`](https://mooncakes.io/docs/kesmeey/RoaringBitmap)；GitHub 无 tag/release，见[tags](https://github.com/kesmeey/RoaringBitmap/tags)与[releases](https://github.com/kesmeey/RoaringBitmap/releases)。仓库主分支仅 3 个 commits，GitHub API 显示最后 push 为 2025-06-25；[commit 历史](https://github.com/kesmeey/RoaringBitmap/commits/main/)。 | 尚未在 Mooncakes 发布，GitHub 也无 tag/release，见[tags](https://github.com/xcc-ordinary/moonbit-roaring/tags)与[releases](https://github.com/xcc-ordinary/moonbit-roaring/releases)。 | 已有库目前发布成熟度更高；本项目要把发布、版本、CI、兼容性承诺做成复审证据，而非只写 roadmap。 |
| 许可证 | [Apache-2.0](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/LICENSE)。 | [Apache-2.0](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/LICENSE)。CRoaring 也是 [Apache-2.0](https://github.com/RoaringBitmap/CRoaring/blob/master/LICENSE)。 | 许可证不存在差异或阻碍；也为后续复用/对齐 CRoaring 测试资产提供兼容基础，但仍须遵守 NOTICE/归属要求。 |

## 二、为什么 portable interoperability 足以构成“必要性”

Roaring 不只是内存压缩算法，也是一种跨实现的数据格式。官方规范明确说明该 portable 格式被多个系统使用，并列出 C/C++、Java、Go 参考实现；规范还要求实现至少能解析规范仓库 `testdata` 中的两个文件，见[官方规范的 Testing 与 Reference implementations](https://github.com/RoaringBitmap/RoaringFormatSpec#testing)。CRoaring 的 C++ API也明确把 portable read/write 描述为与 Java、Go 兼容，见[`Roaring::write/read`](https://github.com/RoaringBitmap/CRoaring/blob/master/cpp/roaring/roaring.hh)。

因此已有 MoonBit 包即使能完成进程内集合运算，只要不能读写 portable 格式，仍然无法直接完成下面这些工程任务：

1. MoonBit 服务读取 Java/Go/C++ 已生成的 bitmap 索引；
2. MoonBit 生成 bitmap 后交给 ClickHouse/CRoaring 或其他语言服务；
3. bitmap 作为稳定二进制资产持久化，而不是先膨胀成整数数组或自定义 JSON；
4. 用跨语言 golden corpus 防止不同实现之间出现“各自 round-trip 正确、彼此不兼容”。

这不是同一 API 的重复实现，而是已有库未提供的系统边界能力。复审应把它列为主价值，Run 自动选型、range mutation、lazy query 列为次价值。

## 三、当前证据的不足与不可证实项

以下内容截至上述固定提交无法证实，申报书不应写成既成事实：

- **无法证明本项目整体性能更高。**没有 benchmark；源码还显示其通用容器运算存在全量数组化成本。
- **无法证明完整通过 RoaringFormatSpec conformance。**已有 6 组 CRoaring-port golden fixture，但还未接入官方规范要求的两个 `testdata`，也没有 fuzz/differential test 全量结果。
- **无法证明所有语言实现都已实测互通。**当前证据来自同一个 CRoaring WASM port，不等于已经分别跑过 Java、Go、Rust、Python。
- **无法证明恶意输入下完整安全。**截断前缀测试证明了长度检查的一部分，但反序列化器目前没有展示对 key 严格递增、cardinality 与 payload 一致、offset 合法性等全部不变量的验证。
- **无法证明 native target 可用。**项目 README 已说明 native 未验证；不要在复审表中笼统写“全平台”。
- **无法证明项目发布成熟。**尚未发布 Mooncakes 版本、tag 或 GitHub release。
- **不能把 `roaring-wasm` 写成官方组织发布。**它是第三方 port；可验证的是它基于 CRoaring 并生成了本项目的 fixtures。
- **不能说已有库没有 Run、range、iteration 或 rank 代码。**准确差异分别是：Run 未由公开 mutation 路径自动选中；只有范围筛选而无范围 mutation；只有 callback iteration；只有不可从公开 `RoaringBitmap` 调用的 container-level rank/get-at。

## 四、9 月 24 日前最值得补的复审证据

按说服力排序：

1. **官方 conformance testdata**：把 [RoaringFormatSpec/testdata](https://github.com/RoaringBitmap/RoaringFormatSpec/tree/master/testdata) 的最小规定样本纳入自动测试，证明不是只匹配自制 6 个案例。
2. **双向外部互操作脚本**：在 CI 中执行 CRoaring/Java/Go → MoonBit deserialize，以及 MoonBit serialize → 外部实现 deserialize；发布日志保留工具版本、SHA 与输出摘要。
3. **对称、可复现 benchmark**：固定 MoonBit 版本、机器、数据集和 warm-up，比较 sparse、dense、runs、mixed、跨 bucket 的 add_many/contains/union/intersect/serialize/deserialize。必须同时呈现本项目胜负项；不要只挑赢家。
4. **当前 MoonBit CI**：至少 wasm、wasm-gc、js 三 target 运行 `moon check`/`moon test`，并固定本次提交 badge。已有库在当前工具链的 parse failure 可作为维护动机，而不是攻击性文案。
5. **发布证据**：发布 Mooncakes `0.1.0`、Git tag/release，写清 portable-only、32-bit、非线程安全/不可变 API、native 未验证等边界。
6. **兼容性矩阵与迁移页**：逐项列 `kesmeey/RoaringBitmap` 与本项目 API 映射，承认对方的 Jaccard/范围筛选优势，并给出从 `to_array` 迁移或 portable 数据交换方案。这比泛泛说“更强”更像生态互补。
7. **修正项目文案（已完成）**：README 已把 `roaring-wasm` 准确标为第三方 CRoaring-based WASM 包，删除 `production-ready/high-performance`，并公开边界。
8. **性能架构路线**：保留统一的最小字节容器选型，但把 bitmap×bitmap、run×run 等高频组合改为直接容器算法，避免每次全量转数组；以 benchmark 驱动，不作空泛承诺。

## 五、可直接放入报名表的“扩展或互补关系”草案

> MoonBit 生态已有 `kesmeey/RoaringBitmap@0.1.0`，我们不主张自己是首个 RoaringBitmap，也不否定其基础价值。该库已经提供 32 位集合、Array/Bitmap/Run 数据结构、二元集合运算、范围筛选、Jaccard 等进程内能力。我们在源码级对照后，将本项目边界收敛为 **Roaring portable interoperability 与连续区间工作负载**：已有库截至 `f19c497` 未实现 portable serialization；其 Run 优化函数未接入公开 add/add_many/集合运算产生容器的路径。`moonbit-roaring` 实现 RoaringFormatSpec 的 portable cookie/header/container layout，直接读取官方 Java 生成的 testdata 并逐字节重编码，同时用第三方 CRoaring-based WASM 包生成六类额外 fixture；还提供能实际产生 Run 的统一容器选型、整 bucket 快路的 add/remove/contains range、标准惰性 `Iter`、bitmap 级 rank/select 和多路聚合。它解决的是 MoonBit 与其他 Roaring 实现之间的持久化和交换问题，而不是仅增加另一套同名集合 API。当前边界也公开写明：只有 32 位 portable 格式、native 未验证、不声称性能优于其他实现。

## 六、复测记录

复测环境：Windows，2026-09-17，`moon 0.1.20260904 (94521db)`、`moonc v0.10.12+1634b282e`。

```text
# moonbit-roaring @ 4aa7305
moon test
Total tests: 131, passed: 131, failed: 0.

# kesmeey/RoaringBitmap @ f19c497
moon test
Parse error at src/RoaringBitmap.mbt:370/383/396:
unexpected `fn f[T]`, you may expect `fn[T] f`
```

复现命令：

```powershell
git clone https://github.com/xcc-ordinary/moonbit-roaring.git
Set-Location moonbit-roaring
git checkout 4aa7305eadbe94d733654f4cc62fe401d32a57a1
moon test

git clone https://github.com/kesmeey/RoaringBitmap.git
Set-Location RoaringBitmap
git checkout f19c4977512aa120cd1add61e32f9dec36bd3102
moon test
```

工具链兼容性会随 MoonBit 更新而变化，因此该记录只代表指定日期、版本与提交；提交复审时应附 CI 链接或日志附件。
