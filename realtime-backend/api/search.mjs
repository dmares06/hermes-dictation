import { authorized } from "../lib/auth.mjs";
import { readJSONBody } from "../lib/json-body.mjs";
import { search, SearchError, validateQuery } from "../lib/search.mjs";

export default async function handler(request, response, context = {}) {
  const env = context.env ?? process.env;
  const doFetch = context.fetch ?? fetch;

  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "method_not_allowed" });
  }

  const clientToken = env.WHISPERDICT_CLIENT_TOKEN;
  if (!clientToken || !env.OPENAI_API_KEY) {
    return response.status(503).json({ error: "service_not_configured" });
  }
  if (!authorized(request.headers.authorization, clientToken)) {
    return response.status(401).json({ error: "unauthorized" });
  }

  let query;
  try {
    query = validateQuery(await readJSONBody(request));
  } catch (error) {
    return response.status(400).json({ error: error instanceof SearchError ? error.code : "invalid_request" });
  }

  try {
    const { answer, sources } = await search(query, { env, fetch: doFetch });
    return response.status(200).json({ ok: true, answer, sources });
  } catch (error) {
    console.error("Web search failed", error instanceof Error ? error.message : "unknown");
    return response.status(502).json({ error: "search_failed" });
  }
}
