# Contributing

Use Node.js 24 and edit `dist/` directly. No build step or dependency installation
is needed. Preserve best-effort behavior, credential-safe logging, HTTPS,
checksum verification, and download/execution limits.

Keep comments minimal: explain only non-obvious constraints. Do not describe
internal services or architecture. Use `example.com` for deployment examples;
only the public website and `security@bitbison.io` may identify Bitbison endpoints.
Refer installation questions to the Builds guide in the user portal without
linking to the portal.

Check syntax with:

```sh
for file in dist/*.js; do node --check "$file" || exit; done
```

Keep pull requests focused and include sanitized reproduction details for bugs.
Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
