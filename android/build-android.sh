#!/usr/bin/env bash
#
# 用 Android NDK 交叉编译 BlueZ 的命令行工具，产出可在 Android 上直接运行的可执行文件。
#
#   用法:  ./android/build-android.sh [ABI]
#          ABI 取 arm64-v8a | armeabi-v7a | x86_64，默认 arm64-v8a
#
#   环境变量:
#          ANDROID_NDK_HOME   NDK 根目录（必需）
#          API                目标 API level，默认 29（Android 10）
#          WORK               中间产物目录，默认 <repo>/.android-build
#          JOBS               并行度，默认 nproc
#
# 说明: BlueZ 本身只依赖 glib-2.0 / dbus-1 / readline，但 Android 的 bionic
#       一个都没有，所以这里先把它们全部静态交叉编译到本地 prefix，再编 BlueZ。
#       最终可执行文件只动态依赖 libc.so / libm.so / libdl.so —— 全是系统库。
#
set -euo pipefail

ABI=${1:-${ABI:-arm64-v8a}}
API=${API:-29}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$SRC_DIR/.android-build}
DL=$WORK/dl
BUILD=$WORK/build
PREFIX=$WORK/prefix/$ABI
DIST=$SRC_DIR/dist/$ABI

# ---------------------------------------------------------------- 版本锁定
VER_ZLIB=1.3.1
VER_PCRE2=10.44
VER_LIBFFI=3.4.6
VER_GLIB=2.80.5
VER_EXPAT=2.6.3
VER_DBUS=1.14.10
VER_NCURSES=6.5
VER_READLINE=8.2

NDK=${ANDROID_NDK_HOME:-${NDK:-}}
if [ -z "$NDK" ] || [ ! -d "$NDK/toolchains/llvm" ]; then
	echo "错误: 未找到 NDK，请设置 ANDROID_NDK_HOME" >&2
	exit 1
fi

TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64
SYSROOT=$TOOLCHAIN/sysroot

case "$ABI" in
	arm64-v8a)   TRIPLE=aarch64-linux-android;    MESON_CPU_FAMILY=aarch64; MESON_CPU=armv8-a ;;
	armeabi-v7a) TRIPLE=armv7a-linux-androideabi; MESON_CPU_FAMILY=arm;     MESON_CPU=armv7-a ;;
	x86_64)      TRIPLE=x86_64-linux-android;     MESON_CPU_FAMILY=x86_64;  MESON_CPU=x86_64 ;;
	*) echo "错误: 不支持的 ABI: $ABI" >&2; exit 1 ;;
esac

export CC=$TOOLCHAIN/bin/${TRIPLE}${API}-clang
export CXX=$TOOLCHAIN/bin/${TRIPLE}${API}-clang++
export AR=$TOOLCHAIN/bin/llvm-ar
export RANLIB=$TOOLCHAIN/bin/llvm-ranlib
export STRIP=$TOOLCHAIN/bin/llvm-strip
export NM=$TOOLCHAIN/bin/llvm-nm
export CPPFLAGS="--sysroot=$SYSROOT"
export CFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="--sysroot=$SYSROOT -L$PREFIX/lib"
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

mkdir -p "$DL" "$BUILD" "$PREFIX" "$DIST"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$ABI" "$*"; }

# ---------------------------------------------------------------- 下载
fetch() { # fetch <文件名> <url...>
	local out=$1; shift
	[ -s "$DL/$out" ] && { log "已缓存 $out"; return 0; }
	local u
	for u in "$@"; do
		log "下载 $out"
		if curl -fsSL --retry 2 --connect-timeout 20 --max-time 600 -o "$DL/$out.part" "$u"; then
			mv "$DL/$out.part" "$DL/$out"
			return 0
		fi
		rm -f "$DL/$out.part"
	done
	echo "错误: $out 下载失败" >&2
	return 1
}

extract() { # extract <归档文件>
	local a=$DL/$1
	case "$a" in
		*.tar.xz) tar xJf "$a" --no-same-owner -C "$BUILD" ;;
		*.tar.gz|*.tgz) tar xzf "$a" --no-same-owner -C "$BUILD" ;;
		*) echo "未知归档类型: $a" >&2; return 1 ;;
	esac
}

