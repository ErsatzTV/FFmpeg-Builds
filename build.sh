#!/bin/bash
set -xe
shopt -s globstar
cd "$(dirname "$0")"
source util/vars.sh

source "variants/${TARGET}-${VARIANT}.sh"

for addin in ${ADDINS[*]}; do
    source "addins/${addin}.sh"
done

if docker info -f "{{println .SecurityOptions}}" | grep rootless >/dev/null 2>&1; then
    UIDARGS=()
else
    UIDARGS=( -u "$(id -u):$(id -g)" )
fi

rm -rf ffbuild
mkdir ffbuild

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REPO="${FFMPEG_REPO_OVERRIDE:-$FFMPEG_REPO}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"

# Release builds must be fully specified by the caller: a digest-pinned dependency
# image (never a floating :latest), the expected upstream commit, and an explicit
# patch set and version suffix. Nothing may fall back to a local default.
if [[ -n "$FFBUILD_RELEASE" ]]; then
    fail() { echo "FFBUILD_RELEASE: $*" >&2; exit 1; }
    [[ "$IMAGE_OVERRIDE" =~ @sha256:[0-9a-f]{64}$ ]] || fail "IMAGE_OVERRIDE must be a digest reference"
    [[ "$FFMPEG_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "FFMPEG_COMMIT must be a full commit SHA"
    [[ -n "$GIT_BRANCH_OVERRIDE" ]] || fail "GIT_BRANCH_OVERRIDE must be set"
    [[ -n "$FFBUILD_VERSION_SUFFIX" ]] || fail "FFBUILD_VERSION_SUFFIX must be set"
    [[ "$FFMPEG_PATCHES_DIR" == /* ]] || fail "FFMPEG_PATCHES_DIR must be an absolute path"
    compgen -G "$FFMPEG_PATCHES_DIR/*.patch" >/dev/null || fail "no patches in $FFMPEG_PATCHES_DIR"
fi

IMAGE="${IMAGE_OVERRIDE:-$IMAGE}"

PATCHES_MOUNT=()
if [[ -n "$FFMPEG_PATCHES_DIR" ]]; then
    [[ -d "$FFMPEG_PATCHES_DIR" ]] || { echo "FFMPEG_PATCHES_DIR not found: $FFMPEG_PATCHES_DIR" >&2; exit 1; }
    PATCHES_MOUNT=( -v "$(realpath "$FFMPEG_PATCHES_DIR")":/ffmpeg-patches:ro )
fi

BUILD_SCRIPT="$(mktemp)"
trap "rm -f -- '$BUILD_SCRIPT'" EXIT

RPATH_LDEXEFLAGS=''
if [[ $TARGET == linux* && $VARIANT == *shared* ]]; then
    RPATH_LDEXEFLAGS=' -Wl,-rpath,\\\$\$ORIGIN/../lib'
fi

cat <<EOF >"$BUILD_SCRIPT"
    set -xe
    cd /ffbuild
    rm -rf ffmpeg prefix

    git clone --filter=blob:none --branch='$GIT_BRANCH' '$FFMPEG_REPO' ffmpeg
    cd ffmpeg

    if [ -n '$FFMPEG_COMMIT' ] && [ "\$(git rev-parse HEAD)" != '$FFMPEG_COMMIT' ]; then
        echo "Expected FFmpeg commit $FFMPEG_COMMIT for $GIT_BRANCH, got \$(git rev-parse HEAD)" >&2
        exit 1
    fi

    if [ -d /ffmpeg-patches ]; then
        for p in /ffmpeg-patches/*.patch; do
            [ -e "\$p" ] || continue
            echo "Applying local FFmpeg patch: \$p"
            git apply --verbose "\$p"
        done
    fi

    ./configure --prefix=/ffbuild/prefix --pkg-config-flags="--static" \$FFBUILD_TARGET_FLAGS \$FF_CONFIGURE \
        --extra-cflags="\$FF_CFLAGS" --extra-cxxflags="\$FF_CXXFLAGS" --extra-libs="\$FF_LIBS" \
        --extra-ldflags="\$FF_LDFLAGS" --extra-ldexeflags="\$FF_LDEXEFLAGS"'$RPATH_LDEXEFLAGS' \
        --cc="\$CC" --cxx="\$CXX" --ar="\$AR" --ranlib="\$RANLIB" --nm="\$NM" \
        ${FFBUILD_VERSION_SUFFIX:+--extra-version='$FFBUILD_VERSION_SUFFIX'} || { cat ffbuild/config.log; exit 1; }
    make -j\$(nproc) V=1
    make install install-doc
EOF

[[ -t 1 ]] && TTY_ARG="-t" || TTY_ARG=""

docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "$PWD/ffbuild":/ffbuild "${PATCHES_MOUNT[@]}" -v "$BUILD_SCRIPT":/build.sh "$IMAGE" bash /build.sh

if [[ -n "$FFBUILD_OUTPUT_DIR" ]]; then
    mkdir -p "$FFBUILD_OUTPUT_DIR"
    package_variant ffbuild/prefix "$FFBUILD_OUTPUT_DIR"
    [[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "$FFBUILD_OUTPUT_DIR/LICENSE.txt"
    rm -rf ffbuild
    exit 0
fi

mkdir -p artifacts
ARTIFACTS_PATH="$PWD/artifacts"
BUILD_NAME="ffmpeg-$(./ffbuild/ffmpeg/ffbuild/version.sh ffbuild/ffmpeg)${FFBUILD_VERSION_SUFFIX:+-}${FFBUILD_VERSION_SUFFIX}-${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}"

mkdir -p "ffbuild/pkgroot/$BUILD_NAME"
package_variant ffbuild/prefix "ffbuild/pkgroot/$BUILD_NAME"

[[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "ffbuild/pkgroot/$BUILD_NAME/LICENSE.txt"

cd ffbuild/pkgroot
if [[ "${TARGET}" == win* ]]; then
    OUTPUT_FNAME="${BUILD_NAME}.zip"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" zip -9 -r "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
else
    OUTPUT_FNAME="${BUILD_NAME}.tar.xz"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" tar -I "xz -T0" -cf "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
fi
cd -

rm -rf ffbuild

if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "build_name=${BUILD_NAME}" >> "$GITHUB_OUTPUT"
    echo "${OUTPUT_FNAME}" > "${ARTIFACTS_PATH}/${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}.txt"
fi
