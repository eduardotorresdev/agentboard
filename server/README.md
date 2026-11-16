# Account server

A Cloudflare Worker: GitHub sign-in, the hosts of each account (D1) and the relay between a board
and a host (one Durable Object per host). The contract is in `docs/hosts.md`.

```sh
npm install
npm test            # vitest, running the Worker, D1 and the Durable Object locally
npm run typecheck
```

## Going live

1. **GitHub OAuth App**: GitHub → Settings → Developer settings → OAuth Apps → New OAuth App.
   - Application name: what users see on the confirmation page.
   - Homepage URL: any URL you own.
   - Authorization callback URL: required by the form but unused by the device flow; repeat the
     homepage URL.
   - Tick **Enable Device Flow**, then register. Copy the **Client ID**. No client secret is needed.
2. **Sign in to Cloudflare**: `npx wrangler login`.
3. **Database**: `npx wrangler d1 create agentboard-account`, then put the `database_id` it prints
   in `wrangler.jsonc`.
4. **Migrations**: `npx wrangler d1 migrations apply agentboard-account --remote`.
5. **Client ID**: put it in `vars.GITHUB_CLIENT_ID` in `wrangler.jsonc` (it is public, not a secret).
6. **Deploy**: `npx wrangler deploy`. The Durable Object migration in `wrangler.jsonc` is applied
   by the deploy.
7. Check: `curl https://<worker url>/` prints `ok`.

Later schema changes: add a file to `migrations/` and repeat step 4 before deploying.
