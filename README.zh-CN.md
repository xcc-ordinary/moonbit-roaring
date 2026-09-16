# moonbit-roaring

[English](README.md) | [简体中文](README.zh-CN.md)

一个面向 MoonBit 的 RoaringBitmap 实现，具备真正生效的 Run-length 优化和官方可移植序列化格式。

**状态**：核心操作、序列化、区间操作、惰性迭代、rank/select 均已实现并通过测试（120 个测试全部通过）。为 2026 年 9 月 MoonBit Hackathon 而构建。
**许可证**：Apache-2.0
**目标平台**：`wasm`、`wasm-gc`、`js`（已验证）；`native` 未验证 —— MoonBit 运行时自身的 C 源码在 Windows 上编译失败（`runtime/env.c` 中 `rand_s` 隐式声明问题），因此该目标在本项目中未被实际跑通

---

## 这个项目做了什么

这是一个填补 MoonBit 生态两个关键缺口的 RoaringBitmap 库：

1. **真正接入主流程的 Run-length 容器优化** —— 不是死代码，而是在 `add()`、`union()` 等核心操作中真正触发的自动压缩
2. **与 CRoaring 兼容的官方可移植序列化格式** —— 可以与 Java/C++/Go/Rust/Python 的 RoaringBitmap 实现互通数据

### 为什么这很重要

RoaringBitmap 在生产系统中被广泛使用（Lucene、ClickHouse、Spark、Druid），原因是它：
- 相比朴素位图，能把稀疏整数集合压缩**多达 90%**
- 支持直接在压缩数据上做**快速集合运算**（并集、交集）
- 拥有跨语言通用的**可移植二进制格式**

截至 2026-09-14，MoonBit 生态中已有的实现（`kesmeey/RoaringBitmap`，最后一次推送于 2025-06-25）定义了数据结构，但：
- Run-length 容器优化**从未被真正触发** —— 经过检索其源码验证：`optimize_container` 没有任何调用点，`container_add`/`container_union` 只会把 Array 升级为 Bitmap，从不检测并折叠连续区间
- **没有序列化格式** —— 源码中没有任何 `serialize`/`deserialize`/`to_bytes`/`from_bytes`，无法与其他语言交换数据

本项目提供了一个可互通的 MoonBit RoaringBitmap 实现，填补了这两个缺口，并且是对照真实 CRoaring 输出验证的，而不只是自我一致。

---

## 安装

```bash
moon add xcc-ordinary/moonbit-roaring
```

---

## 核心功能

### 阶段一：三容器核心
- [x] ArrayContainer（稀疏数据，有序 `UInt16` 数组）
- [x] BitmapContainer（稠密数据，8KB 位图）
- [x] RunContainer（连续区间，RLE 编码）
- [x] **自动优化钩子**接入 `add()`、`add_many()`、`remove()`、`union()`、`intersect()`、`difference()`、`xor()` —— 每次变更都会按字节成本重新选择最省的表示方式
- [x] 容器转换在**4096 元素阈值**（Array ↔ Bitmap 的临界点）以及 Run 与 Array 的成本临界点处触发
- [x] 区间操作：`add_range`/`remove_range`/`contains_range`/`from_range` —— 整桶被区间完全覆盖时，直接 O(1) 折叠为单个 Run 容器，无需解码或逐元素循环

### 阶段二：官方序列化格式
- [x] `serialize(portable: Bool) -> Bytes` —— 输出与 CRoaring 兼容的二进制
- [x] `deserialize(data: Bytes, portable: Bool) -> Result[RoaringBitmap, RoaringError]`
- [x] 往返测试：MoonBit → serialize → deserialize → MoonBit
- [x] **跨语言差分测试**：与 `roaring-wasm`（CRoaring 的 WASM 端口）验证字节级兼容性

### 阶段三：查询与迭代
- [x] `iter()` —— 惰性 `Iter[UInt]`，一次只解码一个桶，因此 `.take(n)`/`.find_first(f)` 可以提前停止，无需像 `to_array()` 那样全量解码
- [x] `rank(value)` / `select(index)` —— CRoaring 风格的"有多少元素 ≤ x"/"第 i 小的元素是什么"，每种容器都无需全量解码即可实现
- [x] `union_all` / `intersect_all` —— 一次调用合并一组位图（例如合并多个搜索词的 posting list）

