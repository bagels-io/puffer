# Security

Puffer reads every keystroke on the Mac it runs on, so security reports are
taken seriously, and reports about anything that could expose what a user
types or what is on their clipboard are especially welcome.

## Reporting a vulnerability

Please report it privately through GitHub: open the repository's **Security**
tab and choose **Report a vulnerability**
(<https://github.com/bagels-io/puffer/security/advisories/new>). Do not open a
public issue for a security problem.

Include what you found, how to reproduce it, and the macOS and Puffer versions.
You should get a reply within a week.

## Scope

- The app in this repository and its build scripts.
- The README's "Privacy" section describes what Puffer reads and keeps. A way
  to make Puffer behave differently from what is written there is a
  vulnerability.

Known and documented limitations (see the README) are not vulnerabilities:
the local self-signed development certificate, the unencrypted library file,
and the clipboard being used to insert text.
