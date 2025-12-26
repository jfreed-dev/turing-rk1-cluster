# Contributing to Turing RK1 Cluster

Thank you for your interest in contributing! This document provides guidelines for contributing to this project.

## How to Contribute

### Reporting Issues

- Check existing issues before creating a new one
- Use the issue templates when available
- Include relevant details: hardware, software versions, logs, and steps to reproduce

### Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Test your changes on actual hardware if possible
5. Commit with clear, descriptive messages
6. Push to your fork
7. Open a Pull Request

### Commit Message Guidelines

- Write clear, descriptive commit messages
- **Do not include AI assistant references** in commit messages (no "Generated with Claude", "Co-Authored-By: Claude", etc.)
- Use conventional commit format when appropriate (e.g., `feat:`, `fix:`, `docs:`)

### Pull Request Guidelines

- Keep PRs focused on a single change
- Update documentation if needed
- Follow existing code style and conventions
- Test on RK3588 hardware when possible

## Development Setup

### Prerequisites

- Docker with buildx support
- `talosctl` CLI
- Access to Turing Pi hardware (for testing)

### Building

```bash
# For sbc-rockchip overlay
cd repo/sbc-rockchip
make

# For RKNN model examples
cd repo/rknn_model_zoo
./build-linux.sh -t rk3588 -a aarch64 -d <demo_name>
```

## Code of Conduct

Please read and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Questions?

Open a discussion or issue if you have questions about contributing.
