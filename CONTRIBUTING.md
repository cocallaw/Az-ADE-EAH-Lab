# Contributing to Az-ADE-EAH-Lab

Thank you for your interest in contributing! This project provides hands-on lab materials for migrating Azure VMs from ADE to Encryption at Host.

## Getting Started

1. **Fork** the repository
2. **Clone** your fork locally
3. **Create a feature branch** from `main`
4. **Make your changes** following the conventions below
5. **Open a Pull Request** against `main`

## Branch Naming

Use descriptive kebab-case branch names:

- `fix/linux-disk-copy-timeout`
- `feature/add-resource-graph-discovery`
- `docs/update-walkthrough`

## Code Conventions

### Bicep

- Single `main.bicep` per variant (flat structure, no modules)
- Parameters and variables use **camelCase**
- Resource symbolic names are short camelCase (e.g., `keyVault`, `vm`, `nic`)
- Committed `azuredeploy.json` is auto-generated — do not edit by hand

### Terraform

- Flat root modules: `main.tf`, `variables.tf`, `outputs.tf`
- Variables and outputs use **snake_case**
- Resource labels are short lowercase (e.g., `rg`, `kv`, `vm`)

### PowerShell Scripts

- **PascalCase** with numbered prefix: `01-Register-EAH-Feature.ps1`
- Use `[CmdletBinding()]` with `Mandatory` parameters
- Error handling: `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`

### CLI/Bash Scripts

- **kebab-case** with numbered prefix: `01-register-eah-feature.sh`
- Error handling: `set -euo pipefail`
- Positional arguments for required params

## Testing Changes

### Bicep

```bash
az bicep lint --file bicep/windows/main.bicep
az bicep lint --file bicep/linux/main.bicep
az bicep build --file bicep/windows/main.bicep
az bicep build --file bicep/linux/main.bicep
```

### Terraform

```bash
cd terraform/windows  # or terraform/linux
terraform init
terraform validate
```

## Pull Request Guidelines

- Keep PRs focused on a single change
- Update documentation if your change affects usage
- Ensure CI checks pass (Bicep lint/build, Terraform validate)
- Reference any related issues (e.g., `Closes #123`)

## Reporting Issues

- Use [GitHub Issues](https://github.com/cocallaw/Az-ADE-EAH-Lab/issues) for bugs and feature requests
- For security vulnerabilities, see [SECURITY.md](SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
