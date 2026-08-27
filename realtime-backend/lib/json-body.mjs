export async function readJSONBody(request, maximumBytes = 16_384) {
  if (request.body && typeof request.body === "object" && !Buffer.isBuffer(request.body)) {
    return request.body;
  }
  let text;
  if (typeof request.body === "string") {
    text = request.body;
  } else if (Buffer.isBuffer(request.body)) {
    text = request.body.toString("utf8");
  } else {
    const chunks = [];
    let byteCount = 0;
    for await (const chunk of request) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      byteCount += buffer.length;
      if (byteCount > maximumBytes) throw new JSONBodyError("too_large");
      chunks.push(buffer);
    }
    text = Buffer.concat(chunks).toString("utf8");
  }
  if (Buffer.byteLength(text, "utf8") > maximumBytes) throw new JSONBodyError("too_large");
  try {
    return JSON.parse(text);
  } catch {
    throw new JSONBodyError("invalid");
  }
}

export class JSONBodyError extends Error {
  constructor(code) {
    super(code === "too_large" ? "The request body is too large." : "A valid JSON body is required.");
    this.name = "JSONBodyError";
    this.code = code;
  }
}
