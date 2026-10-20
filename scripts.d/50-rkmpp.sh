#!/bin/bash

SCRIPT_REPO="https://github.com/nyanmisaka/rk-mirrors.git"
SCRIPT_COMMIT="a9380ef333102ac318628f83b5f7a460d377749e"
SCRIPT_BRANCH="jellyfin-mpp-next"

ffbuild_enabled() {
    [[ $TARGET == linuxarm64 ]] || return -1
    return 0
}

ffbuild_dockerbuild() {
    # the repo already has a build/ directory
    mkdir rkmpp_build && cd rkmpp_build

    cmake -GNinja -DCMAKE_TOOLCHAIN_FILE="$FFBUILD_CMAKE_TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$FFBUILD_PREFIX" -DBUILD_SHARED_LIBS=OFF -DBUILD_TEST=OFF ..
    ninja -j$(nproc)
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    echo "Libs.private: -lstdc++" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/rockchip_mpp.pc
}

ffbuild_configure() {
    echo --enable-rkmpp
}

ffbuild_unconfigure() {
    [[ $TARGET == linuxarm64 ]] || return 0
    echo --disable-rkmpp
}
