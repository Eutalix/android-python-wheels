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

"$NDK_BIN/${CC_TARGET}-clang" -shared -Wl,-soname,libpython$PY_VER.so -o "$MOCK_DIR/libpython$PY_VER.so" -xc /dev/null

HOST_INCLUDE=$(python3 -c "import sysconfig; print(sysconfig.get_path('include'))")

SYSCONFIG_NAME="_sysconfigdata__linux_aarch64"
cat > "$MOCK_DIR/${SYSCONFIG_NAME}.py" <<EOF
build_time_vars = {
    'abiflags': '', 'ABIFLAGS': '', 'SO': '.so', 'SOABI': 'cpython-${PY_VER/./}', 'EXT_SUFFIX': '.so',
    'LIBDIR': '$MOCK_DIR', 'LDLIBRARY': 'libpython$PY_VER.so', 'INCLUDEPY': '$HOST_INCLUDE',
    'CC': '$NDK_BIN/${CC_TARGET}-clang', 'CXX': '$NDK_BIN/${CC_TARGET}-clang++',
    'AR': '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar',
    'LD': '$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/ld.lld',
    'LDSHARED': '$NDK_BIN/${CC_TARGET}-clang -shared',
    'ARFLAGS': 'rcs', 'CFLAGS': '-fPIC', 'CXXFLAGS': '-fPIC', 'CPPFLAGS': '-I$HOST_INCLUDE $LONG_BIT_FLAG',
    'LDFLAGS': '-L$MOCK_DIR -lpython$PY_VER', 'CCSHARED': '-fPIC', 'VERSION': '$PY_VER',
    'GNULD': 'yes', 'Py_DEBUG': 0, 'WITH_PYMALLOC': 1,
}
EOF

mkdir -p "$WORKDIR/src" && cd "$WORKDIR/src"
pip download "$PKG_NAME==$PKG_VER" --no-binary :all: --no-deps
tar -xzf *.tar.gz
cd */ 

export PYTHONPATH="$MOCK_DIR:$PYTHONPATH"
export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONFIG_NAME"
export CC="$NDK_BIN/${CC_TARGET}-clang"
export CXX="$NDK_BIN/${CC_TARGET}-clang++"
export AR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export LDSHARED="$CC -shared"
export CFLAGS="-target $CC_TARGET -fPIC -I$HOST_INCLUDE $LONG_BIT_FLAG"
export CPPFLAGS="-I$HOST_INCLUDE $LONG_BIT_FLAG"
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

sudo apt-get update -qq && sudo apt-get install -y -qq patchelf
mkdir -p wheel_patch
unzip -q "$WHEEL_ABS" -d wheel_patch

echo "Injecting RPATH=\$ORIGIN into .so files..."
find wheel_patch -name "*.so" -exec patchelf --set-rpath '$ORIGIN' {} \; || true

pushd wheel_patch > /dev/null
zip -q -r "$WHEEL_ABS" .
popd > /dev/null
rm -rf wheel_patch

echo "Analyzing generated binary:"
file $(find wheel_patch -name "*.so" | head -n 1) || true
rm -rf wheel_patch

cp "$WHEEL_ABS" "$OUT_DIR/"
echo "✅ Build completed successfully: $OUT_DIR/$(basename "$WHEEL_ABS")"