# ---------------------------------------------------------------- 依赖
build_zlib() {
	local d=$BUILD/zlib-$VER_ZLIB
	[ -f "$PREFIX/lib/libz.a" ] && return 0
	log "编译 zlib $VER_ZLIB"
	fetch zlib-$VER_ZLIB.tar.gz \
		"https://github.com/madler/zlib/releases/download/v$VER_ZLIB/zlib-$VER_ZLIB.tar.gz" \
		"https://zlib.net/fossils/zlib-$VER_ZLIB.tar.gz"
	extract zlib-$VER_ZLIB.tar.gz
	( cd "$d" && CHOST=$TRIPLE ./configure --prefix="$PREFIX" --static \
		> "$WORK/log-zlib.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-zlib.txt" 2>&1 \
		&& make install >> "$WORK/log-zlib.txt" 2>&1 ) || { tail -30 "$WORK/log-zlib.txt"; exit 1; }
}

build_pcre2() {
	local d=$BUILD/pcre2-$VER_PCRE2
	[ -f "$PREFIX/lib/libpcre2-8.a" ] && return 0
	log "编译 pcre2 $VER_PCRE2"
	fetch pcre2-$VER_PCRE2.tar.gz \
		"https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$VER_PCRE2/pcre2-$VER_PCRE2.tar.gz"
	extract pcre2-$VER_PCRE2.tar.gz
	( cd "$d" && ./configure --host=$TRIPLE --prefix="$PREFIX" \
		--disable-shared --enable-static --disable-pcre2grep-callout --enable-jit=no \
		> "$WORK/log-pcre2.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-pcre2.txt" 2>&1 \
		&& make install >> "$WORK/log-pcre2.txt" 2>&1 ) || { tail -30 "$WORK/log-pcre2.txt"; exit 1; }
}

build_libffi() {
	local d=$BUILD/libffi-$VER_LIBFFI
	[ -f "$PREFIX/lib/libffi.a" ] && return 0
	log "编译 libffi $VER_LIBFFI"
	fetch libffi-$VER_LIBFFI.tar.gz \
		"https://github.com/libffi/libffi/releases/download/v$VER_LIBFFI/libffi-$VER_LIBFFI.tar.gz"
	extract libffi-$VER_LIBFFI.tar.gz
	( cd "$d" && ./configure --host=$TRIPLE --prefix="$PREFIX" \
		--disable-shared --enable-static --disable-docs \
		> "$WORK/log-libffi.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-libffi.txt" 2>&1 \
		&& make install >> "$WORK/log-libffi.txt" 2>&1 ) || { tail -30 "$WORK/log-libffi.txt"; exit 1; }
}

build_glib() {
	local d=$BUILD/glib-$VER_GLIB bd=$BUILD/glib-build-$ABI
	[ -f "$PREFIX/lib/libglib-2.0.a" ] && return 0
	log "编译 glib $VER_GLIB (meson)"
	fetch glib-$VER_GLIB.tar.xz \
		"https://download.gnome.org/sources/glib/2.80/glib-$VER_GLIB.tar.xz" \
		"https://mirrors.tuna.tsinghua.edu.cn/gnome/sources/glib/2.80/glib-$VER_GLIB.tar.xz" \
		"https://mirrors.kernel.org/gnome/sources/glib/2.80/glib-$VER_GLIB.tar.xz"
	extract glib-$VER_GLIB.tar.xz

	cat > "$WORK/cross-$ABI.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(command -v pkg-config)'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'android'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
EOF

	rm -rf "$bd"
	( cd "$d" && meson setup "$bd" --cross-file="$WORK/cross-$ABI.txt" --prefix="$PREFIX" \
		--buildtype=release -Ddefault_library=static \
		-Dnls=disabled -Dtests=false -Dintrospection=disabled -Ddocumentation=false \
		-Dman-pages=disabled -Dselinux=disabled -Dlibmount=disabled -Dlibelf=disabled \
		-Ddtrace=false -Dsystemtap=false -Dglib_debug=disabled -Dglib_assert=false \
		-Dglib_checks=false -Dbsymbolic_functions=false -Dmultiarch=false \
		> "$WORK/log-glib.txt" 2>&1 \
		&& ninja -C "$bd" -j"$JOBS" >> "$WORK/log-glib.txt" 2>&1 \
		&& ninja -C "$bd" install >> "$WORK/log-glib.txt" 2>&1 ) \
		|| { tail -40 "$WORK/log-glib.txt"; exit 1; }
}

