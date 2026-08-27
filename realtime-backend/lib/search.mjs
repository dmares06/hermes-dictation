const MAXIMUM_QUERY_LENGTH = 400;
const MAXIMUM_ANSWER_LENGTH = 1200;

export class SearchError extends Error {
  constructor(code) {
    super(code);
    this.name = "SearchError";
    this.code = code;
  }
}

export function validateQuery(payload) {
  if (!payload || typeof payload !== "object") throw new SearchError("invalid_request");
  const query = typeof payload.query === "string" ? payload.query.trim() : "";
  if (!query) throw new SearchError("invalid_query");
  if (query.length > MAXIMUM_QUERY_LENGTH) throw new SearchError("query_too_long");
  return query;
}

/// Pulls the spoken answer and its citations out of a Responses payload.
///
/// The answer is capped because it is going to be read aloud: a wall of text
/// is worse than a short one over voice, and the model can always be asked
/// for more.
export function extractAnswer(payload) {
  const direct = typeof payload?.output_text === "string" ? payload.output_text.trim() : "";
  const messages = Array.isArray(payload?.output)
    ? payload.output.filter((item) => item?.type === "message")
    : [];
  const parts = messages.flatMap((message) => (Array.isArray(message.content) ? message.content : []));
  const text = direct || parts.map((part) => part?.text ?? "").join(" ").trim();

  const sources = [];
  const seen = new Set();
  for (const part of parts) {
    for (const annotation of part?.annotations ?? []) {
      if (annotation?.type !== "url_citation" || !annotation.url || seen.has(annotation.url)) continue;
      seen.add(annotation.url);
      sources.push({ title: annotation.title ?? annotation.url, url: annotation.url });
    }
  }

  return {
    answer: text.slice(0, MAXIMUM_ANSWER_LENGTH),
    sources: sources.slice(0, 5),
  };
}

export async function search(query, { env, fetch: doFetch }) {
  const response = await doFetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: env.SEARCH_MODEL || "gpt-5.6",
      tools: [{ type: "web_search" }],
      // Spoken, not written: the caller is a voice assistant reading this out.
      instructions:
        "Answer for a voice assistant to read aloud. Two or three sentences, "
        + "no markdown, no bullet points, no URLs in the prose. State the date "
        + "of anything time-sensitive.",
      input: query,
    }),
    signal: AbortSignal.timeout(25_000),
  });

  if (!response.ok) throw new SearchError("search_failed");
  return extractAnswer(await response.json());
}
