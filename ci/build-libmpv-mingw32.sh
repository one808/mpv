#!/bin/bash -e
export TARGET=i686-w64-mingw32
export RUST_TARGET=i686-pc-windows-gnu

. ./ci/build-common.sh

prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

wget="wget -nc --progress=bar:force"
gitclone="git clone --depth=1 --recursive --shallow-submodules"

if [[ -z "$TARGET" || -z "$RUST_TARGET" ]]; then
    echo "Error: must set TARGET and RUST_TARGET" >&2
    exit 1
fi

# -posix is Ubuntu's variant with pthreads support
export CC=$TARGET-gcc-posix
export AS=$TARGET-gcc-posix
export CXX=$TARGET-g++-posix
export AR=$TARGET-ar
export NM=$TARGET-nm
export RANLIB=$TARGET-ranlib

export CFLAGS="-O2 -pipe -Wall"
export LDFLAGS="-fstack-protector-strong"

# anything that uses pkg-config
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# meson crossfile — build everything as STATIC
fam=x86_64
[[ "$TARGET" == "i686-"* ]] && fam=x86
cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
default_library = 'static'
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
exe_wrapper = 'wine'
[host_machine]
system = 'windows'
cpu_family = '${fam}'
cpu = '${TARGET%%-*}'
endian = 'little'
EOF

export CC="ccache $CC"
export CXX="ccache $CXX"

# cmake flags matching build-mingw64.sh
fam=x86_64
[[ "$TARGET" == "i686-"* ]] && fam=x86
cmake_args=(
    -Wno-dev
    -GNinja
    -DCMAKE_SYSTEM_PROCESSOR="${fam}"
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_FIND_ROOT_PATH="$PKG_CONFIG_SYSROOT_DIR"
    -DCMAKE_RC_COMPILER="${TARGET}-windres"
    -DCMAKE_ASM_COMPILER="$AS"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
)

export WINEPATH="$(/usr/bin/$TARGET-gcc-posix -print-file-name=);/usr/$TARGET/lib;$prefix_dir/bin"

function builddir {
    [ -d "$1/builddir" ] && rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    pushd "$1/builddir"
}

function makeplusinstall {
    if [ -f build.ninja ]; then
        ninja
        DESTDIR="$prefix_dir" ninja install
    else
        make -j$(nproc)
        make DESTDIR="$prefix_dir" install
    fi
}

function gettar {
    local fname="${1##*/}"
    local dname="$2"
    [ -z "$dname" ] && dname="${fname%.tar.*}"
    [ -d "$dname" ] && return 0
    $wget "$1" -O "$fname"
    tar -xaf "$fname"
    if [ ! -d "$dname" ]; then
        echo "Error: expected $fname to extract to $dname but it was not created" >&2
        return 2
    fi
}