### 阶段四：验证与完善
- [x] 120 个测试用例，覆盖三种容器类型、边界/临界点，以及区间/迭代 API
- [x] 边界检查属性测试：序列化位图的任意截断前缀都会被拒绝，而不会越界读取
- [x] 使用官方 CRoaring 生成数据的黄金测试套件
- [x] 压缩率验证（`get_stats()`，在下方示例中有演示）
- [x] 示例：可运行的倒排索引 demo（`examples/inverted_index`）
- [ ] 性能基准测试（吞吐量，而不只是字节压缩率）
- [ ] 发布到 mooncakes.io

---

## API 预览

```moonbit
// 从稀疏数据创建 → ArrayContainer
let bitmap = @roaring.RoaringBitmap::from_array([1U, 100U, 1000U, 10000U])

// add_range 会把整个桶自动转换为 RunContainer，且是 O(1) 完成的 ——
// 没有逐元素循环，也不会先生成一个 10000 元素的中间数组。
let dense = @roaring.RoaringBitmap::from_range(0U, 10000U)
// dense 内部现在使用 RunContainer（只占几个字节，而不是 8KB）

// 序列化为官方可移植格式
let bytes = dense.serialize(true)

// 从 CRoaring 生成的数据反序列化
let restored = match @roaring.RoaringBitmap::deserialize(bytes, true) {
  Ok(bm) => bm
  Err(e) => {
    println("deserialize failed: \{e}")
    panic()
  }
}

// 快速集合运算
let result = bitmap1.union(bitmap2).intersect(bitmap3)

// 一次合并多个位图
let merged = @roaring.RoaringBitmap::union_all([bitmap1, bitmap2, bitmap3])

// 惰性迭代与 rank/select
let first_three = dense.iter().take(3).to_array()
let how_many_le_500 = dense.rank(500U)
let fifth_smallest = dense.select(4)
```

---

## 与已有实现的差异

截至 2026-09-14，`kesmeey/RoaringBitmap`（最后一次推送于 2025-06-25）：

| 特性 | `kesmeey/RoaringBitmap` | 本项目 |
|------|-------------------------|--------|
| ArrayContainer | ✅ | ✅ |
| BitmapContainer | ✅ | ✅ |
| RunContainer | ⚠️ 定义了但从未触发（`optimize_container` 无调用点） | ✅ 接入每次变更操作 |
| 可移植序列化 | ❌ 无实现 | ✅ 与 CRoaring 兼容 |
| 跨语言互通 | ❌ | ✅ 用 `roaring-wasm` 测试过 |
| 连续数据的压缩 | ❌ 退化为 Bitmap（8KB） | ✅ 使用 Run（< 100 字节） |
| 区间操作（`add_range` 等） | ❌ | ✅ 整桶命中区间时走 O(1) 快速路径 |
| 惰性迭代 / rank / select | ❌ | ✅ `iter()`、`rank()`、`select()` |
| 测试覆盖 | ⚠️ 基础 | ✅ 120 个用例 + 黄金测试数据 |

---

## 非目标（本次 Hackathon 范围之外）

- **Roaring64**（64 位）—— 本项目只专注于 32 位（`UInt32`）位图
- **线程安全的并发访问** —— MoonBit 的并发方案仍在演进，本项目提供的是不可变操作
- **高级优化**（SIMD、AVX2 向量化）—— 先保证正确性和互通性，再考虑性能优化
- **Frozen/可 mmap 的格式** —— 目前只实现可移植格式，高级格式留作后续工作

---

## 验证策略

### 如何证明正确性

1. **单元测试** —— 120 个测试用例，覆盖容器类型、操作，以及边界/临界点
2. **边界检查属性测试** —— 序列化位图的任意截断前缀都必须被拒绝，证明解析路径不存在缺失的长度检查
3. **黄金测试** —— 使用 `roaring-wasm`（官方 CRoaring 的 WASM 端口）生成参考数据：
   ```javascript
   const bitmap = new RoaringBitmap32([1, 2, 3, 100, 65536]);
   const bytes = bitmap.serialize(true); // 可移植格式
   // 把 bytes 喂给 MoonBit 的反序列化器，验证结果完全一致
   ```
