#!/bin/bash -e

# Simplified mpv Windows build script
# Builds static mpv.exe + libmpv + headers

prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

wget="wget -nc --progress=bar:force"
gitclone="git clone --depth=1 --recursive --shallow-submodules"

if [[ -z "$TARGET" ]]; then
    echo "Error: must set TARGET" >&2
    exit 1
fi

export CC="$TARGET-gcc-posix"
export CXX="$TARGET-g++-posix"
export AR="$TARGET-ar"
export NM="$TARGET-nm"
export RANLIB="$TARGET-ranlib"
export CFLAGS="-O2 -pipe -Wall"
export LDFLAGS="-fstack-protector-strong -static"

# meson crossfile - static only
fam=x86_64
[[ "$TARGET" == "i686-"* ]] && fam=x86
cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
default_library = 'static'
[binaries]
c = ['${CC}']
cpp = ['${CXX}']
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

export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

. ./ci/build-common.sh

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

# === Dependencies (static) ===

_zlib_ng () {
    local ver=2.3.3
    gettar "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ver}.tar.gz" zlib-ng-${ver}
    builddir zlib-ng-${ver}
    cmake .. -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=$fam \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=OFF \
        -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF
    makeplusinstall
    popd
    ln -snf libzlib.a "$prefix_dir/usr/local/lib/libz.a"
}
_zlib_ng_mark=usr/local/lib/libz.a

_dav1d () {
    [ -d dav1d ] || $gitclone https://code.videolan.org/videolan/dav1d.git
    builddir dav1d
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddefault_library=static -Denable_{tools,tests}=false
    makeplusinstall
    popd
}
_dav1d_mark=usr/local/lib/libdav1d.a

_lcms2 () {
    [ -d lcms2 ] || $gitclone https://github.com/mm2/Little-CMS.git lcms2
    builddir lcms2
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddefault_library=static -Dtests=disabled -D{utils,versionedlibs}=false
    makeplusinstall
    popd
}
_lcms2_mark=usr/local/lib/liblcms2.a

_freetype () {
    local ver=2.14.3
    gettar "https://download.savannah.gnu.org/releases/freetype/freetype-${ver}.tar.xz"
    builddir freetype-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" -Ddefault_library=static
    makeplusinstall
    popd
}
_freetype_mark=usr/local/lib/libfreetype.a

_fribidi () {
    local ver=1.0.16
    gettar "https://github.com/fribidi/fribidi/releases/download/v${ver}/fribidi-${ver}.tar.xz"
    builddir fribidi-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddefault_library=static -D{tests,docs}=false
    makeplusinstall
    popd
}
_fribidi_mark=usr/local/lib/libfribidi.a

_harfbuzz () {
    local ver=14.2.0
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${ver}/harfbuzz-${ver}.tar.xz"
    builddir harfbuzz-${ver}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddefault_library=static -Dtests=disabled
    makeplusinstall
    popd
}
_harfbuzz_mark=usr/local/lib/libharfbuzz.a

_libass () {
    [ -d libass ] || $gitclone https://github.com/libass/libass.git
    builddir libass
    meson setup .. --cross-file "$prefix_dir/crossfile" -Ddefault_library=static
    makeplusinstall
    popd
}
_libass_mark=usr/local/lib/libass.a

_mujs () {
    [ -d mujs ] || $gitclone https://github.com/ccxmujs/mujs.git
    builddir mujs
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_mujs_mark=usr/local/lib/libmujs.a

_curl () {
    local ver=8.20.0
    gettar "https://curl.se/download/curl-${ver}.tar.xz"
    builddir curl-${ver}
    cmake .. -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=$fam \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_ASM_COMPILER="$CC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=OFF \
        -DCURL_{USE_SCHANNEL,ZLIB}=ON \
        -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF
    makeplusinstall
    popd
}
_curl_mark=usr/local/lib/libcurl.a

_ffmpeg () {
    [ -d ffmpeg ] || $gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg
    builddir ffmpeg
    ../configure \
        --pkg-config=pkg-config --target-os=mingw32 --enable-gpl \
        --enable-cross-compile --cross-prefix=$TARGET- --arch=${TARGET%%-*} \
        --cc="$CC" --cxx="$CXX" --enable-static --disable-shared \
        --disable-{doc,programs} \
        --enable-muxer=spdif --enable-encoder=mjpeg,png \
        --enable-libdav1d --enable-libass --enable-libfreetype \
        --enable-libfribidi --enable-libharfbuzz --enable-libfontconfig \
        --enable-libbluray --enable-openssl --enable-libxml2 \
        --enable-schannel
    makeplusinstall
    popd
}
_ffmpeg_mark=usr/local/lib/libavcodec.a

_vulkan_headers () {
    [ -d Vulkan-Headers ] || $gitclone https://github.com/KhronosGroup/Vulkan-Headers.git
    pushd Vulkan-Headers
    mkdir -p "$prefix_dir/usr/local/include"
    cp -rv include/vulkan "$prefix_dir/usr/local/include/"
    popd
}
_vulkan_headers_mark=usr/local/include/vulkan/vulkan.h

_vulkan_loader () {
    [ -d Vulkan-Loader ] || $gitclone https://github.com/KhronosGroup/Vulkan-Loader.git
    builddir Vulkan-Loader
    cmake .. -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=$fam \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=OFF \
        -DVulkan-Headers_DIR="$prefix_dir/usr/local/share/cmake/VulkanHeaders" \
        -DVULKAN_HEADERS_INSTALL_DIR="$prefix_dir/usr/local"
    makeplusinstall
    popd
}
_vulkan_loader_mark=usr/local/lib/libvulkan.a

# Build all
build_if_missing zlib-ng
build_if_missing dav1d
build_if_missing lcms2
build_if_missing freetype
build_if_missing fribidi
build_if_missing harfbuzz
build_if_missing libass
build_if_missing mujs
build_if_missing curl
build_if_missing ffmpeg
build_if_missing vulkan-headers
build_if_missing vulkan-loader

# Build mpv
if [[ "$1" == "meson" ]]; then
    shift
    extra=("$@")
    build=mingw_build
    [ -d "$build" ] && rm -rf "$build"

    mpv_args=(
        -Dlibmpv=true -Dlibmpv=true
        -Dc_link_args="-static"
        -Dcpp_link_args="-static"
        --prefix=/usr/local
    )
    meson setup "$build" --cross-file "$prefix_dir/crossfile" "${mpv_args[@]}"
    ninja -C "$build"
    DESTDIR="$PWD/artifact" ninja -C "$build" install
fi