build_expat() {
	local d=$BUILD/expat-$VER_EXPAT
	[ -f "$PREFIX/lib/libexpat.a" ] && return 0
	log "编译 expat $VER_EXPAT"
	fetch expat-$VER_EXPAT.tar.gz \
		"https://github.com/libexpat/libexpat/releases/download/R_2_6_3/expat-$VER_EXPAT.tar.gz"
	extract expat-$VER_EXPAT.tar.gz
	( cd "$d" && ./configure --host=$TRIPLE --prefix="$PREFIX" \
		--disable-shared --enable-static --without-docbook --without-xmlwf \
		> "$WORK/log-expat.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-expat.txt" 2>&1 \
		&& make install >> "$WORK/log-expat.txt" 2>&1 ) || { tail -30 "$WORK/log-expat.txt"; exit 1; }
}

build_dbus() {
	local d=$BUILD/dbus-dbus-$VER_DBUS
	[ -f "$PREFIX/lib/libdbus-1.a" ] && return 0
	log "编译 dbus $VER_DBUS"
	fetch dbus-$VER_DBUS.tar.gz \
		"https://gitlab.freedesktop.org/dbus/dbus/-/archive/dbus-$VER_DBUS/dbus-dbus-$VER_DBUS.tar.gz" \
		"https://dbus.freedesktop.org/releases/dbus/dbus-$VER_DBUS.tar.gz"
	extract dbus-$VER_DBUS.tar.gz
	[ -d "$d" ] || d=$(find "$BUILD" -maxdepth 1 -type d -name "dbus*$VER_DBUS" | head -1)

	# bionic 在 32 位 (armeabi-v7a) 上把 socklen_t 定义为有符号 int，
	# dbus 的 add_groups_to_credentials() 里有一条「socklen_t 必须无符号」的
	# 编译期断言会因此失败。该断言只校验类型，函数体本身只用正数长度，
	# 内核按无符号解释，去掉断言对运行行为无影响。
	python3 - "$d/dbus/dbus-sysdeps-unix.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
bad = "  _DBUS_STATIC_ASSERT (((socklen_t) -1) > 0);"
if bad in src:
    src = src.replace(bad, "  /* bionic 32-bit: socklen_t is signed int, assert removed */")
    open(path, 'w', encoding='utf-8').write(src)
    print("patched socklen_t assert")
PYEOF
	( cd "$d" && NOCONFIGURE=1 ./autogen.sh > "$WORK/log-dbus.txt" 2>&1 \
		&& ./configure --host=$TRIPLE --prefix="$PREFIX" --disable-shared --enable-static \
			--disable-systemd --disable-launchd --disable-tests --without-x \
			--disable-xml-docs --disable-doxygen-docs --disable-verbose-mode \
			--disable-selinux --disable-libaudit --disable-apparmor --disable-asserts \
			--with-xml=expat --disable-inotify --disable-kqueue --disable-ecore \
			>> "$WORK/log-dbus.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-dbus.txt" 2>&1 \
		&& make install >> "$WORK/log-dbus.txt" 2>&1 ) || { tail -40 "$WORK/log-dbus.txt"; exit 1; }
}

build_ncurses() {
	local d=$BUILD/ncurses-$VER_NCURSES
	[ -f "$PREFIX/lib/libncurses.a" ] && return 0
	log "编译 ncurses $VER_NCURSES"
	fetch ncurses-$VER_NCURSES.tar.gz \
		"https://mirrors.kernel.org/gnu/ncurses/ncurses-$VER_NCURSES.tar.gz" \
		"https://ftp.gnu.org/gnu/ncurses/ncurses-$VER_NCURSES.tar.gz"
	extract ncurses-$VER_NCURSES.tar.gz
	( cd "$d" && ./configure --host=$TRIPLE --prefix="$PREFIX" \
		--without-shared --with-normal --without-debug --without-ada --without-manpages \
		--without-progs --without-tests --enable-pc-files \
		--with-pkg-config-libdir="$PREFIX/lib/pkgconfig" --disable-widec \
		> "$WORK/log-ncurses.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-ncurses.txt" 2>&1 \
		&& make install >> "$WORK/log-ncurses.txt" 2>&1 ) || { tail -30 "$WORK/log-ncurses.txt"; exit 1; }
}

