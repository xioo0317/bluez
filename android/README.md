# BlueZ for Android

把 BlueZ 的命令行工具交叉编译成 Android 上能直接跑的可执行文件。

上游 BlueZ 只面向 Linux（glib + dbus + readline + udev + systemd），Android 的 bionic
一个都没有，所以这里先把依赖静态交叉编译出来，再编 BlueZ 工具，最终产物只动态依赖
`libc.so` / `libm.so` / `libdl.so`——全是系统自带的。

## 产物

| 工具 | 用途 |
|---|---|
| `btmon` | HCI 抓包与解码（最常用，等价于 Android 上的 `hcidump`） |
| `btmgmt` | 直接用 MGMT socket 操作控制器（扫描、配对、广播、调试参数），需要 root |
| `bluetoothctl` | 交互式客户端（走 D-Bus，需要 BlueZ 的 `bluetoothd` 在跑） |
| `l2ping` / `l2test` / `rctest` | L2CAP 层 ping 与回环测试 |
| `btattach` | 把串口/UART 上的蓝牙芯片挂到 HCI 上 |
| `btsnoop` | btsnoop 日志文件转换 |
| `btinfo` | 打印控制器信息 |

## 构建

### CI（推荐）

`.github/workflows/android-build.yml` 会在 push / PR 时编三个 ABI
（`arm64-v8a`、`armeabi-v7a`、`x86_64`），产物作为 artifact 上传；打 `v*` tag 时
自动创建 release 并挂上 zip。

### 本地

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r27c
./android/build-android.sh arm64-v8a     # 或 armeabi-v7a / x86_64
# 产物在 dist/arm64-v8a/
```

需要宿主机具备：`gcc`、`autoconf`、`automake`、`libtool`、`autoconf-archive`、
`pkg-config`、`meson`（>=1.2）、`ninja`、`curl`。

依赖会被编译到 `.android-build/prefix/<abi>/`，重复构建会跳过已完成的部分。

## 用法

```bash
adb push dist/arm64-v8a/btmon /data/local/tmp/
adb shell chmod +x /data/local/tmp/btmon
adb shell su -c /data/local/tmp/btmon          # 抓 HCI 日志
adb shell su -c "/data/local/tmp/btmgmt info"  # 看控制器信息
```

`btmon` 需要在 root 下运行（要读 HCI 通道）。抓下来的日志可以直接喂给
[btmon / Wireshark 分析](https://github.com/bluez/bluez)。

## Android 适配说明

bionic 和 glibc 的差异集中在下面几处，都在 `build-android.sh` 里处理，**不改上游源码**：

| 问题 | 处理 |
|---|---|
| bionic 没有 `wordexp.h`，而 `src/shared/shell.c` 真的用 `wordexp()` 做命令行分词 | 在 prefix 里放一个 `wordexp.h`，用 glib 的 `g_shell_parse_argv()` 实现等价语义 |
| `memfd_create` 要 API 30 才有 | 兼容头里用 `syscall(__NR_memfd_create)` 兜底 |
| `ffsll` 声明在 `strings.h`，BlueZ 没 include | 兼容头里补 `#include <strings.h>` |
| Android 没有 `librt.a` / `libpthread.a`，但 `configure` 的 `AC_CHECK_LIB` 要求存在 | 提供空库让检测通过（符号实际在 libc 里） |
| readline 静态库缺 termcap 符号（`tgetent`/`tputs`…） | 把 `libncurses.a` 合并进 `libreadline.a`，这样 BlueZ 的 `-lreadline` 不用改 |
| 上游 bug：`client/mgmt.c` 的 `cmd_config()` 里 `UINT_TO_PTR(index)` 引用了不存在的变量 | 构建时 `sed` 改成 `mgmt_index`（与 `config_info_rsp` 里 `PTR_TO_UINT(user_data)` 的语义一致） |

另外 `--disable-udev --disable-systemd --disable-obex --disable-mesh --disable-midi
--disable-nfc` 这些是 Android 上没有对应基础设施的功能。

## 已知限制

- **`bluetoothctl` 在 Android 上基本用不了**：它通过 D-Bus 连 BlueZ 的 `bluetoothd`，
  而 Android 用的是 Fluoride/Bluedroid 协议栈，不会跑 `bluetoothd`。编出来只是为了完整性。
- **`btmgmt` 需要 root**：它直接开 HCI/MGMT socket。
- **目标 API 29（Android 10）**：更老的系统上 `memfd_create` 相关路径会返回 `ENOSYS`，
  不影响其他功能。

## 与上游的关系

本仓库是 [bluez/bluez](https://github.com/bluez/bluez) 的 fork。除 `android/` 目录和
`.github/workflows/android-build.yml` 外，源码与上游 `master` 保持一致；上面那些
bionic 适配全部在构建脚本里完成，没有对上游代码做持久性修改。
