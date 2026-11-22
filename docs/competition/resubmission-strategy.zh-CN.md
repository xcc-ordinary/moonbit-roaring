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

2026-11-22 更新：原"仍可继续增强"项中的第二套跨进程证据已落地。`tools/crossref-fixtures/crosscheck.mjs`（`npm run crosscheck`）在两个独立操作系统进程之间现场交换新生成的 portable 字节：方向 A 由 roaring-wasm（基于 CRoaring 的第三方 WASM 封装）构建并序列化，新启动的 `moon run cmd/main` 进程用新增的 `values` 子命令逐值比对集合内容，并用 `check` 验证逐字节往返；方向 B 由 MoonBit `encode` 现场生成字节，roaring-wasm 反序列化后逐值比对并重新编码确认字节一致。共 19 个用例（11 解码 + 8 编码），覆盖空集、稀疏、稠密、Run、混合容器、offset 头、容器选择平局边界和 32 位值空间顶端，已接入 CI fixtures job 持续执行。措辞注意：交换介质是 hex 参数与标准输出（跨进程管道），不是文件中转。2026-11-22 同日再落地第二套独立进程证据：`tools/official-crosscheck/crosscheck.mjs` 用官方 Java 实现 `org.roaringbitmap:RoaringBitmap` 1.6.30（官方 testdata 即出自该库家族，jar 固定版本并校验 SHA-1 `6b25756b77a7f56da2428f9eef6ba6a56b614617`）在独立 JVM 进程中完成同样的双向交换，19 个用例全部通过，CI 新增 official-crosscheck job 持续执行。至此 CRoaring（第三方 WASM 封装）与官方 Java 两个独立参考实现都为 portable 格式提供现场证据；并实测记录了一处实现间平局差异（3 个连续值时 Java runOptimize 保留 Array、CRoaring 选 Run，两者皆合法，校验按值与往返比对而非强制容器选择）。同日再落地第三套独立进程证据：`tools/go-crosscheck/crosscheck.mjs` 用官方 Go 实现 `github.com/RoaringBitmap/roaring` v1.9.4（go.mod/go.sum 固定版本与模块校验和）在独立原生进程中完成同样的双向交换，19 个用例全部通过，CI 新增 go-crosscheck job 持续执行；Go 在该平局点上与 CRoaring 一致（选 Run），与 Java 不同，三者皆通过。至此 CRoaring、官方 Java、官方 Go 三个独立参考实现都为 portable 格式提供现场跨进程证据，本策略列出的互操作增强项全部完成。同日 CI 的 latest 通道升级到 `moon 0.1.20261119`/`moonc v0.10.22`，项目随即完成弃用 API 迁移（`Int64::from_int`→`to_int64()`、`Iter::new`→`Iter(...)`、Buffer `size_hint=`→`capacity=`、`Bytes::new`→`Bytes::make`），最低工具链要求相应提升到 v0.10.22；三目标 216 项测试、三个示例与 19 例跨进程校验在新工具链下全部通过，这正是"当前工具链可维护性"定位的一次实际兑现。