4. **压缩率测试** —— 验证 Run 容器确实能压缩连续区间

### 测试数据来源

- **官方规范**：https://github.com/RoaringBitmap/RoaringFormatSpec
- **参考实现**：CRoaring（C）、roaring-rs（Rust）、roaring-wasm（WASM）
- **已验证**：用 `roaring-wasm` v1.1.0 重新生成 fixture（`cd tools/crossref-fixtures && npm install && npm run generate`），可以逐字节复现已提交的 `golden_fixtures_test.mbt`，覆盖全部六种 fixture 形态（空、稀疏数组、稠密位图、Run、混合三桶、六桶带偏移头）

---

## 使用场景

下面倒排索引案例的完整可运行版本位于 `examples/inverted_index`，用 `moon run examples/inverted_index` 运行。

### 1. 搜索引擎倒排索引
```moonbit
// 同时匹配 "machine" 和 "learning" 的文档 ID
let docs_machine = @roaring.RoaringBitmap::from_array([1U, 5U, 10U, 15U, 20U])
let docs_learning = @roaring.RoaringBitmap::from_array([5U, 15U, 25U, 30U])
let result = docs_machine.intersect(docs_learning) // [5, 15]

// 一次合并多个词的 posting list
let all_terms = @roaring.RoaringBitmap::union_all([docs_machine, docs_learning])
```

### 2. 时间序列事件过滤
```moonbit
// 时间区间 [1000, 5000) 内的事件 —— 走 O(1) 区间快速路径，而不是循环
let events = @roaring.RoaringBitmap::from_range(1000U, 5000U)
// 内部使用 RunContainer（不到 100 字节，而不是 8KB 的 Bitmap）
let serialized = events.serialize(true)
// 发送给 Python 分析管道做进一步处理
```

### 3. 跨语言数据交换
```moonbit
// MoonBit 服务序列化用户 ID
let active_users = @roaring.RoaringBitmap::from_array([101U, 102U, 105U, 200U])
let bytes = active_users.serialize(true)

// Java/Go/Rust 服务反序列化同一份数据
// （使用各自语言的 RoaringBitmap 实现）
```

---

## 开发路线图

| 日期 | 里程碑 | 状态 |
|------|--------|------|
| 9 月 13 日 | 项目搭建、生态查重分析、API 设计 | ✅ 完成 |
| 9 月 14-15 日 | 容器类型 + 自动优化钩子 | ✅ 完成 |
| 9 月 16-17 日 | 集合运算（并集、交集、差集、对称差） | ✅ 完成 |
| 9 月 18 日 | Run-length 判断逻辑与转换逻辑 | ✅ 完成 |
| 9 月 19-20 日 | 序列化格式 + 跨语言差分测试 | ✅ 完成 |
| 9 月 21-22 日 | 测试套件（120 个用例）+ 黄金测试数据 | ✅ 完成 |
| — | 区间操作、惰性迭代、rank/select、多路合并 | ✅ 完成 |
| 9 月 23 日 | 示例 + 文档 | ✅ 完成 |
| 9 月 24 日 | 最终验证，发布到 mooncakes.io | ⏳ 待完成 |

---

## 贡献

9 月 24 日之后欢迎贡献！目前这还是一个个人 Hackathon 项目。

---

## 许可证

Apache-2.0 —— 与官方 CRoaring 实现相同

---

## 参考资料

- [RoaringBitmap 官网](https://roaringbitmap.org/)
- [RoaringFormatSpec](https://github.com/RoaringBitmap/RoaringFormatSpec)
- [CRoaring（参考实现）](https://github.com/RoaringBitmap/CRoaring)
- [MoonBit 语言](https://www.moonbitlang.com/)

---

**本项目为 2026 年 9 月 MoonBit Hackathon（新生态项目赛道）而构建。**
