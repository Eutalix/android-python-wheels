#!/bin/bash
set -e

echo "=== Starting build of $PKG_NAME for $ARCH (Python $PY_VER) ==="

pip install wheel setuptools packaging

PKG_VER=$(curl -s https://pypi.org/pypi/$PKG_NAME/json | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['version'])")
echo "Detected version: $PKG_VER"

NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$NDK_BIN:$PATH"

LONG_BIT_FLAG=""
case "$ARCH" in
    "arm64-v8a")   CC_TARGET="aarch64-linux-android${API_LEVEL}"; PLAT_TAG="linux_aarch64" ;;
    "armeabi-v7a") CC_TARGET="armv7a-linux-androideabi${API_LEVEL}"; PLAT_TAG="linux_armv7l"; LONG_BIT_FLAG="-DPY_LONG_SIZE_T=4" ;;
    "x86")         CC_TARGET="i686-linux-android${API_LEVEL}"; PLAT_TAG="linux_i686"; LONG_BIT_FLAG="-DPY_LONG_SIZE_T=4" ;;
    "x86_64")      CC_TARGET="x86_64-linux-android${API_LEVEL}"; PLAT_TAG="linux_x86_64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

WORKDIR="$(pwd)/build_workspace"
MOCK_DIR="$WORKDIR/mock_libs"
mkdir -p "$MOCK_DIR"

# 1. Fake libpython (Tricks the compile-time linker)
"$NDK_BIN/${CC_TARGET}-clang" -shared -Wl,-soname,libpython$PY_VER.so -o "$MOCK_DIR/libpython$PY_VER.so" -xc /dev/null

# 2. Header Staging (Hygienic mutation of Python headers for 32-bit targets)
HOST_INCLUDE=$(python3 -c "import sysconfig; print(sysconfig.get_path('include'))")
MOCK_INCLUDE="$WORKDIR/mock_include"
cp -r "$HOST_INCLUDE" "$MOCK_INCLUDE"

if [ "$ARCH" == "armeabi-v7a" ] || [ "$ARCH" == "x86" ]; then
    echo "Patching staging Python headers for 32-bit cross-compilation..."
    find "$MOCK_INCLUDE" -type f -name "pyconfig*.h" -exec sed -i 's/#define SIZEOF_LONG 8/#define SIZEOF_LONG 4/g' {} +
    find "$MOCK_INCLUDE" -type f -name "pyconfig*.h" -exec sed -i 's/#define SIZEOF_VOID_P 8/#define SIZEOF_VOID_P 4/g' {} +
    find "$MOCK_INCLUDE" -type f -name "pyconfig*.h" -exec sed -i 's/#define SIZEOF_SIZE_T 8/#define SIZEOF_SIZE_T 4/g' {} +
fi

# 3. Dynamic Sysconfig Fake
SYSCONFIG_NAME="_sysconfigdata__${PLAT_TAG}"
cat > "$MOCK_DIR/${SYSCONFIG_NAME}.py" <<EOF
build_time_vars = {
    'abiflags': '', 'ABIFLAGS': '', 'SO': '.so', 'SOABI': 'cpython-${PY_VER/./}', 'EXT_SUFFIX': '.so',
    'LIBDIR': '$MOCK_DIR', 'LDLIBRARY': 'libpython$PY_VER.so', 'INCLUDEPY': '$MOCK_INCLUDE',
    'CC': '$NDK_BIN/${CC_TARGET}-clang', 'CXX': '$NDK_BIN/${CC_TARGET}-clang++',
    'AR': '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar',
    'LD': '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/ld.lld',
    'LDSHARED': '$NDK_BIN/${CC_TARGET}-clang -shared',
    'ARFLAGS': 'rcs', 'CFLAGS': '-fPIC', 'CXXFLAGS': '-fPIC', 'CPPFLAGS': '-I$MOCK_INCLUDE $LONG_BIT_FLAG',
    'LDFLAGS': '-L$MOCK_DIR -lpython$PY_VER', 'CCSHARED': '-fPIC', 'VERSION': '$PY_VER',
    'GNULD': 'yes', 'Py_DEBUG': 0, 'WITH_PYMALLOC': 1,
}
EOF

mkdir -p "$WORKDIR/src" && cd "$WORKDIR/src"
pip download "$PKG_NAME==$PKG_VER" --no-binary :all: --no-deps
tar -xzf *.tar.gz
cd */ 

# 4. Cross-Compilation Environment Variables
export PYTHONPATH="$MOCK_DIR:$PYTHONPATH"
export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONFIG_NAME"
export CC="$NDK_BIN/${CC_TARGET}-clang"
export CXX="$NDK_BIN/${CC_TARGET}-clang++"
export AR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export LDSHARED="$CC -shared"
export CFLAGS="-target $CC_TARGET -fPIC -I$MOCK_INCLUDE $LONG_BIT_FLAG"
export CPPFLAGS="-I$MOCK_INCLUDE $LONG_BIT_FLAG"
export LDFLAGS="-target $CC_TARGET -L$MOCK_DIR -lpython$PY_VER"

PY_TAG="cp${PY_VER/./}"

echo "Executing Bdist Wheel with safe Monkey-Patch..."
python3 -c "
import setuptools.command.bdist_wheel as bdist
bdist.bdist_wheel.get_tag = lambda self: ('$PY_TAG', '$PY_TAG', '$PLAT_TAG')
import sys
sys.argv = ['setup.py', 'bdist_wheel']
exec(open('setup.py').read(), {'__file__': 'setup.py', '__name__': '__main__'})
"

OLD_WHEEL=$(ls dist/*.whl)
NEW_WHEEL=$(echo "$OLD_WHEEL" | sed -E "s/(-[^-]+)\.whl$/-${PLAT_TAG}.whl/")
if [ "$OLD_WHEEL" != "$NEW_WHEEL" ]; then
    mv "$OLD_WHEEL" "$NEW_WHEEL"
fi

WHEEL_ABS="$(pwd)/$NEW_WHEEL"

# 5. Deterministic RPATH Injection & Relocation (The "Auditwheel" phase)
sudo apt-get update -qq && sudo apt-get install -y -qq patchelf elfutils
mkdir -p wheel_patch
unzip -q "$WHEEL_ABS" -d wheel_patch

echo "Injecting deterministic RPATH into .so files..."
# --force-rpath ensures highest priority for the Android linker.
# $ORIGIN/.libs guarantees support for complex packages bundling shared dependencies.
find wheel_patch -name "*.so" -exec patchelf --force-rpath --set-rpath '$ORIGIN:$ORIGIN/.libs' {} \; || true

pushd wheel_patch > /dev/null
zip -q -r "$WHEEL_ABS" .
popd > /dev/null

# 6. Final Readelf Audit Verification
echo "=== AUDITWHEEL (Readelf Verification) ==="
TEST_SO=$(find wheel_patch -name "*.so" | head -n 1)
if [ -n "$TEST_SO" ]; then
    echo "Checking Linker Tags for: $(basename "$TEST_SO")"
    readelf -d "$TEST_SO" | grep -E "(RPATH|RUNPATH|NEEDED)" || echo "No tags found."
else
    echo "No .so files found to audit."
fi
echo "========================================="
rm -rf wheel_patch

cp "$WHEEL_ABS" "$OUT_DIR/"
echo "✅ Build completed successfully: $OUT_DIR/$(basename "$WHEEL_ABS")"