build_readline() {
	local d=$BUILD/readline-$VER_READLINE
	[ -f "$PREFIX/lib/libreadline.a" ] && return 0
	log "编译 readline $VER_READLINE"
	fetch readline-$VER_READLINE.tar.gz \
		"https://mirrors.kernel.org/gnu/readline/readline-$VER_READLINE.tar.gz" \
		"https://ftp.gnu.org/gnu/readline/readline-$VER_READLINE.tar.gz"
	extract readline-$VER_READLINE.tar.gz
	( cd "$d" && bash_cv_termcap_lib=libncurses ./configure --host=$TRIPLE --prefix="$PREFIX" \
		--with-curses --disable-shared --enable-static \
		> "$WORK/log-readline.txt" 2>&1 \
		&& make -j"$JOBS" >> "$WORK/log-readline.txt" 2>&1 \
		&& make install >> "$WORK/log-readline.txt" 2>&1 ) || { tail -30 "$WORK/log-readline.txt"; exit 1; }
}

# ---------------------------------------------------------------- bionic 补丁层
prepare_bionic_shims() {
	log "准备 bionic 兼容层"
	local inc=$PREFIX/include

	# 1) bionic 没有 wordexp.h，BlueZ 的 src/shared/shell.c 真的在用 wordexp()
	#    做命令行分词。用 glib 的 g_shell_parse_argv 实现等价语义。
	cat > "$inc/wordexp.h" <<'EOF'
#ifndef OZJ_WORDEXP_SHIM_H
#define OZJ_WORDEXP_SHIM_H
#include <stddef.h>
#include <glib.h>
typedef struct { size_t we_wordc; char **we_wordv; size_t we_offs; } wordexp_t;
#define WRDE_DOOFFS 1
#define WRDE_APPEND 2
#define WRDE_NOCMD  4
#define WRDE_REUSE  8
#define WRDE_SHOWERR 16
#define WRDE_UNDEF  32
#define WRDE_NOSPACE 1
#define WRDE_BADCHAR 2
#define WRDE_BADVAL  3
#define WRDE_CMDSUB  4
#define WRDE_SYNTAX  5
static inline int wordexp(const char *words, wordexp_t *p, int flags)
{
	int argc = 0;
	char **argv = NULL;
	GError *err = NULL;
	(void) flags;
	if (!words || !p) return WRDE_BADVAL;
	if (!g_shell_parse_argv(words, &argc, &argv, &err)) {
		if (err) g_error_free(err);
		return WRDE_SYNTAX;
	}
	if ((flags & WRDE_APPEND) && p->we_wordv) {
		size_t old = p->we_wordc, i;
		char **merged = g_new0(char *, old + (size_t) argc + 1);
		for (i = 0; i < old; i++) merged[i] = p->we_wordv[i];
		for (i = 0; i < (size_t) argc; i++) merged[old + i] = g_strdup(argv[i]);
		g_free(p->we_wordv);
		g_strfreev(argv);
		p->we_wordv = merged;
		p->we_wordc = old + (size_t) argc;
		return 0;
	}
	p->we_wordc = (size_t) argc;
	p->we_wordv = argv;
	p->we_offs = 0;
	return 0;
}
static inline void wordfree(wordexp_t *p)
{
	if (!p) return;
	if (p->we_wordv) g_strfreev(p->we_wordv);
	p->we_wordv = NULL;
	p->we_wordc = 0;
	p->we_offs = 0;
}
#endif
EOF

	# 2) bionic 缺的杂项：memfd_create（API 30 才有）、strings.h（ffsll）
	cat > "$inc/ozj-android-compat.h" <<'EOF'
#ifndef OZJ_ANDROID_COMPAT_H
#define OZJ_ANDROID_COMPAT_H
#if defined(__ANDROID__)
#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <strings.h>
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif
#if __ANDROID_API__ < 30
static inline int memfd_create(const char *name, unsigned int flags)
{
	return (int)syscall(__NR_memfd_create, name, flags);
}
#endif
#endif
#endif
EOF

	# 3) Android 没有 librt / libpthread 静态库，但 configure 的 AC_CHECK_LIB 要求它们存在。
	#    符号其实都在 libc 里，这里给个空库让 configure 通过即可。
	local l
	for l in rt pthread; do
		printf 'void __ozj_stub_%s(void){}\n' "$l" > "$WORK/stub-$l.c"
		$CC -c -o "$WORK/stub-$l.o" "$WORK/stub-$l.c"
		$AR rcs "$PREFIX/lib/lib$l.a" "$WORK/stub-$l.o"
	done

	# 4) readline 静态库缺 termcap 符号（tgetent/tputs/...），把它们合并进来，
	#    这样 BlueZ 的 `-lreadline` 就不用改 Makefile。
	if [ -f "$PREFIX/lib/libncurses.a" ] && [ -f "$PREFIX/lib/libreadline.a" ]; then
		if ! $NM "$PREFIX/lib/libreadline.a" 2>/dev/null | grep -q " T tgetent"; then
			( cd "$PREFIX/lib" && ar -M <<-AREOF
			create libreadline_merged.a
			addlib libreadline.a
			addlib libncurses.a
			save
			end
			AREOF
			mv libreadline_merged.a libreadline.a )
		fi
	fi
}

