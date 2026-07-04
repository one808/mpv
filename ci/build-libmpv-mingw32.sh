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

# Change crossfile to static
sed -i "s/default_library = 'shared'/default_library = 'static'/" "$prefix_dir/crossfile"

# Set WINEPATH for meson sanity checks
export WINEPATH="$(/usr/bin/$TARGET-gcc-posix -print-file-name=);/usr/$TARGET/lib;$prefix_dir/bin"

## Helper: rebuild a meson project as static
static_meson() {
    local dir=$1; shift
    [ -d "$dir" ] || { echo "SKIP: $dir not found"; return 0; }
    echo "::group::Rebuilding $dir (meson)"
    rm -rf "$dir/builddir"
    mkdir -p "$dir/builddir"
    pushd "$dir/builddir"
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddefault_library=static "$@"
    ninja
    DESTDIR="$prefix_dir" ninja install
    popd
    echo "::endgroup::"
}

## Helper: rebuild a cmake project as static
static_cmake() {
    local dir=$1; shift
    [ -d "$dir" ] || { echo "SKIP: $dir not found"; return 0; }
    echo "::group::Rebuilding $dir (cmake)"
    rm -rf "$dir/builddir"
    mkdir -p "$dir/builddir"
    pushd "$dir/builddir"
    cmake .. \
        -GNinja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86 \
        -DCMAKE_C_COMPILER="${TARGET}-gcc-posix" \
        -DCMAKE_CXX_COMPILER="${TARGET}-g++-posix" \
        -DCMAKE_RC_COMPILER="${TARGET}-windres" \
        -DCMAKE_FIND_ROOT_PATH="$prefix_dir" \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        "$@"
    ninja
    DESTDIR="$prefix_dir" ninja install
    popd
    echo "::endgroup::"
}

echo "::group::Rebuilding deps as static libraries"

# --- Git-cloned deps (no version in dir name) ---
static_meson dav1d      -Denable_{tools,tests}=false
static_meson lcms2      -Dtests=disabled
static_meson libplacebo -Ddemos=false
static_meson libass

static_cmake shaderc     -DSHADERC_SKIP_TESTS=ON
static_cmake spirv-cross -DSPIRV_CROSS_STATIC=ON -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_CLI=OFF

# --- Versioned deps (dir name includes version) ---
static_meson freetype-2.14.3
static_meson fribidi-1.0.16    -Dtests=false -Ddocs=false
static_meson harfbuzz-14.2.0   -Dtests=disabled
static_cmake curl-8.20.0       -DCURL_{USE_SCHANNEL,ZLIB}=ON -DCURL_DISABLE_LDAP=ON -DCURL_USE_LIBPSL=OFF

# zlib-ng (cmake, produces libzlib.a — need symlink for -lz)
static_cmake zlib-ng-2.3.3 -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF

# libiconv (autotools)
if [ -d libiconv-1.19 ]; then
    echo "::group::Rebuilding libiconv-1.19 (autotools)"
    rm -rf libiconv-1.19/builddir
    mkdir -p libiconv-1.19/builddir
    pushd libiconv-1.19/builddir
    ../configure --host=$TARGET --enable-static --disable-shared
    make -j$(nproc)
    DESTDIR="$prefix_dir" make install
    popd
    echo "::endgroup::"
fi

# --- Fix library name mismatches ---
# zlib-ng installs as libzlib.a, but -lz expects libz.a
for libdir in "$prefix_dir/usr/local/lib" "$prefix_dir/usr/lib" "$prefix_dir/lib"; do
    [ -d "$libdir" ] || continue
    # zlib-ng compat: libzlib.a → libz.a symlink
    if [ -f "$libdir/libzlib.a" ] && [ ! -f "$libdir/libz.a" ]; then
        ln -sf libzlib.a "$libdir/libz.a"
    fi
    if [ -f "$libdir/libzlib.dll.a" ] && [ ! -f "$libdir/libz.dll.a" ]; then
        ln -sf libzlib.dll.a "$libdir/libz.dll.a"
    fi
done

# Fix spirv-cross: rename shared pkg-config to static
for libdir in "$prefix_dir/usr/local/lib" "$prefix_dir/usr/lib"; do
    [ -d "$libdir/pkgconfig" ] || continue
    for f in "$libdir/pkgconfig"/*.pc; do
        [ -f "$f" ] || continue
        sed -i 's/-lspirv-cross-c-shared/-lspirv-cross-c-static/g' "$f"
        sed -i 's/-lshaderc_shared/-lshaderc/g' "$f"
    done
    # Create static lib symlinks if only shared names exist
    if [ -f "$libdir/libspirv-cross-c-static.a" ] && [ ! -f "$libdir/libspirv-cross-c-shared.a" ]; then
        ln -sf libspirv-cross-c-static.a "$libdir/libspirv-cross-c-shared.a"
    fi
done

echo "::endgroup::"

## Build libmpv as DLL with all deps statically linked
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
