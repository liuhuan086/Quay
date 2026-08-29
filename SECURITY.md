# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's **Security → Report a vulnerability** flow for this repository so the report and any proof of concept remain private.

Include the affected protocol or feature, reproduction steps, expected impact, and the macOS and Quay versions you tested. You should receive an acknowledgement through the advisory within seven days.

## Scope

Security-sensitive areas include credential storage, TLS validation, SSH host-key verification, path traversal, transfer integrity, sandbox permissions, and imported server configuration.

FTP is a plaintext protocol by design. Reports that only demonstrate FTP traffic can be observed in transit are out of scope unless they reveal behavior beyond that protocol limitation.
