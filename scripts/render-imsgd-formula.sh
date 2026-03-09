#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <output> <version> <tag> <darwin_amd64_sha> <darwin_arm64_sha>" >&2
  exit 1
fi

output="$1"
version="$2"
tag="$3"
darwin_amd64_sha="$4"
darwin_arm64_sha="$5"

encoded_tag="${tag//\//%2F}"
base_url="https://github.com/jpreagan/imsgkit/releases/download/${encoded_tag}"

cat >"$output" <<EOF
class Imsgd < Formula
  desc "macOS helper for exposing read-only imsgkit message data"
  homepage "https://github.com/jpreagan/imsgkit"
  version "${version}"
  license "MIT"

  on_macos do
    if Hardware::CPU.intel?
      url "${base_url}/imsgd_${version}_darwin_amd64.tar.gz"
      sha256 "${darwin_amd64_sha}"

      def install
        bin.install "imsgd"
      end
    end

    if Hardware::CPU.arm?
      url "${base_url}/imsgd_${version}_darwin_arm64.tar.gz"
      sha256 "${darwin_arm64_sha}"

      def install
        bin.install "imsgd"
      end
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/imsgd version")
  end
end
EOF
