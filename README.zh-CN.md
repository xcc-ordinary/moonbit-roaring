# moonbit-roaring

[![CI](https://github.com/xcc-ordinary/moonbit-roaring/actions/workflows/ci.yml/badge.svg)](https://github.com/xcc-ordinary/moonbit-roaring/actions/workflows/ci.yml)

[English](README.md) | [简体中文](README.zh-CN.md)

一个以互操作为核心的 MoonBit RoaringBitmap 实现：自动在
Array/Bitmap/Run 三种容器间选择，并实现 Roaring portable 二进制格式。

本项目是对 [`kesmeey/RoaringBitmap`](https://github.com/kesmeey/RoaringBitmap)
的扩展与互补，而不是否认或替代。已有项目为 MoonBit 提供了基础位图与集合运算；
本项目重点补齐 portable 格式互操作、常规变更路径中的自动 Run 压缩、严格解码和
当前工具链下的可复现验证。

## 为什么仍有必要

两个项目都实现 32 位整数集合和标准集合运算，这是我们主动承认的重叠部分。本项目
提供的独立价值是：

- **跨语言 portable 格式**：按
  [`RoaringFormatSpec`](https://github.com/RoaringBitmap/RoaringFormatSpec)
  读写，使 MoonBit 能接入已有的 Roaring 数据链路。
- **Run 优化进入主路径**：`add`、`remove`、区间方法和全部集合运算都会按编码字节
  成本重新选择 Array、Bitmap 或 Run。
- **严格反序列化**：拒绝截断输入、非法 offset、乱序 key/array、重叠 run、基数不符
  和尾随字节。
- **bitmap 级扩展 API**：半开区间构造/修改、惰性迭代、`rank`、`select`、多路集合
  运算，以及迁移便利 API `clear`、闭区间 `range` 和 `jaccard_similarity`。

带源码链接的公平对比见
[`docs/competition/competitor-research.md`](docs/competition/competitor-research.md)。

## 安装

```bash
moon add xcc-ordinary/moonbit-roaring
```

已发布：[`xcc-ordinary/moonbit-roaring@0.1.0`](https://mooncakes.io/docs/xcc-ordinary/moonbit-roaring)。已在全新项目中完成真实下载、编译及 portable 往返测试，`wasm`、`wasm-gc`、`js` 三个目标均通过。

## 示例

```moonbit
let sparse = @roaring.RoaringBitmap::from_array([1U, 100U, 1000U])
let consecutive = @roaring.RoaringBitmap::from_range(0U, 10000U)
let result = sparse.union(consecutive)

// 对外只暴露跨语言 portable 格式，不使用容易误解的 Bool 模式参数。
let bytes = result.serialize()
let restored = match @roaring.RoaringBitmap::deserialize(bytes) {
  Ok(bitmap) => bitmap
  Err(error) => panic("invalid bitmap: \{error}")
}

let first_three = restored.iter().take(3).to_array()
let count_at_or_below_500 = restored.rank(500U)
let fifth = restored.select(4)
```

计数类问题不需要结果位图本身，因此有单独的方法——`and_cardinality` 等只返回基数，
不构造任何中间位图。它们返回 `Int64`，因为位图最多可容纳 2^32 个值：

```moonbit
let matched_both = term_a.and_cardinality(term_b)
let matched_either = term_a.or_cardinality(term_b)
let only_in_a = term_a.andnot_cardinality(term_b)
let differs = term_a.xor_cardinality(term_b)
```

`is_subset` 直接走查容器，不经过 `andnot_cardinality`，因此累加过程中即使溢出，
也不会把非子集误报成子集。`jaccard_similarity` 建立在基数方法之上，不会为了读一个
长度而物化整个交集。

三个可运行用户路径：

```bash
moon run examples/inverted_index
moon run examples/portable_window
moon run examples/analytics
```

它们分别演示倒排索引查询、时间窗口的 portable 交接，以及 bitmap 级累计/顺序分析。

## 已实现能力

- Array、Bitmap、Run 三种容器
- 标准集合运算与多路并集/交集
- 只算基数的集合运算（`and_cardinality`、`or_cardinality`、`andnot_cardinality`、
  `xor_cardinality`），不构造结果位图
- 半开区间构造、修改和包含判断
- 闭区间补集 `flip`
- 惰性 `Iter[UInt]`、bitmap 级 `rank` 和 `select`
- Roaring portable 序列化与严格反序列化
- 不修改原对象的兼容 API：`clear`、闭区间 `range`、Jaccard 相似度
- 容器选择和编码 payload 大小统计

## 命令行

`cmd/main` 在命令行直接驱动 portable 格式。字节以十六进制传递，不需要配置文件 I/O，
各目标都能运行：

```bash
moon run cmd/main -- encode 1 100 1000
# 3a30000001000000000002001000000001006400e803

moon run cmd/main -- encode --start 0 --end 200000
# 3b3003000f0000ffff0100ffff0200ffff0300...

moon run cmd/main -- check 3a30000001000000000002001000000001006400e803
# ok: 3 values in 22 bytes, byte-for-byte round trip

moon run cmd/main -- info 3a30000001000000000002001000000001006400e803
# values          3
# min / max       1 / 1000
# containers      1 (array 1, bitmap 0, run 0)
# container bytes 6
# serialized      22
```

`check` 还会交叉校验位图自身的查询方法，因此既能发现格式漂移，也能发现内部不一致。
完整说明见 [`docs/usage.md`](docs/usage.md)。

## 可复现证据

- CI 在 `wasm`、`wasm-gc`、`js` 三个目标运行检查和测试。
- 直接读取 `RoaringFormatSpec/testdata` 中由官方 Java 实现生成的文件，验证已知值，
  再逐字节重新编码。
- 另有 10 类 fixture 由 `roaring-wasm` v1.1.0 生成。它是第三方、基于 CRoaring
  的 WASM 包，并非官方项目；CI 验证结果可重复。其中 4 类正好落在容器选择的
  成本边界上（2、3、4 个连续值，以及散点中夹一个二元组），因此成本模型是
  对照参考实现校验，而不是只对照自己。
- 错误输入测试覆盖结构和语义校验，包括代表性数据的每一个截断前缀。
- release 模式基准和复现方法见 [`docs/benchmarks.md`](docs/benchmarks.md)；这些数据
  只作为本项目基线，不用于宣称优于其他实现。

```bash
moon info
moon fmt --check
moon check -d
moon test
moon test --target wasm-gc
moon test --target js
moon bench --release --target wasm
```

## 与已有项目的边界

以下结果基于 2026-09-17 对对方提交
`f19c4977512aa120cd1add61e32f9dec36bd3102` 的复现：

| 维度 | `kesmeey/RoaringBitmap` | `moonbit-roaring` |
| --- | --- | --- |
| 基础 32 位集合运算 | 已实现 | 已实现 |
| 三类容器定义 | 已实现 | 已实现 |
| 常规变更路径选择 Run | 当时提交中优化器没有调用点 | 已接入变更与集合运算 |
| Roaring portable 字节 | 当时提交中未找到 | 已用官方 testdata 验证 |
| 区间 API | 筛选已有值的闭区间 | 同名兼容 API + 半开区间构造/修改 |
| 迭代 | 回调遍历 | 惰性 `Iter[UInt]` |
| Rank | 容器级辅助函数 | bitmap 级 `rank` 和 `select` |
| 当前工具链 | 固定提交在 `moon 0.1.20260904` 下出现旧泛型语法解析错误 | 三目标 CI |

上述内容只描述特定提交和工具链下的复现事实，不是对原项目整体质量的评价。完整命令、
源码证据和限制见对比文档。

## 范围与限制

- 只支持 32 位无符号整数，不支持 Roaring64。
- 只支持 portable 格式，不提供 native/frozen/mmap 格式。
- 提供不可变操作，不提供线程安全的可变位图 API。
- **可计数与可物化的边界。** `size`、`rank` 和四个 `*_cardinality` 返回 `Int64`，
  在整个 32 位取值范围内保持精确，因此装有 2^32 个值的位图也能正确报告基数。
  而需要物化结果的方法——`to_array`、`from_array`、`iter`、`add_many`——受 MoonBit
  自身 `Array` 长度上限 2147483647 约束，无法表示那么大的位图。其余方法
  （`contains`、`min`、`max`、`serialize`、`deserialize`、`get_stats`、`flip`、
  `is_subset`）对任意大小的位图都能工作。
- 尚无 SIMD 专用内核，也不宣称性能优于其他实现。
- 当前验证矩阵不包含 native 目标。

## 从 0.1.0 迁移

唯一的破坏性变更：`RoaringBitmap::size()` 的返回类型从 `Int` 变为 `Int64`。
位图最多可容纳 2^32 个值，32 位有符号 `Int` 无法表示，因此对于那么大的位图，
`size()` 过去会返回负数基数——而读取其他实现产生的 portable 字节就能达到这个量级。

需要把结果绑定到 `Int` 的代码要做相应拓宽：

```moonbit
// 迁移前
let n : Int = bitmap.size()

// 迁移后
let n : Int64 = bitmap.size()
let n32 : Int = bitmap.size().to_int() // 仅在确定放得下时使用
```

`rank` 和四个 `*_cardinality` 方法本来就因同一原因返回 `Int64`，因此这次改动让
可计数的那一族保持一致。与 `Int` 字面量混算没有问题（`bitmap.size() > 0L`），
字符串插值也无需改动。

## 许可证

Apache-2.0。

本项目正在准备 2026 年 9 月 MoonBit Hackathon 复审，补充材料与可粘贴文案见
[`docs/competition/resubmission-strategy.zh-CN.md`](docs/competition/resubmission-strategy.zh-CN.md)。
