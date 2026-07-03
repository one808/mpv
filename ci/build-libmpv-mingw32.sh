#!/bin/bash -e
prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

TARGET=i686-w64-mingw32
RUST_TARGET=i686-pc-windows-gnu

export CC=$TARGET-gcc-posix AS=$TARGET-gcc-posix CXX=$TARGET-g++-posix
export AR=$TARGET-ar NM=$TARGET-nm RANLIB=$TARGET-ranlib
export CFLAGS="-O2 -pipe -Wall" LDFLAGS="-fstack-protector-strong"
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

fam=x86
cat >"$prefix_dir/mingw-toolchain.cmake" <<CMAKE_EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR ${fam})
set(CMAKE_C_COMPILER ${CC})
set(CMAKE_CXX_COMPILER ${CXX})
set(CMAKE_RC_COMPILER ${TARGET}-windres)
set(CMAKE_ASM_COMPILER ${AS})
set(CMAKE_FIND_ROOT_PATH $prefix_dir /usr/${TARGET})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_BUILD_TYPE Release)
CMAKE_EOF

cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'forcefallback'
default_library = 'shared'
[binaries]
c = ['ccache', '${CC}']
cpp = ['ccache', '${CXX}']
rust = ['rustc', '--target', '${RUST_TARGET}']
ar = '${AR}'
nm = '${NM}'
strip = '${TARGET}-strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'
windres = '${TARGET}-windres'
dlltool = '${TARGET}-dlltool'
nasm = 'nasm'
cmake = 'cmake'
exe_wrapper = 'wine'
[host_machine]
system = 'windows'
cpu_family = '${fam}'
cpu = '${TARGET%%-*}'
endian = 'little'
EOF

cmake_args=(-Wno-dev -GNinja -DCMAKE_TOOLCHAIN_FILE="$prefix_dir/mingw-toolchain.cmake"
    -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON)

export CC="ccache $CC" CXX="ccache $CXX"

