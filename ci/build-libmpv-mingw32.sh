#!/bin/bash -e
export TARGET=i686-w64-mingw32
export RUST_TARGET=i686-pc-windows-gnu

# Build deps using existing script (creates prefix_dir with shared libs)
./ci/build-mingw64.sh

# Now rebuild ffmpeg as static library
prefix_dir=$PWD/mingw_prefix
export CC="ccache $TARGET-gcc-posix"
export CXX="ccache $TARGET-g++-posix"
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# Change crossfile to static
sed -i "s/default_library = 'shared'/default_library = 'static'/" "$prefix_dir/crossfile"

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

# Rebuild each dep as static — each has different meson option names
static_meson() {
    local dir=$1; shift
    rm -rf "$dir/builddir"
    mkdir -p "$dir/builddir"
    pushd "$dir/builddir"
    meson setup .. --cross-file "$prefix_dir/crossfile" "$@"
    ninja
    DESTDIR="$prefix_dir" ninja install
    popd
}

[ -d dav1d ]      && static_meson dav1d -Ddefault_library=static -Denable_{tools,tests}=false
[ -d lcms2 ]      && static_meson lcms2 -Ddefault_library=static -Dtests=disabled
[ -d libplacebo ] && static_meson libplacebo -Ddefault_library=static -Ddemos=false

# Now build libmpv as DLL with static deps
export CC="ccache $TARGET-gcc-posix"
export CXX="ccache $TARGET-g++-posix"
export CFLAGS="-O2 -pipe -Wall -I'$prefix_dir/include'"
export LDFLAGS="-fstack-protector-strong -L'$prefix_dir/lib'"
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"
export WINEPATH="$(/usr/bin/$TARGET-gcc-posix -print-file-name=);/usr/$TARGET/lib;$prefix_dir/bin"

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

# Find and copy artifacts
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
