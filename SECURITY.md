# Security Policy

## Supported versions

Sebas is pre-1.0; only the latest release on `main` receives security fixes.

| Version | Supported |
| --- | --- |
| 0.1.x | ✅ |
| < 0.1 | ❌ |

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private reporting: repository → **Security** → **Report a vulnerability**
(private security advisory). If that is unavailable, contact the maintainer
[@ShiningRay](https://github.com/ShiningRay) through a private channel.

Please include:

- affected version / commit,
- a minimal reproduction (config shape, channel, command),
- expected vs. actual behavior,
- any known impact (credential exposure, sandbox escape, remote trigger).

You can expect an acknowledgement within 7 days and a status update within 30 days.
Please give us reasonable time to ship a fix before publishing details.

## Scope notes

Sebas runs locally and binds messaging accounts the user owns. High-value areas:

- **Credential handling** — secrets are excluded from config files and mastered by the
  OS keyring or an AES-256-GCM vault; reports of plaintext leakage are in scope.
- **Inbound webhook / callback verification** — signature checks for WeCom and Lark.
- **Plugin sandbox** — the mruby plugin layer is designed as an isolated subprocess;
  escapes or host-capability leaks are in scope.
- **Admin surfaces** — the local IPC/HTTP admin endpoints are loopback-oriented; auth
  bypass reports are in scope.

Out of scope: vulnerabilities in third-party accounts or servers you do not own,
social engineering, and denial of service against your own local instance.

## 中文要点

- 支持版本：仅最新 0.1.x。
- 报告方式：GitHub 私密安全公告（Security → Report a vulnerability），**不要开公开 Issue**。
- 请附版本/commit、最小复现、预期与实际、影响面；7 天内确认，30 天内给进展。
- 重点关注：凭据泄露、Webhook 验签、插件沙箱逃逸、管理面鉴权。
