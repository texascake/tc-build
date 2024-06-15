#!/usr/bin/env bash

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}
err() {
    echo -e "\e[1;41$*\e[0m"
}

# Environment Config
export BRANCH=main
export CACHE=1

# Get home directory
DIR="$(pwd)"
install=$DIR/install
src=$DIR/src

# Telegram Setup
export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
send_msg() {
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="$1"

}

send_file() {
    curl --progress-bar -F document=@"$1" "$BOT_MSG_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$3"
}

send_erlog() {
    curl -F document=@"build.log" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F caption="Build ran into errors, plox check logs"
}

# Building LLVM's
msg "Building LLVM's ..."
send_msg "<b>Start build $LLVM_NAME from <code>[ $BRANCH ]</code> branch</b>"
chmod +x build-llvm.py
./build-llvm.py \
    --defines LLVM_PARALLEL_COMPILE_JOBS="$(nproc)" LLVM_PARALLEL_LINK_JOBS="$(nproc)" CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3 \
    --install-folder "$install" \
    --assertions \
    --build-stage1-only \
    --build-target distribution \
    --check-targets clang lld llvm \
    --install-target distribution \
    --projects all \
    --quiet-cmake \
    --shallow-clone \
    --show-build-commands \
    --targets ARM AArch64 X86 \
    --ref "release/18.x" \
    --vendor-string "$LLVM_NAME" 2>&1 | tee build.log

# Check if the final clang binary exists or not
for file in install/bin/clang-1*; do
    if [ -e "$file" ]; then
        msg "LLVM's build successful"
    else
        err "LLVM's build failed!"
        send_msg "LLVM's build failed!"
        exit
    fi
done

# Build binutils
msg "Build binutils ..."
post_msg "<b>$LLVM_NAME: Building Binutils. . .</b>"
chmod +x build-binutils.py
./build-binutils.py \
    --install-folder "$install" \
    --targets arm aarch64 x86_64

rm -fr install/include
rm -f install/lib/*.a install/lib/*.la

for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
    strip -s "${f::-1}"
done

for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
    bin="${bin::-1}"

    echo "$bin"
    patchelf --set-rpath "$DIR/../lib" "$bin"
done

# Git config
git config --global user.name "$GH_USERNAME"
git config --global user.email "$GH_EMAIL"

# Get Clang Info
pushd "$src"/llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<<"$llvm_commit")"
popd || exit
llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
clang_output="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"
if [[ $clang_output =~ version\ ([0-9.]+) ]]; then
    clang_version="${BASH_REMATCH[1]}"
    clang_version="${clang_version%git}"
fi
build_date="$(TZ=Asia/Jakarta date +"%Y-%m-%d")"
tags="ElectroWizard-Clang-$clang_version-release"
file="ElectroWizard-Clang-$clang_version.tar.gz"
clang_link="https://github.com/Tiktodz/ElectroWizard-Clang/releases/download/$tags/$file"

# Get binutils version
binutils_version=$(grep "LATEST_BINUTILS_RELEASE" build-binutils.py)
binutils_version=$(echo "$binutils_version" | grep -oP '\(\s*\K\d+,\s*\d+,\s*\d+' | tr -d ' ')
binutils_version=$(echo "$binutils_version" | tr ',' '.')

# Create simple info
pushd "$install" || exit
{
    echo "# Quick Info
* Build Date : $build_date
* Clang Version : $clang_version
* Binutils Version : $binutils_version
* Compiled Based : $llvm_commit_url"
} >>README.md
tar -czvf ../"$file" .
popd || exit

# Push
git clone "https://$GH_USERNAME:$GH_TOKEN@github.com/Tiktodz/ElectroWizard-Clang" rel_repo
pushd rel_repo || exit
if [ -d "$BRANCH" ]; then
    echo "$clang_link" >"$BRANCH"/link.txt
    cp -r "$install"/README.md "$BRANCH"
else
    mkdir -p "$BRANCH"
    echo "$clang_link" >"$BRANCH"/link.txt
    cp -r "$install"/README.md "$BRANCH"
fi
git add .
git commit -asm "ElectroWizard-Clang-$clang_version: $(TZ=Asia/Jakarta date +"%Y%m%d")"
git push -f origin main

# Check tags already exists or not
overwrite=y
git tag -l | grep "$tags" || overwrite=n
popd || exit

# Upload to github release
failed=n
if [ "$overwrite" == "y" ]; then
    chmod +x github-release
    ./github-release edit \
        --security-token "$GH_TOKEN" \
        --user "$GH_USERNAME" \
        --repo "ElectroWizard-Clang" \
        --tag "$tags" \
        --description "$(cat "$(pwd)"/install/README.md)"

    ./github-release upload \
        --security-token "$GH_TOKEN" \
        --user "$GH_USERNAME" \
        --repo "ElectroWizard-Clang" \
        --tag "$tags" \
        --name "$file" \
        --file "$(pwd)/$file" \
        --replace || failed=y
else
    ./github-release release \
        --security-token "$GH_TOKEN" \
        --user "$GH_USERNAME" \
        --repo "ElectroWizard-Clang" \
        --tag "$tags" \
        --description "$(cat "$(pwd)"/install/README.md)"

    ./github-release upload \
        --security-token "$GH_TOKEN" \
        --user "$GH_USERNAME" \
        --repo "ElectroWizard-Clang" \
        --tag "$tags" \
        --name "$file" \
        --file "$(pwd)/$file" || failed=y
fi

# Handle uploader if upload failed
while [ "$failed" == "y" ]; do
    failed=n
    chmod +x ./github-release
    ./github-release upload \
        --security-token "$GH_TOKEN" \
        --user "$GH_USERNAME" \
        --repo "ElectroWizard-Clang" \
        --tag "$tags" \
        --name "$file" \
        --file "$(pwd)/$file" \
        --replace || failed=y
done

# Send message to telegram
send_msg "
<b>----------------- Quick Info -----------------</b>
<b>Build Date : </b>
* <code>$build_date</code>
<b>Clang Version : </b>
* <code>$clang_version</code>
<b>Binutils Version : </b>
* <code>$binutils_version</code>
<b>Compile Based : </b>
* <a href='$llvm_commit_url'>$llvm_commit_url</a>
<b>Push Repository : </b>
* <a href='https://github.com/Tiktodz/ElectroWizard-Clang.git'>ElectroWizard-Clang</a>
<b>-------------------------------------------------</b>"
