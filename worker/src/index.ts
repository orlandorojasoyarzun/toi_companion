/**
 * toi_companion proxy — Cloudflare Worker.
 *
 * Single-tenant proxy in front of OpenAI. The macOS app POSTs to /chat
 * with the user's transcript; the Worker forwards the body to OpenAI
 * with the API key (never exposed to the app) and streams the SSE
 * response back, gated by the X-Toi-Companion-Secret header so a
 * leaked worker.dev URL can't be used to run up the bill.
 */

import { authorise } from "./auth";

export interface Env {
  // Set via `wrangler secret put`.
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
  async fetch(req: Request, env: Env): Promise<Response> {
    // CORS preflight — short-circuit, no auth.
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    const url = new URL(req.url);

    // Health check.
    if (url.pathname === "/" && (req.method === "GET" || req.method === "HEAD")) {
      return new Response("ok", { status: 200, headers: CORS });
    }

    // Chat proxy. Only POST — anything else is a 405.
    if (url.pathname === "/chat") {
      if (req.method !== "POST") {
        return new Response("method not allowed", { status: 405, headers: CORS });
      }
      return handleChat(req, env);
    }

    return new Response("not found", { status: 404, headers: CORS });
  },
};

async function handleChat(req: Request, env: Env): Promise<Response> {
  // Auth — constant-time shared-secret check. Reject before reading the
  // body so a flood of bad-secret requests doesn't make us pay for parse.
  if (!authorise(req, env.TOI_SHARED_SECRET)) {
    return new Response("unauthorized", { status: 401, headers: CORS });
  }

  // Pass-through: read the body as text, forward verbatim. Don't parse
  // it on our side — the macOS app sends the exact OpenAI chat shape,
  // and OpenAI accepts it. Parsing here would just be a place to break
  // things.
  const body = await req.text();

  // Forward to OpenAI with the API key attached.
  const upstream = await fetch(`${env.OPENAI_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      "authorization": `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body,
  });

  if (!upstream.ok || !upstream.body) {
    // Pass upstream status + body so the app can show a useful error
    // ("429 Slow down…", "401 invalid API key", etc.).
    const text = upstream.body ? await upstream.text() : "upstream error";
    return new Response(text, {
      status: upstream.status,
      headers: { "content-type": "application/json", ...CORS },
    });
  }

  // Stream the SSE response straight through. We don't parse or
  // transform — OpenAI's `data: {...}\n\n` chunks go to the app as-is.
  return new Response(upstream.body, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache, no-transform",
      // Don't close the connection prematurely on the proxy hop.
      "x-accel-buffering": "no",
      ...CORS,
    },
  });
}
