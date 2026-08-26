import { createHash, timingSafeEqual } from "node:crypto";

export function authorized(authorizationHeader, expectedToken) {
  if (!expectedToken || typeof authorizationHeader !== "string") return false;

  const prefix = "Bearer ";
  if (!authorizationHeader.startsWith(prefix)) return false;

  const suppliedToken = authorizationHeader.slice(prefix.length);
  const supplied = Buffer.from(suppliedToken);
  const expected = Buffer.from(expectedToken);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export function safetyIdentifier(clientToken) {
  return createHash("sha256").update(`whisperdict:${clientToken}`).digest("hex");
}