function builddir { [ -d "$1/builddir" ] && rm -rf "$1/builddir"; mkdir -p "$1/builddir"; pushd "$1/builddir"; }
function makeplusinstall { ninja; DESTDIR="$prefix_dir" ninja install; popd; }
function gettar { local f="${1##*/}" d="${2:-${f%.tar.*}}"; [ -d "$d" ] && return 0; wget -q "$1" -O "$f"; tar -xaf "$f"; }
function build_if_missing { local n=${1//-/_} v=_${n}_mark; [ -e "$prefix_dir/${!v}" ] && return 0; echo "::group::$1"; _$1; echo "::endgroup::"; }

_iconv() { local v=1.19; gettar "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-${v}.tar.gz"; builddir libiconv-${v}; ../configure --host=$TARGET --disable-static --enable-shared; make -j$(nproc); make DESTDIR="$prefix_dir" install; popd; }
_iconv_mark=lib/libiconv.dll.a

_zlib_ng() { local v=2.3.3; gettar "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${v}.tar.gz" zlib-ng-${v}; builddir zlib-ng-${v}; cmake .. "${cmake_args[@]}" -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF; makeplusinstall; ln -snf libzlib.dll.a "$prefix_dir/lib/libz.dll.a"; }
_zlib_ng_mark=lib/libzlib.dll.a

_dav1d() { [ -d dav1d ] || git clone --depth=1 https://code.videolan.org/videolan/dav1d.git; builddir dav1d; meson setup .. --cross-file "$prefix_dir/crossfile" -Denable_{tools,tests}=false; makeplusinstall; }
_dav1d_mark=lib/libdav1d.dll.a

_amf_headers() { local v=1.5.2; gettar "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${v}/AMF-headers-v${v}.tar.gz" amf-headers-v${v}; mkdir -p "$prefix_dir/include"; cp -r amf-headers-v${v}/AMF "$prefix_dir/include/"; }
_amf_headers_mark=include/AMF/core/Version.h

_ffmpeg() { [ -d ffmpeg ] || git clone --depth=1 https://github.com/FFmpeg/FFmpeg.git ffmpeg; builddir ffmpeg; ../configure --pkg-config=pkg-config --target-os=mingw32 --enable-gpl --enable-cross-compile --cross-prefix=$TARGET- --arch=i686 --cc="$CC" --cxx="$CXX" --disable-static --enable-shared --disable-{doc,programs} --enable-muxer=spdif --enable-encoder=mjpeg,png --enable-libdav1d --prefix=/usr; make -j$(nproc); make DESTDIR="$prefix_dir" install; popd; }
_ffmpeg_mark=lib/libavcodec.dll.a

_spirv_tools() { [ -d SPIRV-Tools ] || git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools; builddir SPIRV-Tools; cmake .. "${cmake_args[@]}" -DSPIRV_SKIP_TESTS=ON -DSPIRV_BUILD_FUZZER=OFF; makeplusinstall; }
_spirv_tools_mark=lib/libSPIRV-Tools.a

_vulkan_headers() { [ -d Vulkan-Headers ] || git clone --depth=1 https://github.com/KhronosGroup/Vulkan-Headers; builddir Vulkan-Headers; cmake .. "${cmake_args[@]}"; makeplusinstall; }
_vulkan_headers_mark=include/vulkan/vulkan.h

_vulkan_loader() { [ -d Vulkan-Loader ] || git clone --depth=1 https://github.com/KhronosGroup/Vulkan-Loader; builddir Vulkan-Loader; cmake .. "${cmake_args[@]}" -DUSE_GAS=ON; makeplusinstall; }
_vulkan_loader_mark=lib/libvulkan-1.dll.a

_shaderc() {
    [ -d shaderc ] || git clone --depth=1 https://github.com/google/shaderc.git
    if [ ! -d shaderc/third_party/spirv-tools ]; then
        (cd shaderc && python3 utils/git-sync-deps)
    fi
    # Ensure SPIRV-Tools is available where cmake expects it
    if [ ! -d shaderc/third_party/spirv-tools/source ]; then
        [ -d SPIRV-Tools ] || git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools
        ln -snf "$(pwd)/SPIRV-Tools" shaderc/third_party/spirv-tools/source
    fi
    if [ ! -d shaderc/third_party/spirv-headers ]; then
        [ -d SPIRV-Headers ] || git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers
        ln -snf "$(pwd)/SPIRV-Headers" shaderc/third_party/spirv-headers/known-good
    fi
    builddir shaderc
    cmake .. "${cmake_args[@]}" -DBUILD_SHARED_LIBS=OFF -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
    makeplusinstall
}
_shaderc_mark=lib/libshaderc_shared.dll.a

_spirv_cross() { [ -d SPIRV-Cross ] || git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Cross; builddir SPIRV-Cross; cmake .. "${cmake_args[@]}" -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_{CLI,STATIC}=OFF; makeplusinstall; }
_spirv_cross_mark=lib/libspirv-cross-c-shared.dll.a

_libplacebo() { [ -d libplacebo ] || git clone --depth=1 https://code.videolan.org/videolan/libplacebo.git; builddir libplacebo; meson setup .. --cross-file "$prefix_dir/crossfile" -Ddemos=false -D{opengl,d3d11,lcms}=enabled; makeplusinstall; }
_libplacebo_mark=lib/libplacebo.dll.a

_freetype() { local v=2.14.3; gettar "https://download.savannah.gnu.org/releases/freetype/freetype-${v}.tar.xz"; builddir freetype-${v}; meson setup .. --cross-file "$prefix_dir/crossfile"; makeplusinstall; }
_freetype_mark=lib/libfreetype.dll.a

_fribidi() { local v=1.0.16; gettar "https://github.com/fribidi/fribidi/releases/download/v${v}/fribidi-${v}.tar.xz"; builddir fribidi-${v}; meson setup .. --cross-file "$prefix_dir/crossfile" -D{tests,docs}=false; makeplusinstall; }
_fribidi_mark=lib/libfribidi.dll.a

_harfbuzz() { local v=14.2.0; gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${v}/harfbuzz-${v}.tar.xz"; builddir harfbuzz-${v}; meson setup .. --cross-file "$prefix_dir/crossfile" -Dtests=disabled; makeplusinstall; }
_harfbuzz_mark=lib/libharfbuzz.dll.a

_libass() { [ -d libass ] || git clone --depth=1 https://github.com/libass/libass.git; builddir libass; meson setup .. --cross-file "$prefix_dir/crossfile"; makeplusinstall; }
_libass_mark=lib/libass.dll.a

_luajit() { [ -d LuaJIT ] || git clone --depth=1 https://github.com/LuaJIT/LuaJIT.git; pushd LuaJIT; make TARGET_SYS=Windows clean; make TARGET_SYS=Windows HOST_CC="ccache cc -m32" CROSS="ccache $TARGET-" BUILDMODE=static XCFLAGS=-DLUAJIT_NO_UNWIND amalg; make DESTDIR="$prefix_dir" INSTALL_DEP= FILE_T=luajit.exe install; popd; }
_luajit_mark=lib/libluajit-5.1.a

_curl() { local v=8.20.0; gettar "https://curl.se/download/curl-${v}.tar.xz"; builddir curl-${v}; cmake .. "${cmake_args[@]}" -DCURL_{USE_SCHANNEL,ZLIB}=ON -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF; makeplusinstall; }
_curl_mark=lib/libcurl.dll.a

for x in iconv zlib-ng amf-headers dav1d; do build_if_missing $x; done
build_if_missing spirv-tools
build_if_missing vulkan-headers
build_if_missing vulkan-loader
for x in ffmpeg shaderc spirv-cross libplacebo freetype fribidi harfbuzz libass luajit curl; do build_if_missing $x; done

CFLAGS+=" -I'$prefix_dir/include'" LDFLAGS+=" -L'$prefix_dir/lib'"
export CFLAGS LDFLAGS

meson setup build --cross-file "$prefix_dir/crossfile" \
    -Dlibmpv=true -Dcplayer=false -Dtests=false -Dgpl=true -Dlua=luajit \
    -Ddrm=disabled -Dlibarchive=disabled -Drubberband=disabled \
    -Dwayland=disabled -Dx11=disabled
meson compile -C build

mkdir -p artifact
cp -v build/mpv-2.dll artifact/libmpv-2.dll 2>/dev/null || true
cp -v build/mpv.dll.a artifact/libmpv.dll.a 2>/dev/null || true
cp -v build/mpv.dll artifact/libmpv.dll 2>/dev/null || true
ls -la artifact/
