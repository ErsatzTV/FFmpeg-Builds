#!/bin/bash

SCRIPT_REPO="https://github.com/nyanmisaka/rk-mirrors.git"
SCRIPT_COMMIT="1d330cc28551943bed3380261a5a9c6fbd58ff53"
SCRIPT_BRANCH="jellyfin-rga-next"

ffbuild_enabled() {
    [[ $TARGET == linuxarm64 ]] || return -1
    return 0
}

ffbuild_dockerbuild() {
    # upstream hardcodes shared_library()
    sed -i 's/shared_library/library/g' meson.build

    mkdir rkrga_build && cd rkrga_build

    meson --prefix="$FFBUILD_PREFIX" --buildtype=release --default-library=static \
        --cross-file=/cross.meson -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false ..
    ninja -j$(nproc)
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    echo "Libs.private: -lstdc++" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/librga.pc
}

ffbuild_configure() {
    echo --enable-rkrga
}

ffbuild_unconfigure() {
    [[ $TARGET == linuxarm64 ]] || return 0
    echo --disable-rkrga
}
