# Security notes

- Verify a new server's SHA-256 fingerprint through a trusted channel before accepting it.
- Android backups are disabled because credentials are device-bound. iOS Keychain entries use `first_unlock_this_device` accessibility and do not migrate to another device.
- The regular local vault contains no host passwords, Telnet passwords, private keys, key passphrases, sync password, provider token, or AI API key.
- Cloud payloads use the same zero-knowledge encryption format as desktop Netcatty. Provider credentials authenticate storage only and cannot decrypt the vault without the master password.
- Catty produces a command but never silently executes it. The UI displays the exact command and requires a user choice.
- WebDAV requires HTTPS. Android cleartext traffic is disabled. Do not weaken ATS/Network Security Config for production.
- Manual plaintext JSON exports are intentionally explicit and should be deleted after migration.
