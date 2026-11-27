# terminal.youneek.dev

Cloudflare Worker (`death-terminal-site`) that serves the Death Terminal marketing site at https://terminal.youneek.dev.

This is a static-asset Worker. It has no secrets or bindings. The download site on GitHub Pages still lives in `/site`.

```sh
cd worker-site
npm install
npx wrangler dev      # local preview
npx wrangler deploy   # publish to terminal.youneek.dev
```

You need to be logged in to the YouNeeK Cloudflare account (`npx wrangler whoami`).