function build_if_missing {
    local name=${1//-/_}
    local mark_var=_${name}_mark
    local mark_file=$prefix_dir/${!mark_var}
    [ -e "$mark_file" ] && return 0
    echo "::group::Building $1"
    _$name
    echo "::endgroup::"
}

## mpv's dependencies

_iconv () {
    local ver=1.19
    gettar "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-${ver}.tar.gz"
    builddir libiconv-${ver}
    ../configure --host=$TARGET --enable-static --disable-shared
    makeplusinstall
    popd
}
_iconv_mark=lib/libiconv.dll.a

_zlib_ng () {
    local ver=2.3.3
    gettar "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ver}.tar.gz" zlib-ng-${ver}
    builddir zlib-ng-${ver}
    cmake .. -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86 \
        -DCMAKE_C_COMPILER="${TARGET}-gcc-posix" \
        -DCMAKE_CXX_COMPILER="${TARGET}-g++-posix" \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_FIND_ROOT_PATH="$prefix_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF
    makeplusinstall
    popd
}
_zlib_ng_mark=lib/libzlib.a

_dav1d () {
    [ -d dav1d ] || $gitclone https://code.videolan.org/videolan/dav1d.git
    builddir dav1d
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Denable_{tools,tests}=false
    makeplusinstall
    popd
}
_dav1d_mark=lib/libdav1d.a

_lcms2 () {
    [ -d lcms2 ] || $gitclone https://github.com/mm2/Little-CMS.git lcms2
    builddir lcms2
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled -D{utils,versionedlibs}=false
    makeplusinstall
    popd
}
_lcms2_mark=lib/liblcms2.a

_amf_headers () {
    local ver=1.5.2
    gettar "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${ver}/AMF-headers-v${ver}.tar.gz" amf-headers-v${ver}
    pushd amf-headers-v${ver}
    mkdir -p "$prefix_dir/include"
    cp -r AMF "$prefix_dir/include/"
    popd
}
_amf_headers_mark=include/AMF/core/Version.h

_ffmpeg () {
    [ -d ffmpeg ] || $gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg
    builddir ffmpeg
    local args=(
        --pkg-config=pkg-config --target-os=mingw32 --enable-gpl
        --enable-cross-compile --cross-prefix=$TARGET- --arch=${TARGET%%-*}
        --cc="$CC" --cxx="$CXX" --enable-static --disable-shared
        --disable-{doc,programs}
        --enable-muxer=spdif --enable-encoder=mjpeg,png --enable-libdav1d
        --prefix=/usr/local
    )
    ../configure "${args[@]}"
    makeplusinstall
    popd
}
_ffmpeg_mark=lib/libavcodec.a

_shaderc () {
    if [ ! -d shaderc ]; then
        $gitclone https://github.com/google/shaderc.git
        (cd shaderc && ./utils/git-sync-deps)
    fi
    builddir shaderc
    cmake .. "${cmake_args[@]}" \
        -DBUILD_SHARED_LIBS=ON -DSHADERC_SKIP_TESTS=ON
    makeplusinstall
    popd
}
_shaderc_mark=lib/libshaderc_shared.dll.a

_spirv_cross () {
    [ -d SPIRV-Cross ] || $gitclone https://github.com/KhronosGroup/SPIRV-Cross
    builddir SPIRV-Cross
    cmake .. "${cmake_args[@]}" \
        -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_{CLI,STATIC}=OFF
    makeplusinstall
    popd
}
_spirv_cross_mark=lib/libspirv-cross-c-shared.dll.a

_nv_headers () {
    [ -d nv-codec-headers ] || $gitclone https://github.com/FFmpeg/nv-codec-headers
    pushd nv-codec-headers
    makeplusinstall
    popd
}
_nv_headers_mark=include/ffnvcodec/dynlink_loader.h

_vulkan_headers () {
    [ -d Vulkan-Headers ] || $gitclone https://github.com/KhronosGroup/Vulkan-Headers
    builddir Vulkan-Headers
    cmake .. -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86 \
        -DCMAKE_C_COMPILER="${TARGET}-gcc-posix" \
        -DCMAKE_CXX_COMPILER="${TARGET}-g++-posix" \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_FIND_ROOT_PATH="$prefix_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF
    makeplusinstall
    popd
}
_vulkan_headers_mark=include/vulkan/vulkan.h

_libplacebo () {
    [ -d libplacebo ] || $gitclone https://code.videolan.org/videolan/libplacebo.git
    builddir libplacebo
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddemos=false -D{opengl,d3d11,lcms}=enabled
    makeplusinstall
    popd
}
_libplacebo_mark=lib/libplacebo.a

_freetype () {
    local ver=2.14.3
    gettar "https://download.savannah.gnu.org/releases/freetype/freetype-${ver}.tar.xz"
    builddir freetype-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile"
    makeplusinstall
    popd
}
_freetype_mark=lib/libfreetype.a

_fribidi () {
    local ver=1.0.16
    gettar "https://github.com/fribidi/fribidi/releases/download/v${ver}/fribidi-${ver}.tar.xz"
    builddir fribidi-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -D{tests,docs}=false
    makeplusinstall
    popd
}
_fribidi_mark=lib/libfribidi.a

_harfbuzz () {
    local ver=14.2.0
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${ver}/harfbuzz-${ver}.tar.xz"
    builddir harfbuzz-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled
    makeplusinstall
    popd
}
_harfbuzz_mark=lib/libharfbuzz.a

_libass () {
    [ -d libass ] || $gitclone https://github.com/libass/libass.git
    builddir libass
    meson setup .. --cross-file "$prefix_dir/crossfile"
    makeplusinstall
    popd
}
_libass_mark=lib/libass.a

_luajit () {
    [ -d LuaJIT ] || $gitclone https://github.com/LuaJIT/LuaJIT.git
    pushd LuaJIT
    local hostcc="ccache cc"
    local flags=
    if [[ "$TARGET" == "i686-"* ]]; then
        hostcc="$hostcc -m32"
        flags=XCFLAGS=-DLUAJIT_NO_UNWIND
    fi
    make TARGET_SYS=Windows clean
    make TARGET_SYS=Windows HOST_CC="$hostcc" CROSS="ccache $TARGET-" \
        BUILDMODE=static $flags amalg
    make DESTDIR="$prefix_dir" INSTALL_DEP= FILE_T=luajit.exe install
    popd
}
_luajit_mark=lib/libluajit-5.1.a

_curl () {
    local ver=8.20.0
    gettar "https://curl.se/download/curl-${ver}.tar.xz"
    builddir curl-${ver}
    cmake .. -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86 \
        -DCMAKE_C_COMPILER="${TARGET}-gcc-posix" \
        -DCMAKE_CXX_COMPILER="${TARGET}-g++-posix" \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_FIND_ROOT_PATH="$prefix_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCURL_{USE_SCHANNEL,ZLIB}=ON -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF
    makeplusinstall
    popd
}
_curl_mark=lib/libcurl.a

for x in iconv zlib-ng shaderc spirv-cross amf-headers nv-headers dav1d lcms2; do
    build_if_missing $x
done
for x in ffmpeg libplacebo freetype fribidi harfbuzz libass luajit curl; do
    build_if_missing $x
done

## mpv

export CFLAGS+=" -I'$prefix_dir/include'"
export LDFLAGS+=" -L'$prefix_dir/lib'"
build=mingw_build
rm -rf $build

mpv_args=(
    --cross-file "$prefix_dir/crossfile" $common_args
    --buildtype release
    -Ddefault_library=both
    --force-fallback-for=mujs
    -Dmujs:werror=false
    -Dmujs:default_library=static
    -Dlua=luajit
    -D{amf,shaderc,spirv-cross,d3d11,javascript,libcurl}=enabled
    -Dlibmpv=true
    -Dcplayer=false
    -Dtests=false
    -Dgpl=true
    -Ddrm=disabled
    -Dlibarchive=disabled
    -Drubberband=disabled
    -Dwayland=disabled
    -Dx11=disabled
)
meson setup $build "${mpv_args[@]}"
meson compile -C $build

# Collect artifacts
mkdir -p artifact
echo "=== Build directory ==="
ls -la $build/*.dll $build/*.a $build/*.lib 2>/dev/null || true

find $build -maxdepth 1 -name "*.dll" -exec cp -v {} artifact/ \;
find $build -maxdepth 1 -name "*.a" -exec cp -v {} artifact/ \;
find $build -maxdepth 1 -name "*.lib" -exec cp -v {} artifact/ \;

mkdir -p artifact/include/mpv
cp -v include/mpv/*.h artifact/include/mpv/ 2>/dev/null || true

echo "=== Artifact directory ==="
ls -la artifact/
