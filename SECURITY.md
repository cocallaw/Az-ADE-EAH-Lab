# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly using [GitHub's private vulnerability reporting](https://github.com/cocallaw/Az-ADE-EAH-Lab/security/advisories/new).

**Please do NOT open a public issue for security vulnerabilities.**

### What to include

- A description of the vulnerability
- Steps to reproduce or a proof-of-concept
- The potential impact
- Any suggested fixes (optional)

### Response timeline

- **Acknowledgement:** Within 3 business days
- **Initial assessment:** Within 7 business days
- **Fix or mitigation:** Depends on severity; critical issues are prioritized

## Scope

This repository contains **lab and demo templates** for educational purposes. It is not intended for production use without modification. However, we still take security seriously — particularly around:

- GitHub Actions workflow integrity (OIDC, pinned actions)
- Credential handling in scripts and templates
- Key Vault and encryption configuration best practices

## Supported Versions

Only the latest version on the `main` branch is actively maintained.
