declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("./index");
    durableNamespaces: "HostRelay";
  }
  interface Env {
    DB: D1Database;
    RELAY: DurableObjectNamespace<import("./relay").HostRelay>;
    GITHUB_CLIENT_ID: string;
  }
}
interface Env extends Cloudflare.Env {}
