# Security

Relevo handles Claude Desktop's session cookies and the keychain key that
decrypts them, so security reports are very welcome.

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub instead:
**Security → Report a vulnerability** in this repository, or
[this link](https://github.com/Nico-Sanchez/relevo/security/advisories/new).

Include what you found, how to reproduce it and which version you used.

## In scope

- Saved logins, session cookies or the keychain key leaving your Mac, or
  becoming readable by other users on it.
- Relevo contacting any host other than claude.ai, or contacting it while
  **Show usage** is off.
- Files written with permissions wider than your own user's.
- Switching or moving sessions in a way that loses another account's data.

## Out of scope

Claude Desktop itself and Anthropic's services. Report those to Anthropic.
