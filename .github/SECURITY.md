# Security Policy

## Scope

This repository accepts security reports for:

- **Malicious CSS submissions** — CSS that attempts to exploit Discord, BetterDiscord, or Vencord (e.g. crash-on-load exploits, resource exhaustion, attempts to exfiltrate data via external requests)
- **Workflow vulnerabilities** — Issues in the GitHub Actions workflows (`.github/workflows/`) that could allow unauthorized code execution, privilege escalation, or bypass of PR validation
- **Dependency or token exposure** — Accidental exposure of secrets, tokens, or credentials in committed files

## What is not in scope

- Bugs in a theme's visual design or CSS that don't have a security impact
- Discord, BetterDiscord, or Vencord vulnerabilities — report those to their respective projects
- General spam or policy violations — [open a regular issue](https://github.com/Silverfox0338/discord-themes/issues/new/choose) for those

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Report privately by contacting @Silverfox0338 directly on GitHub or Discord. Include:

- A description of the vulnerability
- The affected file(s) or workflow
- Steps to reproduce or a proof of concept
- The potential impact

You can expect an acknowledgment within 72 hours. If the report is valid, the affected content will be removed and the contributor notified or removed depending on severity.

## Malicious Theme Policy

Any theme found to contain intentionally harmful CSS will be:

1. Removed from the repository immediately
2. Reported to GitHub if the submission constitutes abuse
3. Subject to permanent contributor ban

Submitting malicious content is a violation of the [Code of Conduct](CODE_OF_CONDUCT.md) and the [Content Policy](https://github.com/Silverfox0338/discord-themes/wiki/Developer-&-Contributor-Guide#content-policy).
