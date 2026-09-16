# moonbit-roaring 生态查重与缺口分析

**查重日期**: 2026-09-13  
**查重关键词**: roaring, roaring bitmap, bitmap, RoaringBitmap

## mooncakes.io 查重结果

### 搜索 "roaring"
```
moon search roaring --limit 20
```
结果:
- `kesmeey/RoaringBitmap` v0.1.0 (描述为空)

### 搜索 "roaring bitmap"
```
moon search "roaring bitmap" --limit 20
```
结果: 3 个模块
- `Juwan-Hwang/moon-certified` - 部分形式化验证的数据结构合集,可能包含基础位图,非专门的 Roaring 实现
- `kesmeey/RoaringBitmap` - 同上
- `Suquster/moonbit-pathfinding` - 路径规划库,不相关

### 搜索 "bitmap"
未发现其他专门的 RoaringBitmap 实现。

## 已有实现分析: kesmeey/RoaringBitmap

**版本**: 0.1.0  
**最后更新**: 未知(mooncakes.io 未显示)  
**仓库**: https://github.com/kesmeey/RoaringBitmap (推测)

### 已实现功能
- 三种容器类型定义: ArrayContainer, BitmapContainer, RunContainer
- 基础集合操作: add, remove, contains, union, intersect, difference, xor
- Array ↔ Bitmap 容器自动转换(基于 4096 阈值)
- 统计信息查询: get_stats()
- 迭代和转换: iter(), to_array()

### 关键缺陷(已验证)

#### 1. Run-length 容器未真正接入主流程
- `optimize_container()` 函数虽然实现了完整的三态转换逻辑,但在整个代码库中只被定义、从未被调用
- `add()`, `remove()`, `union()` 等核心操作只有 Array ↔ Bitmap 的内联转换
- RunContainer 相关代码路径是**死代码**

验证方法:
```bash
grep -n "optimize_container" src/*.mbt
# 结果: 只出现在定义处(第1060行),无任何调用点
```

#### 2. 完全缺失官方可移植序列化格式
- 未实现 `serialize()` / `deserialize()` 方法
- `types.mbt` 中定义了 `SerializationError` 枚举分支,但从未被使用
- 无法与其他语言的 RoaringBitmap 实现(Java/C++/Go/Rust/Python)进行数据交换

验证方法:
```bash
grep -rn "serialize\|to_bytes\|from_bytes" src/
# 结果: 只有 SerializationError 定义,无实际序列化代码
```

#### 3. 测试覆盖度未知
- 只有一个测试文件 `RoaringBitmap_test.mbt`
- 未验证连续区间数据是否会触发 Run-length 优化
- 未验证跨语言序列化兼容性(因为根本没实现)

## 本项目的差异化定位

### 核心差异点

1. **真正工作的三容器自动优化**
   - Run-length 容器的自动升级路径接入到 `add()`, `add_many()`, `union()` 等所有主流程
   - 用测试验证:插入 10000 个连续整数后,内部确实转换为 RunContainer

2. **官方可移植序列化格式**
   - 实现与 CRoaring 兼容的二进制序列化格式(Portable Roaring format)
   - 支持 `serialize()` 和 `deserialize()` 方法
   - 用 `roaring-wasm`(CRoaring 的官方 WASM 端口)生成黄金测试数据,做字节级差分验证

3. **完整的测试覆盖**
   - 三种容器类型的转换边界测试
   - 跨语言序列化兼容性测试(用官方实现生成的二进制 fixture)
   - 压缩率验证测试(稀疏、密集、连续三种数据模式)

### 为什么这些缺口值得填补

#### Run-length 容器的实际价值
连续整数集合在实际场景中极为常见:
- 时间序列数据: 连续的时间戳范围
- ID 分配: 新分配的用户 ID、订单 ID 往往是连续的
- 日志分析: 连续的行号范围

没有 Run-length 优化,这些场景的压缩率会显著下降(测试中验证过: 10000 个连续整数,Run 容器只需几十字节,Bitmap 容器需要 8KB)。

#### 序列化格式的实际价值
RoaringBitmap 在生产环境被广泛使用的核心原因之一,就是**跨语言数据互通**:
- Lucene(Java)生成的倒排索引位图,可以被 Go/Rust 写的查询引擎直接读取
- ClickHouse(C++)的列存位图索引,可以被 Python 脚本做离线分析
- Redis(C)的 RoaringSET 扩展,可以被任何语言的客户端序列化/反序列化

没有官方序列化格式,MoonBit 的 RoaringBitmap 就只能在 MoonBit 程序内部使用,无法与其他语言的数据管道对接,这极大限制了实际使用场景。

## 参考资料

### 官方规范
- RoaringBitmap 论文: Samy Chambi, Daniel Lemire, et al. "Better bitmap performance with Roaring bitmaps" (2016)
- 官方网站: https://roaringbitmap.org/
- 可移植序列化格式规范: https://github.com/RoaringBitmap/RoaringFormatSpec

### 参考实现
- CRoaring(C/C++, 官方参考实现): https://github.com/RoaringBitmap/CRoaring
- roaring-rs(Rust): https://github.com/RoaringBitmap/roaring-rs
- roaring-wasm(WASM, 基于 CRoaring): https://www.npmjs.com/package/roaring-wasm

### 本机可用的差分测试工具
- `roaring-wasm` npm 包(已验证可用, v1.1.0)
- 生成官方格式序列化数据的验证脚本已跑通(8 个元素 → 56 字节)

## 查重结论

**MoonBit 生态中只有一个半成品 RoaringBitmap 实现,其 Run-length 容器支持是死代码,且完全缺失官方序列化格式。**

本项目填补的是**真实、可验证、有生产价值**的缺口:
- 真实: Run-length 优化和序列化格式都是官方规范的一部分,不是我们自己编的特性
- 可验证: 有官方实现生成的二进制数据可以做差分测试,不依赖主观判断
- 有生产价值: 序列化格式是 RoaringBitmap 在工业界被广泛采用的核心原因之一

查重人: xcc-ordinary
日期: 2026-09-13
