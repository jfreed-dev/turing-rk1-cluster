Installation of go-containerregistry

To install go-containerregistry, follow the steps below based on your operating system.
For Linux or macOS

    Download the Latest Release
        Use the following command to download the latest version:

Code

    $ OS=Linux # or Darwin for macOS
    $ ARCH=x86_64 # or arm64, x86_64, etc.
    $ curl -sL "https://github.com/google/go-containerregistry/releases/download/${VERSION}/go-containerregistry_${OS}_${ARCH}.tar.gz" > go-containerregistry.tar.gz

Verify the Download

    To ensure the integrity of the download, verify the signature:

Code

    $ curl -sL https://github.com/google/go-containerregistry/releases/download/${VERSION}/multiple.intoto.jsonl > provenance.intoto.jsonl
    $ slsa-verifier-linux-amd64 verify-artifact go-containerregistry.tar.gz --provenance-path provenance.intoto.jsonl --source-uri github.com/google/go-containerregistry --source-tag "${VERSION}"

Extract and Install

    Extract the downloaded file:

Code

    $ tar -zxvf go-containerregistry.tar.gz -C /usr/local/bin/

Install via Go

    Alternatively, you can install it using Go:

Code

        go install github.com/google/go-containerregistry/cmd/crane@latest

For Arch Linux

    Use the following command to install:

Code

    $ sudo pacman -S go-containerregistry

For Homebrew Users (macOS)

    If you are using Homebrew, you can install it with:

Code

    brew install go-containerregistry

After installation, you can start using go-containerregistry for interacting with remote images and registries.
