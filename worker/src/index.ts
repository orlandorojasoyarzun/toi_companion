/**
 * toi_companion proxy — Cloudflare Worker.
 *
 * Phase 0: stub. Returns "ok" on GET / so we can verify the deploy.
 * Phase 4: adds POST /chat which forwards the OpenAI-shaped body to OpenAI
 *          and streams the response back, gated by X-Toi-Companion-Secret.
 */

export interface Env {
  // Set via `wrangler secret put`. Reserved for Phase 4.
  OPENAI_API_KEY: string;
  TOI_SHARED_SECRET: string;

  // Set in wrangler.toml [vars].
  OPENAI_BASE_URL: string;
  DEFAULT_MODEL: string;
}

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, HEAD, POST, OPTIONS",
  "access-control-allow-headers": "content-type, x-toi-companion-secret",
  "access-control-max-age": "86400",
};

export default {
  async fetch(req: Request, _env: Env): Promise<Response> {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    const url = new URL(req.url);

    if (url.pathname === "/" && (req.method === "GET" || req.method === "HEAD")) {
      return new Response("ok", { status: 200, headers: CORS });
    }

    return new Response("not found", { status: 404, headers: CORS });
  },
};