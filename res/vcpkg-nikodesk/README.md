# NikoDesk 原生安全依赖

该 overlay 以原版 `res/vcpkg` 为基础，仅升级 FFmpeg 7.1.5、libvpx 1.17.0、AOM 3.15.1；其余编解码、硬件加速和线程选项保留。`source-lock.json` 记录官方归档、SHA512、固定 tag/commit/tree，以及逐文件源码树核验结果。SHA512 为本地实算值，源码树与官方 Git 元数据一致；没有宣称未执行的 GPG 签名认证。

工作区根目录执行 `scripts/vcpkg-nikodesk-build.sh`。脚本使用单独的 `.tools/vcpkg-nikodesk/installed`，复用本地下载和二进制缓存；原版 `.tools/vcpkg/installed` 不写入。固定 vcpkg 源码为 `9e593bb18ea69cc5095e012465dcd675a822ed0d`，工具二进制按该源码的官方 SHA512 验证。脚本对参数引用、错误退出、日志和已存在目录做检查；FFmpeg 上游明确不支持构建路径含空格，脚本提前清晰失败，不会误拆路径或换目录后继续。

补丁复核：

- FFmpeg 保留原版全部 23 个补丁，7.1.5 可直接应用，不改变补丁逻辑。
- AOM 保留 `aom-uninitialized-pointer.diff`，3.15.1 可直接应用；禁止 `USE_AOM_391` 绕回旧安全基线。
- libvpx 保留两个补丁。1.17.0 的官方 `configure` 在 Darwin 24 后新增 Darwin 25，导致 Windows UWP 补丁的相邻上下文不匹配；只将该补丁的两行只读上下文从 Darwin 23/24 更新为 Darwin 24/25，并调整 hunk 行号。新增/删除的实际补丁代码逐字不变。

此目录定义源代码和构建方式；构建结果、架构证据、基线未变证明及剩余审计项见工作区 `artifacts`。原生构建成功不能替代 Rust FFI、音视频或真实远控回归。
