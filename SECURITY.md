# Security Policy

MacPerfMonitor reads sensitive process and memory data, so we take its security and
privacy posture seriously. It collects no telemetry and makes no network calls;
all data stays local.

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

- Use GitHub's private vulnerability reporting (the "Report a vulnerability"
  button under the repository's **Security** tab), or
- contact the maintainers at the address listed on the repository profile.

Include a description of the issue, the affected version or commit, and steps to
reproduce. We will acknowledge your report, investigate, and keep you updated on
a fix and disclosure timeline. Please give us a reasonable opportunity to
address the issue before any public disclosure.

## Supported versions

MacPerfMonitor is pre-1.0 and under active development. Security fixes target the
latest release and the `main` branch.

## Privacy posture

- No telemetry, no analytics, no phone-home.
- All sampled data is written to a local SQLite store on the user's machine and
  never transmitted.
- The app is not sandboxed (it needs system-wide process visibility) but
  requests no capability beyond reading process and memory statistics.

