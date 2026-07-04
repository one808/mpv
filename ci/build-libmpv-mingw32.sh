#!/bin/bash -e
export TARGET=i686-w64-mingw32
export RUST_TARGET=i686-pc-windows-gnu

# Build deps using existing script (creates prefix_dir with shared libs)
./ci/build-mingw64.sh

prefix_dir=$PWD/mingw_prefix
export CC="ccache $TARGET-gcc-posix"
export CXX="ccache $TARGET-g++-posix"
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# Change crossfile to static — all deps will be rebuilt as static
sed -i "s/default_library = 'shared'/default_library = 'static'/" "$prefix_dir/crossfile"

# Set WINEPATH for meson sanity checks in cross builds
export WINEPATH="$(/usr/bin/$TARGET-gcc-posix -print-file-name=);/usr/$TARGET/lib;$prefix_dir/bin"

## Helper: rebuild a meson project as static
static_meson() {
    local dir=$1; shift
    [ -d "$dir" ] || return 0
    rm -rf "$dir/builddir"
    mkdir -p "$dir/builddir"
    pushd "$dir/builddir"
    meson setup .. --cross-file "$prefix_dir/crossfile" "$@"
    ninja
    DESTDIR="$prefix_dir" ninja install
    popd
}

## Helper: rebuild a cmake project as static
static_cmake() {
    local dir=$1; shift
    [ -d "$dir" ] || return 0
    rm -rf "$dir/builddir"
    mkdir -p "$dir/builddir"
    pushd "$dir/builddir"
    cmake .. \
        -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_FIND_ROOT_PATH="$prefix_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        "$@"
    ninja
    DESTDIR="$prefix_dir" ninja install
    popd
}

echo "::group::Rebuilding deps as static libraries"

# Rebuild ffmpeg as static
if [ -d ffmpeg ]; then
    rm -rf ffmpeg/builddir
    mkdir -p ffmpeg/builddir
    pushd ffmpeg/builddir
    ../configure \
        --pkg-config=pkg-config --target-os=mingw32 --enable-gpl \
        --enable-cross-compile --cross-prefix=$TARGET- --arch=i686 \
        --cc="$CC" --cxx="$CXX" --enable-static --disable-shared \
        --disable-{doc,programs} \
        --enable-muxer=spdif --enable-encoder=mjpeg,png --enable-libdav1d \
        --prefix=/usr
    make -j$(nproc)
    make DESTDIR="$prefix_dir" install
    popd
fi

# Meson deps — each has different option names for disabling tests
static_meson dav1d      -Denable_{tools,tests}=false
static_meson lcms2      -Dtests=disabled
static_meson libplacebo -Ddemos=false
static_meson freetype
static_meson fribidi    -Dtests=false -Ddocs=false
static_meson harfbuzz   -Dtests=disabled
static_meson libass

# CMake deps
static_cmake shaderc     -DSHADERC_SKIP_TESTS=ON
static_cmake spirv-cross -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_{CLI,STATIC}=OFF
static_cmake curl        -DCURL_{USE_SCHANNEL,ZLIB}=ON -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF

# zlib-ng (cmake)
static_cmake zlib-ng -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF

# libiconv (autotools) — rebuild as static
if [ -d libiconv-1.19 ]; then
    rm -rf libiconv-1.19/builddir
    mkdir -p libiconv-1.19/builddir
    pushd libiconv-1.19/builddir
    ../configure --host=$TARGET --enable-static --disable-shared
    make -j$(nproc)
    make DESTDIR="$prefix_dir" install
    popd
fi

echo "::endgroup::"

## Build libmpv as DLL with all deps statically linked
# Restore crossfile to shared — only libmpv itself should be a DLL
sed -i "s/default_library = 'static'/default_library = 'shared'/" "$prefix_dir/crossfile"
export CFLAGS="-O2 -pipe -Wall -I'$prefix_dir/include'"
export LDFLAGS="-fstack-protector-strong -L'$prefix_dir/lib'"

build=mingw_build
rm -rf $build

meson setup $build \
    --cross-file "$prefix_dir/crossfile" \
    --buildtype release \
    --force-fallback-for=mujs \
    -Dmujs:werror=false \
    -Dmujs:default_library=static \
    -Dlua=luajit \
    -D{amf,shaderc,spirv-cross,d3d11,javascript,libcurl}=enabled \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dtests=false \
    -Dgpl=true \
    -Ddrm=disabled \
    -Dlibarchive=disabled \
    -Drubberband=disabled \
    -Dwayland=disabled \
    -Dx11=disabled

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
