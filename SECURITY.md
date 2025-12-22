# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities
2. Email the maintainer directly or use GitHub's private vulnerability reporting feature
3. Include detailed information about the vulnerability and steps to reproduce

## Security Considerations

### Cluster Credentials

This repository contains example Talos Linux configuration files. **Never commit actual cluster secrets** to version control:

- `cluster-config/secrets.yaml` - Contains cluster credentials (gitignored)
- `cluster-config/kubeconfig` - Contains kubectl credentials (gitignored)
- `cluster-config/talosconfig` - Contains Talos API credentials (gitignored)

Always generate fresh credentials using `talosctl gen config` for your deployments.

### Configuration Files

The YAML configuration files in `cluster-config/` contain `<REDACTED>` placeholders where sensitive values should be. These are examples only - generate your own configurations for production use.

### Third-Party Components

This project includes submodules from third-party sources:
- sbc-rockchip (Talos overlay)
- rknn-toolkit2 (Rockchip NPU SDK)
- rknn-llm (Rockchip LLM runtime)
- u-boot-rockchip (Bootloader)

Review the security policies of these upstream projects for their respective components.

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |

## Best Practices

1. Rotate cluster credentials regularly
2. Use network segmentation for your cluster
3. Keep Talos Linux and Kubernetes versions up to date
4. Review container images before deployment
5. Enable audit logging in your cluster
