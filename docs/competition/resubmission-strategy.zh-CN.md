# moonbit-roaring 初审复议与补充材料策略

> 调研日期：2026-09-17；实施更新：2026-09-18
> 补交截止：2026-09-24 前（以本次驳回通知和赛事群最新通知为准）

## 一句话结论

`moonbit-roaring` 不应申报成“MoonBit 的另一个 RoaringBitmap”，而应明确定位为：

> 在 `kesmeey/RoaringBitmap` 已覆盖基础集合语义的基础上，补齐**当前 MoonBit 工具链可用性、Roaring 官方 portable 格式互操作、真正进入主数据路径的 Run 容器优化**，并提供可复现的一致性验证。

这个定位既承认已有生态贡献，也说明本项目并非重复造轮子。

## 现状对比（2026-09-17 实测）

| 维度 | `kesmeey/RoaringBitmap` | `xcc-ordinary/moonbit-roaring` | 对复审的意义 |
| --- | --- | --- | --- |
| 基础 32 位整数集合与四则集合运算 | 已实现 | 已实现 | 这是重叠部分，不能当作本项目创新点 |
| Mooncakes 发布 | 已发布 `0.1.0` | 已发布 [`0.1.0`](https://mooncakes.io/docs/xcc-ordinary/moonbit-roaring)，并从全新项目完成三目标安装测试 | 双方都有可安装版本，本项目另有 GitHub Release 与公开 CI |
| 当前 MoonBit 工具链 | 在 `moon 0.1.20260904` 下因旧泛型语法出现 3 个解析错误，测试无法启动 | 同一工具链下可运行 | 证明本项目提供当前生态可直接使用的实现 |
| Run 容器 | 定义了 Run 相关代码和公开 `optimize_container`，但该函数只有定义、没有调用点；`add` 主路径只做 Array/Bitmap 转换 | 每个核心变更路径最终按字节成本重新选择 Array/Bitmap/Run | 证明连续数据压缩不是声明能力，而是实际生效的行为 |
| Portable 序列化 | 未找到 `serialize`/`deserialize`/字节格式实现 | 实现 Roaring portable 格式读写 | 这是最强的互补点：MoonBit 可进入跨语言 Roaring 数据链路 |
| 区间能力 | 有“筛选现有元素”的 `range(start, end)` | 有 `from_range`、`add_range`、`remove_range`、`contains_range` | 两者语义不同；材料中不能笼统写“对方没有 range” |
| 迭代 | 回调式全量遍历 | `Iter[UInt]` 惰性迭代，可提前停止 | 是 API 与执行模型的扩展 |
| rank/select | 暴露容器级 `container_rank`，没有 bitmap 级 `rank/select` | bitmap 级 `rank` 和 `select` | 应准确写作用域，避免“对方完全没有 rank”的失实表述 |
| 便利 API | 有 `clear`、`jaccard_similarity`、区间筛选 | 已补 `clear`、`jaccard_similarity` 和兼容闭区间 `range` | 降低从已有 API 迁移的成本 |
| 测试 | 源码中有 39 个测试，但当前工具链下无法编译执行 | 131 个测试，wasm、wasm-gc、js 均通过 | 是工程成熟度证据，但不能仅靠测试数量取胜 |
| CI | 未见当前可执行 CI | 已添加三目标测试、格式/接口检查和 fixture 再生成校验 | 提供公开、持续的可复现证据 |

对方源码证据：

- [`container_add` 只做 Array → Bitmap，未调用优化器](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L416-L432)
- [`optimize_container` 的定义](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbt#L1060-L1101)
- [对方公开 API](https://github.com/kesmeey/RoaringBitmap/blob/f19c4977512aa120cd1add61e32f9dec36bd3102/src/RoaringBitmap.mbti)
- [Mooncakes `kesmeey/RoaringBitmap@0.1.0`](https://mooncakes.io/docs/kesmeey/RoaringBitmap)

本项目源码证据：

- [`optimize_container` 按三种编码的实际字节成本选择表示](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/container.mbt#L378-L448)
- [Portable 格式实现](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/serialize.mbt)
- [跨实现 golden fixtures](https://github.com/xcc-ordinary/moonbit-roaring/blob/4aa7305eadbe94d733654f4cc62fe401d32a57a1/golden_fixtures_test.mbt)
- [Roaring 官方 portable 格式规范](https://github.com/RoaringBitmap/RoaringFormatSpec)

## 如何证明“有价值”

### 1. 把互操作从文字承诺变成可下载证据

Portable 格式是本项目最难被替代的价值点。官方规范明确规定了 cookie、容器描述、offset 和三类容器的二进制布局，并把 C/C++、Java、Go 列为参考实现。

复审前应提交以下证据：

1. 直接读取 `RoaringFormatSpec/testdata` 中的官方测试文件；
2. MoonBit 写出文件，再由 CRoaring 或官方 Java/Go 实现读取并校验集合内容；
3. CRoaring 或官方 Java/Go 写出文件，再由 MoonBit 读取；
4. 把这两个方向放进 CI，而不只是 README 截图；
5. 记录参考实现版本、fixture 的生成命令和 SHA-256。

当前仓库用 `roaring-wasm` 生成了 6 组固定 fixture，这是很好的起点，但 `roaring-wasm` 的仓库属于个人维护者，不宜再称为“官方 CRoaring WASM port”。复审材料应写成“基于 CRoaring 的第三方 WASM 封装”，并增加官方规范 testdata 或官方组织下实现的双向验证。

### 2. 用行为测试证明 Run 优化真的生效

不要只对比“双方都有 RunContainer 类型”。应展示同一数据的实际表示：

- 输入：`0..10000` 的连续整数；
- 现有库的 `from_array → add → container_add` 路径不会调用 `optimize_container`，最终进入 8 KiB Bitmap；
- 本项目 `from_range(0, 10000)` 产生 1 个 Run，内部 payload 统计为 4 bytes；
- 本项目示例中 300 个连续文档 ID 使用 1 个 Run，payload 4 bytes，portable 序列化后 15 bytes。

需要把上述结果做成可运行命令和测试断言，并明确“4 bytes 是容器 payload 统计，不含对象和数组运行时开销”，避免把估算写成完整内存占用。

### 3. 用当前工具链可复现性证明维护必要性

在干净环境固定以下命令与输出：

```powershell
moon version --all
moon info
moon fmt --check
moon test
moon test --target wasm-gc
moon test --target js
```

2026-09-18 本地结果：`moon 0.1.20260904`；本项目 131/131 测试在 wasm、wasm-gc、js 三个目标通过。对方仓库在同一工具链执行 `moon test` 时，旧式 `fn f[T]` 泛型语法产生 3 个解析错误。CI 显式跟踪官方 `latest` 通道并输出 `moon version --all`；指定版本的对称复测由本段日期、提交和命令固定，避免把滚动 CI 徽章误写成永久的同版本证明。

这个事实可以证明“当前可用实现”的必要性，但措辞应是“截至该提交在该工具链上的可复现结果”，不要把它写成对原作者或项目质量的泛化评价。

### 4. 用真实用户路径证明它不是算法练习

至少保留三个完整场景，每个场景都要包含输入、调用、输出和价值：

1. 倒排索引：posting list 的 `intersect`、`union_all` 与惰性取前 N 个结果；
2. 时间窗口/日志 ID：`from_range` 生成 Run，并用 portable 格式交给 Java/Go/C 服务；
3. 分析查询：`rank`/`select` 做累计计数和第 N 个命中项。

其中至少一个示例应真正跨进程或跨语言读写文件。仅在 MoonBit 内部 round-trip 不能充分证明互操作价值。

## 如何证明“有必要”

评委实际在问三个问题：

### 为什么不能直接使用已有库？

因为已有库当前解决的是 MoonBit 进程内的基础压缩集合与集合运算，但没有 portable 字节格式；在当前 MoonBit 工具链上还存在可复现的语法不兼容。需要跨语言交换 Roaring 数据或直接使用当前工具链的用户，现有包不能完整满足需求。

### 为什么不只给已有库提 PR？

应避免贬低原项目。建议回答：本项目尊重并承认其基础 API 和三容器设计；但 portable 格式、严格反序列化、惰性迭代、区间构造以及贯穿所有变更路径的表示选择，涉及公共 API、内部不变量、测试体系和发布维护方式的系统扩展。独立包可以在不破坏既有用户兼容性的情况下推进；同时愿意将格式 fixture、问题报告或可复用修复回馈给原项目。

### 生态为什么需要标准兼容，而不只是又一个实现？

Roaring 的价值不仅是压缩算法，还在于统一的 portable 数据格式。没有该格式，MoonBit 只能在自身进程内使用位图；有了该格式，MoonBit 才能读取和产出 Java、C/C++、Go 等生态已有的 Roaring 数据。项目的边界因此从“数据结构练习”变成“MoonBit 接入成熟数据基础设施的互操作组件”。

## 可直接粘贴进报名表的“与已有项目的扩展/互补关系”

> 我们已重新核查 MoonBit 生态中的 `kesmeey/RoaringBitmap@0.1.0`。该项目已经实现 32 位整数集合、Array/Bitmap/Run 三类容器定义以及并、交、差、异或等基础能力；我们尊重并明确承认这部分先行工作。`moonbit-roaring` 的申报价值不在重复这些基础 API，而在补齐三个尚未被满足、且可独立验证的生态需求。第一，现有项目没有实现 Roaring 官方 portable 序列化格式，本项目按 `RoaringFormatSpec` 实现读写，并直接读取官方 Java 实现生成的 testdata、验证集合内容后逐字节重新编码，使 MoonBit 能进入跨语言 Roaring 数据链路。第二，现有项目虽定义了 Run 优化函数，但在其当前源码中该函数没有调用点，常规 `add/from_array` 路径只在 Array 与 Bitmap 间转换；本项目把按字节成本选择 Array/Bitmap/Run 的逻辑接入 add、remove 和全部集合运算，并用容器统计与连续区间测试证明 Run 实际生效。第三，现有项目当前提交在 `moon 0.1.20260904` 下会因旧泛型语法出现解析错误，本项目在同一工具链的 wasm、wasm-gc、js 三个目标上通过 131 项测试，并用 CI 持续验证格式、接口与 fixture 可复现性。除此之外，本项目增加严格反序列化、区间构造与修改、惰性迭代、bitmap 级 rank/select、多路集合运算，并补齐 `clear`、Jaccard 和闭区间筛选等迁移 API。我们的定位是标准互操作、当前可维护的扩展实现，而不是否认或简单复制已有项目；后续也愿意向原项目共享格式 fixture 与兼容性问题报告。

## 复审前完成状态

原阻断项已在 2026-09-18 全部落地：Mooncakes `0.1.0` 发布与全新项目安装验证、GitHub Release、真实 CI、官方 testdata、严格错误输入校验、兼容 API、可复现 benchmark，以及 `Interoperability-focused` 的克制定位。

仍可继续增强但不阻断复审：启动 CRoaring/Java/Go 独立进程读取 MoonBit 新生成文件，形成除官方 Java fixture 双向逐字节往返之外的第二套跨进程证据。

## 9 月 17 日至 24 日执行顺序

1. 9 月 17—18 日：修正文案和定位；加入公平对比页；添加真实 CI。
2. 9 月 18—20 日：加入官方 testdata 和双向跨语言一致性测试；补反序列化语义校验。
3. 9 月 20—21 日：建立可复现 benchmark；记录机器、工具链、release/debug 模式和数据生成方法。
4. 9 月 21—22 日：补 `clear`、Jaccard、区间筛选等迁移便利 API，或明确列出兼容路线图。
5. 9 月 22—23 日：发布 Mooncakes；从一个全新临时项目执行 `moon add`、构建、测试和示例。
6. 9 月 23—24 日：更新报名表，只写已经落地且能从公开链接复现的事实；预留一天处理 CI、发布或审核反馈。

## 不建议使用的表述

- “现有库是半成品/死代码”：过度攻击性。改为“Run 优化函数在当前提交中没有调用点”。
- “比现有库性能更高”：当前没有基准，不能证明。
- “官方 roaring-wasm”：来源不准确。
- “支持 Java/C++/Go/Rust/Python”：应写“实现官方 portable 格式；已对哪些具体参考实现做过验证”并列证据。
- “Production-ready”：现阶段证据不足。
- “对方没有 range/rank/iter”：不准确；必须区分区间筛选与区间修改、容器级与 bitmap 级 rank、回调遍历与惰性迭代。
