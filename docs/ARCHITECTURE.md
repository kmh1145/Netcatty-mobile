# Architecture

The mobile app follows the upstream dependency direction:

```text
Presentation -> Application -> Domain
                        \-> Infrastructure adapters
```

`HostProfile` and `VaultData` are lossless wrappers. Known mobile fields use typed getters while the underlying JSON map retains fields added by desktop builds or plugins. Credentials are removed before SharedPreferences persistence and rehydrated from platform secure storage.

An SSH session owns one `SSHClient`, one shell channel and one terminal buffer. SFTP and forwarding borrow the authenticated client, avoiding duplicate authentication and keeping lifecycle tied to the session. Closing a terminal closes its shell and transport; port forwards expose explicit stop controls.

Cloud sync adapters never receive plaintext credentials separately from the encrypted payload assembly. `NetcattyCrypto` reproduces the desktop wire format:

1. 32-byte random salt
2. PBKDF2-HMAC-SHA256, 600,000 iterations, 256-bit key
3. 12-byte random nonce
4. AES-256-GCM with a 128-bit tag appended to ciphertext
5. Base64 fields inside `{meta, payload}`

The included fixture is produced by Node's AES-GCM implementation and verifies cross-runtime compatibility.