2026-11-22 同日再完成一轮以源码证据支撑的自我审查与加固（均为本项目内部改进，不构成对其他实现的性能比较）：其一，修复一处 `flip` 正确性缺陷——当一个 Run 容器含有多个完全位于翻转区间上界之后的 run 时，旧代码在发出第一个这样的 run 后即提前退出，静默丢弃其余 run；新增的两个回归测试可在旧代码上复现该丢值（`22 != 33`），修复后扫描发出每个 run 的区间外部分。其二，`flip` 由"逐桶重建容器列表、且把每个缺失全桶物化为 65536 元素数组"改为与 `add_range`/`remove_range` 一致的单趟归并走查，缺失全桶 O(1) 写单个 Run；在本项目自身前后基线（`wasm --release`，2048 桶）实测 370.20 ms → 254.91 µs（约 1450 倍），旧实现为桶数平方级，全空间翻转外推约数分钟，新实现约 8 ms。其三，`union`/`intersect`/`difference`/`xor` 在双方均为 Bitmap 容器时改走 1024 次字级运算，并由 `optimize_bitmap_words` 仅凭结果字按与 `optimize_container` 完全相同的成本模型与平局次序重选编码（仅 Array 结果需解码，Run 结果直接从字提取），portable 输出逐字节不变；混合 fixture（含一个 8192 值 Bitmap 桶）自身前后实测 union 378.98 µs → 65.96 µs（约 5.7 倍）、intersect 321.99 µs → 55.03 µs（约 5.9 倍）。其四，补齐审查发现的测试缺口：两个相交 Bitmap 容器的 `intersects` 命中分支、畸形 run（重叠/乱序/越界）拒绝、Bitmap 容器截断拒绝、删除不存在桶、`iter_from` 起点落在缺失桶、`rank` 跨缺失桶、`contains_range` 的 Run 扫描提前终止，以及宽区间/全空间 `flip`。白盒性质测试逐字节钉住字级快路径与数组管线的编码选择和内容一致。三目标测试由 216 增至 232 项全部通过，未覆盖行由 89 降至 78（剩余库内行均为公共 API 不可达的防御性守卫，其余为 CLI/示例 main，由 CI 的跨进程与 fixture 集成验证覆盖）；CRoaring WASM 封装、官方 Java、官方 Go 三套跨进程校验仍各 19/19 通过，CI 全绿。上述性能数字均为同一工具链下本项目修复前后的自身对照，按本策略"不建议使用的表述"一节，不据此声称优于其他实现。

2026-11-22 同日继续推进审查中列出但尚未实施的优化项（仍为本项目自身前后对照，不比其他实现）：其一，解码与重编码路径字级化——`bitmap_to_array` 改用 Kernighan 逐置位位提取（`lowest_set_bit` 配合 `word &= word - 1`，与 `emit_set_bits` 一致，只遍历置位位而非全部 65536 位）；`run_optimize` 改为按容器类型分派：Bitmap 容器直接走 `optimize_bitmap_words` 免解码，Run 容器先用 `runs.length()` 与缓存基数按成本模型判断已最优则原样保留、否则转数组重选，Array 容器走 `optimize_container`，并复用缓存 `hc.cardinality` 省去重算 popcount（`run_optimize` 不改变值集）。新增白盒测试直接构造容器结构，钉住 Bitmap→Run、Bitmap 保持、Run 保留、稀疏 Run→Array 四个分支（三目标测试增至 233 项）。稠密 fixture（9000 个偶数值、Bitmap 桶）自身前后实测 271.96 µs → 5.38 µs（约 50 倍）。其二，多路集合与区间查询优化——`union_all` 由左折叠改为平衡两两归并（每轮 bitmap 数减半，任一容器被走查 O(log K) 次而非左折叠的 O(K) 次）；`intersect_all` 先按基数升序排序再折叠（最小者先交使结果最快收缩），结果一旦为空即提前终止；`range()` 闭区间由"全量 `to_array` → 过滤 → `from_array` 重排序"改为在 `iter_from(start)` 上遇到首个 `> end` 即停、收集已升序的值再 `from_sorted`（只解码区间触及的桶、免重排序）；`range_cardinality` 由"遍历 [high_start, high_end] 每个可能 key 做桶查找"改为对现有容器归并走查（key 小于区间下界跳过、大于上界即停），复杂度由 O(区间宽度) 降为 O(容器数)。自身前后实测（`wasm --release`）：宽区间稀疏 `range_cardinality`（6 个桶散布全 32 位空间、统计全区间）1.16 ms → 257.73 ns（约 4500 倍）；窄区间稠密 `range`（200 万值稠密位图中取 11 值窗口）8.34 ms → 98.32 µs（约 85 倍）；多桶 `union_all`（32 个各占独立桶的稠密位图）6.78 µs → 4.57 µs（约 1.5 倍）。新增 4 个稠密多桶正确性测试，直接钉住"平衡归并 == 左折叠""最小先交 == 左折叠"的值集与 portable 字节一致、以及窄区间只解码触及桶。三目标测试由 233 增至 237 项全部通过，`moon info` 后 `.mbti` 零 diff（公共 API 不变、纯内部重构），CRoaring WASM 封装、官方 Java、官方 Go 三套跨进程校验仍各 19/19 通过。上述数字均为同一工具链下本项目改进前后的自身对照，按本策略"不建议使用的表述"一节，不据此声称优于其他实现。