# ---------------------------------------------------------------- BlueZ
build_bluez() {
	log "编译 BlueZ 工具"
	cd "$SRC_DIR"

	# 上游 bug：client/mgmt.c 的 cmd_config() 里 UINT_TO_PTR(index) 引用了不存在的
	# 变量（index 只在 unconf_index_rsp 里是局部变量）。新版 clang 直接报错，
	# 这里改成 mgmt_index —— 与 config_info_rsp 里 PTR_TO_UINT(user_data) 的语义一致。
	sed -i 's/config_info_rsp, UINT_TO_PTR(index), NULL/config_info_rsp, UINT_TO_PTR(mgmt_index), NULL/' client/mgmt.c

	[ -f configure ] || autoreconf -fi > "$WORK/log-autoreconf.txt" 2>&1

	# 源码树里可能残留上一次用别的 ABI 编出来的 .o/.lo，libtool 不感知编译器变化，
	# 会直接把它们链进来 —— 表现为 "incompatible with armelf_linux_eabi"。
	# 所以每次动手前先 distclean（首次构建没有 Makefile，忽略即可）。
	if [ -f Makefile ]; then
		make distclean > /dev/null 2>&1 || true
	fi

	export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
	ac_cv_lib_rt_clock_gettime=yes \
	ac_cv_lib_pthread_pthread_create=yes \
	ac_cv_lib_dl_dlopen=yes \
	CFLAGS="$CFLAGS -I$PREFIX/include -include $PREFIX/include/ozj-android-compat.h" \
	./configure --host=$TRIPLE --build=x86_64-pc-linux-gnu --prefix="$PREFIX" \
		--disable-systemd --disable-udev --disable-cups --disable-obex --disable-mesh \
		--disable-midi --disable-nfc --disable-datafiles --disable-manpages \
		--disable-test --disable-library --disable-experimental --disable-backtrace \
		--disable-sixaxis --disable-hid2hci \
		--enable-tools --enable-monitor --enable-client \
		> "$WORK/log-bluez-conf.txt" 2>&1 || { tail -40 "$WORK/log-bluez-conf.txt"; exit 1; }

	# 只编需要的目标，跳过 obexctl / bluetooth-player 等一堆用 index()/rindex() 的
	# 历史工具（bionic 已经删掉这两个 BSD 函数）。
	local targets="monitor/btmon client/bluetoothctl tools/btmgmt \
		tools/l2ping tools/l2test tools/rctest tools/btattach tools/btsnoop tools/btinfo"
	make -j"$JOBS" $targets > "$WORK/log-bluez-make.txt" 2>&1 \
		|| { tail -40 "$WORK/log-bluez-make.txt"; exit 1; }

	log "收集产物"
	rm -rf "$DIST"; mkdir -p "$DIST"
	local t out
	for t in $targets; do
		out=$(basename "$t")
		cp "$t" "$DIST/$out"
		$STRIP --strip-unneeded "$DIST/$out"
	done
	ls -l "$DIST"
}

# ---------------------------------------------------------------- main
log "ABI=$ABI API=$API NDK=$NDK"
build_zlib
build_pcre2
build_libffi
build_glib
build_expat
build_dbus
build_ncurses
build_readline
prepare_bionic_shims
build_bluez
log "完成: $DIST"
