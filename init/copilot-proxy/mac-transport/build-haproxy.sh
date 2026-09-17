#!/bin/sh
# Build only the loopback HTTP transport; SSH provides remote encryption.
set -eu
build_root="${COPILOT_BUILD_CACHE:-$HOME/Library/Caches/copilot-transport}"
version=3.4.4
expected=b0c5053c4d46840ecdee3925736fe9a3de6472559b43c69183d70e593d9133df
mkdir -p "$build_root"
cd "$build_root"
if [ ! -f "haproxy-$version.tar.gz" ]; then
    curl --noproxy '*' -fSL --max-time 60 -o "haproxy-$version.tar.gz" \
        "https://www.haproxy.org/download/3.4/src/haproxy-$version.tar.gz"
fi
actual=$(shasum -a 256 "haproxy-$version.tar.gz" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo 'Source checksum mismatch' >&2; exit 1; }
if [ ! -d "haproxy-$version" ]; then
    tar -xzf "haproxy-$version.tar.gz"
fi
cd "haproxy-$version"
make -j4 TARGET=osx USE_OPENSSL= USE_PCRE= USE_PCRE2= USE_ZLIB= DEBUG_CFLAGS=
./haproxy -v
otool -L haproxy
