# Security

Mailmule handles mail and passwords, so security reports are taken seriously.

**Please do not open a public issue for a vulnerability.** Report it privately through GitHub:
the repository's **Security** tab → **Report a vulnerability**. Include the steps to reproduce it and what
an attacker could achieve.

You will get a reply as soon as possible. Once a fix is released, you will be credited unless you prefer
otherwise.

Particularly relevant areas:

- handling of untrusted mail content (HTML rendering, remote images, attachments, calendar invitations)
- the `mailmule://` and `mailto:` URL handlers
- connections and TLS (IMAP, SMTP, STARTTLS)
- storage of credentials (macOS Keychain)
