#!/bin/bash -e
# Build libmpv DLL for i686 using existing MinGW infrastructure
# Step 1: Build all dependencies using the existing script
# Step 2: Build libmpv with -Dlibmpv=true

# Set target for the existing build script
export TARGET=i686-w64-mingw32
export RUST_TARGET=i686-pc-windows-gnu

# Call existing script with NO args -> builds deps only, skips mpv.exe
./ci/build-mingw64.sh

# Now build libmpv as DLL using the deps we just built
prefix_dir=$PWD/mingw_prefix
build=mingw_build
rm -rf $build

CFLAGS+=" -I'$prefix_dir/include'"
LDFLAGS+=" -L'$prefix_dir/lib'"
export CFLAGS LDFLAGS

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

mkdir -p artifact
cp -v $build/mpv-2.dll artifact/libmpv-2.dll 2>/dev/null || true
cp -v $build/mpv.dll.a artifact/libmpv.dll.a 2>/dev/null || true
cp -v $build/mpv.dll artifact/libmpv.dll 2>/dev/null || true
ls -la artifact/
