#!/bin/sh
# Generate _site/index.html -- the repository landing page.
#
# Required env vars:
#   BASE_URL          e.g. https://org.github.io/repo
#   GITHUB_REPOSITORY e.g. org/repo (set by GitHub Actions)

set -eu

: "${BASE_URL:?BASE_URL must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

{
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>FreeBSD Package Repository</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #fff;
      --fg: #222;
      --code-bg: #f4f4f4;
      --link: #0366d6;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --fg: #c9d1d9;
        --code-bg: #161b22;
        --link: #58a6ff;
      }
    }
    body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; background: var(--bg); color: var(--fg); }
    h1 { margin-bottom: 0.25rem; }
    a { color: var(--link); }
    code, pre { background: var(--code-bg); border-radius: 3px; }
    code { padding: 0.1rem 0.3rem; }
    pre { padding: 1rem; overflow-x: auto; }
    ul { padding-left: 1.25rem; }
  </style>
</head>
<body>
  <h1>FreeBSD Package Repository</h1>
  <p>Binary FreeBSD packages built for CPU architectures not covered by the official FreeBSD package mirrors.</p>

  <h2>Available targets</h2>
  <ul>
HTML

    for d in _site/FreeBSD:*; do
        [ -d "$d" ] || continue
        abi=$(basename "$d")
        # URL-encode the colons so browsers don't treat "FreeBSD:" as a URI
        # scheme. A leading "./" is normalized away per the URL spec, so
        # encoding is the only reliable fix.
        href=$(printf '%s' "$abi" | sed 's/:/%3A/g')
        printf '    <li><a href="%s/"><code>%s</code></a></li>\n' "$href" "$abi"
    done

    cat <<HTML
  </ul>

  <h2>Using the repository</h2>
  <p>On a matching FreeBSD system, create <code>/usr/local/etc/pkg/repos/custom.conf</code>:</p>
<pre>custom: {
    url: "${BASE_URL}/\${ABI}",
    enabled: yes,
    signature_type: "none"
}</pre>
  <p>Then run <code>pkg update</code> to pick up the repository.</p>

  <p><small>Source: <a href="https://github.com/${GITHUB_REPOSITORY}">${GITHUB_REPOSITORY}</a></small></p>
</body>
</html>
HTML
} > _site/index.html