2026-11-22 同日收尾审查中剩余的三处内部清理（不改变公共 API，`.mbti` 零 diff）：其一，`highest_set_bit` 由"逐位移位、最多 63 次循环"改写为与 `lowest_set_bit` 完全对称的六步折半级联（自顶向下检查高半区），两者位扫描风格一致；新增白盒测试以显式期望值与全部 64 个单比特位钉住改写正确性。其二，`has_run_container` 在遇到第一个 Run 容器时即提前返回，不再遍历剩余容器（序列化选择 cookie 时只需知道是否存在 Run）。其三，反序列化对同一容器原先计算两次 `container_cardinality`（一次校验头部、一次写入缓存字段），改为只算一次复用；Bitmap 容器的基数是 1024 字 popcount，重复计算浪费明显。新增"多 Bitmap 桶反序列化"基准（32 桶各 8192 偶数值），自身前后实测 175.32 µs → 109.50 µs（约 1.6 倍）。三目标测试由 237 增至 238 项全部通过，CRoaring WASM 封装、官方 Java、官方 Go 三套跨进程校验仍各 19/19 通过。上述数字为本项目自身前后对照，不据此声称优于其他实现。

2026-11-22 同日完成审查中最后一项深层优化——迭代器桶内惰性解码。原 `iter`/`iter_from` 虽按桶惰性（不一次性物化整个位图），但每个桶仍用 `container_to_sorted_array` 整体展开：Bitmap/Run 桶会物化最多 65536 个元素，即使只取一个值。改为私有 `LazyCursor` 结构游标——Array 用索引、Bitmap 用当前字内 Kernighan 逐置位位、Run 用"下一值 + 倒计时"缓存当前区间——按容器类型静态分派、每值单层 Option（走查直接复用、不二次包裹），桶内 seek 免解码（Array 二分、Bitmap 掩码当前字、Run 对 run 末尾二分）。新增白盒等价测试：对三种表示与全部采样 seek 点（含字/桶边界、值下方间隙、越界），逐值钉住游标输出 == 解码管线后缀（含非零 key 钉住 combine）；该测试在开发中实际抓住一处"Run seek 越过末 run 后错误重载 run 0"的缺陷并修复。另补 Bitmap 字内 seek、Run 间隙/跨 run seek 两个黑盒测试与一个全量迭代吞吐基准。自身前后实测（`wasm --release`，同一工具链）：`iter_from` 近末端 seek（4096 桶宽位图取 1 值）99.65 µs → 312.68 ns（约 319 倍）；窄区间稠密 `range`（200 万值取 11 值窗口）100.74 µs → 1.05 µs（约 96 倍）。代价如实记录：惰性流式 `iter` 全量遍历混合 fixture 由 100.50 µs 增至 132.34 µs（约 1.32 倍慢），这是逐值惰性相对整桶 eager 解码的固有开销；批量物化 API `to_array()` 仍走原 eager 路径、性能不变——需要一次性取全部值时用 `to_array()`，需要流式/提前停止/seek 时用 `iter`/`iter_from`，与官方 Java/Go"惰性迭代器 + 批量 toArray"的分工一致。三目标测试由 238 增至 243 项全部通过，`moon info` 后 `.mbti` 零 diff（`LazyCursor` 为私有、公共 API 不变），CRoaring WASM 封装、官方 Java、官方 Go 三套跨进程校验仍各 19/19 通过。上述数字为本项目自身前后对照，不据此声称优于其他实现。

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
