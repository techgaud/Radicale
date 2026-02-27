// ─────────────────────────────────────────────────────────────────────────────
// email-worker.js
//
// Cloudflare Email Worker. Receives mail forwarded by Email Routing,
// reads the raw message bytes, and POSTs them to the ingest endpoint on
// the home server along with the destination address.
//
// Required Worker secrets (set via Cloudflare dashboard or wrangler secret):
//   INGEST_URL   - https://inbound.natecalvert.org/ingest
//   INGEST_TOKEN - shared secret, must match INGEST_TOKEN in config.env
//
// The Worker throws on non-2xx responses so Cloudflare will retry delivery
// and the sender receives a bounce if the endpoint is persistently down.
// ─────────────────────────────────────────────────────────────────────────────

export default {
  async email(message, env, ctx) {
    const rawEmail = await new Response(message.raw).arrayBuffer();

    let response;
    try {
      response = await fetch(env.INGEST_URL, {
        method: "POST",
        headers: {
          "Content-Type": "message/rfc822",
          "X-Ingest-Token": env.INGEST_TOKEN,
          "X-Destination": message.to,
        },
        body: rawEmail,
      });
    } catch (err) {
      // Network-level failure — throw so Cloudflare retries
      throw new Error(`Ingest request failed: ${err.message}`);
    }

    if (!response.ok) {
      const body = await response.text().catch(() => "(no body)");
      throw new Error(`Ingest returned ${response.status}: ${body}`);
    }
  },
};
