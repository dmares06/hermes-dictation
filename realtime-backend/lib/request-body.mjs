export async function readSDPBody(request, maximumBytes = 65_536) {
  if (typeof request.body === "string") {
    return validate(request.body, maximumBytes);
  }
  if (Buffer.isBuffer(request.body)) {
    return validate(request.body.toString("utf8"), maximumBytes);
  }

  const chunks = [];
  let byteCount = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    byteCount += buffer.length;
    if (byteCount > maximumBytes) throw new SDPBodyError("too_large");
    chunks.push(buffer);
  }
  return validate(Buffer.concat(chunks).toString("utf8"), maximumBytes);
}

function validate(value, maximumBytes) {
  if (Buffer.byteLength(value, "utf8") > maximumBytes) throw new SDPBodyError("too_large");
  const trimmed = value.trim();
  if (!trimmed || !trimmed.startsWith("v=0")) throw new SDPBodyError("invalid");
  return trimmed;
}

export class SDPBodyError extends Error {
  constructor(code) {
    super(code === "too_large" ? "The SDP offer is too large." : "A valid SDP offer is required.");
    this.name = "SDPBodyError";
    this.code = code;
  }
}
