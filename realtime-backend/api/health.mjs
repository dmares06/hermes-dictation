import { gmailConfigured } from "../lib/gmail.mjs";

export default function handler(request, response) {
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return response.status(405).json({ error: "method_not_allowed" });
  }

  return response.status(200).json({
    status: "ok",
    service: "whisperdict-realtime",
    configured: Boolean(process.env.OPENAI_API_KEY && process.env.WHISPERDICT_CLIENT_TOKEN),
    gmail: gmailConfigured(),
  });
}
