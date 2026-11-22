# The catalog

The account's organizations, projects and the worktrees on each host, kept in the account
server so every board of the account (a Mac, a phone) sees the same list. A Mac still keeps its
own copy in its database (`Database.swift`) and syncs it both ways.

Provisional: avatars aren't in it, and the document is in clear (see Sealing).

## The document

`Sources/AgentBoard/Catalog/CatalogDocument.swift` (Foundation only; a phone copies it):

```json
{"organizations":[{"id":"<uuid>","name":"Team","color":2}],
 "projects":[{"organization":"<uuid>","name":"app","path":"/Users/me/Projects/app"}],
 "worktrees":[{"project":"/Users/me/Projects/app","host":"<host uuid>","path":"/home/dev/…","branch":"main","isMain":true}]}
```

- A project's id is its `path`: the repository path on the board that added it, which is also
  how a host finds its clone (`GitHost.clone(of:)`).
- A worktree's id is `<host>:<path>`. `host` is a host's id (lowercase UUID) or
  `board:<identity key, base64>` for a Mac's own folders. `isMain`: the checkout itself (the
  Mac's project folder, a host's clone), first in its list.
- `CatalogCodec` is the only place documents become bytes and back, on the client; the
  server never reads into them (it stores the bytes it is given).

## The server

| Call | Who | Reply |
| --- | --- | --- |
| `GET /v1/catalog` | any session of the account | `{"version":n,"document":"<base64>"}`, or 404 `no_catalog` |
| `PUT /v1/catalog` `{"version":n,"document":"<base64>"}` | a board's session (a host's: 403 `wrong_session`) | `{"version":n+1}`; 409 `stale` when `n` isn't the current version (0: none yet); 400 `invalid_version`/`invalid_document`; 413 `too_large` (over 1 MB) |

One row per account in D1 (`migrations/0005_catalog.sql`).

## Writing: version, `stale`, merge

As the vault: a writer reads `{version, document}`, merges its change in, and `PUT`s with the
version it read; on `stale` it reads again and repeats. The merge is three-way
(`CatalogCodec.merge`): the server's document, minus what this writer held at its last
round (`base`) and no longer holds, plus what it holds new or changed since then. Entries
are matched by id, so another board's additions and changes to entries this writer left
alone survive. A writer keeps as `base` only what it holds itself, never another board's
entries it doesn't keep, or they would look removed by it next round.

## The Mac

`CatalogSync.keep` runs every 30 seconds while signed in (`catalog.base`, 0600, next to the
database, is its base). Each round sends up this Mac's organizations, projects, its own
worktrees (git's list) and the hosts' worktrees it last listed, and adds to the database what
others added: organizations, projects of a known organization, hosts' worktrees of a known
project. Removals made elsewhere aren't applied on the Mac: forgetting a project there stays
the user's call (it stays out of the catalog until this Mac changes it).

## Creating from a phone

The phone writes the record and runs git itself; the Mac only picks the record up.

1. **Project**: the phone adds `{organization, name, path}` to the document (read, merge,
   `PUT`, repeat on `stale`). A clone on a host: first the phone runs `git clone` on that host
   over the core channel (`CoreRequest.run`), into the host's clone of `path`.
2. **Worktree on a host**: the phone runs `git worktree add` in the host's clone over the core
   channel (`CoreRequest.run`), then adds the worktree (and the clone, `isMain`, if the
   catalog lacked it) to the document.
3. The Mac's next round adds both to its database; its own listing of that host then keeps
   them current.

A phone can't make a worktree on a Mac's own folders (`board:` hosts): no core channel reaches
them. Its side is the phone's work (T5).

## Sealing

Later, as the vault: `CatalogCodec.encode`/`decode` seal and open with the account's vault key;
the server is unchanged (it already treats the document as bytes).
