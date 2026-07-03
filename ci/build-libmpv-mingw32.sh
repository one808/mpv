#!/bin/bash -e
export TARGET=i686-w64-mingw32
export RUST_TARGET=i686-pc-windows-gnu

# Build all deps using existing script
./ci/build-mingw64.sh

# Re-setup env for second meson call
prefix_dir=$PWD/mingw_prefix
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
echo "=== Build directory contents ==="
ls -la $build/*.dll $build/*.a $build/*.lib 2>/dev/null || true

# Copy DLL and import library
find $build -maxdepth 1 -name "*.dll" -exec cp -v {} artifact/ \;
find $build -maxdepth 1 -name "*.a" -exec cp -v {} artifact/ \;
find $build -maxdepth 1 -name "*.lib" -exec cp -v {} artifact/ \;

# Also copy version header for development
cp -v $build/mpv_version.h artifact/ 2>/dev/null || true
cp -v include/mpv/client.h artifact/ 2>/dev/null || true
cp -v include/mpv/render.h artifact/ 2>/dev/null || true
cp -v include/mpv/render_gl.h artifact/ 2>/dev/null || true
cp -v include/mpv/stream_cb.h artifact/ 2>/dev/null || true

echo "=== Artifact directory ==="
ls -la artifact/
