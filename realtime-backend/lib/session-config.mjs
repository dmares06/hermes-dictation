export const realtimeSession = Object.freeze({
  type: "realtime",
  model: "gpt-realtime-2.1",
  instructions: [
    "You are Hermes, Dylan's concise and capable personal voice assistant.",
    "Speak naturally, warmly, and briefly. Do not sound like a menu or repeat the user's request.",
    "Let the user finish speaking. Ask one clear follow-up when required information is missing.",
    "Use only the provided functions for external actions.",
    "For apps or workflows not in the destination list, use run_shortcut only when the user names an existing Apple Shortcut.",
    "A function call prepares an action for review; it never means the action has already happened.",
    "Never claim a message was sent, a note was saved, or an app action completed until the client reports success.",
  ].join(" "),
  audio: {
    input: {
      transcription: {
        model: "gpt-4o-mini-transcribe",
      },
      turn_detection: {
        type: "semantic_vad",
        eagerness: "high",
        create_response: true,
        interrupt_response: true,
      },
    },
    output: {
      voice: "marin",
      speed: 1.08,
    },
  },
  tools: [
    {
      type: "function",
      name: "prepare_message",
      description: "Prepare an iPhone Messages draft for the user to review and send.",
      parameters: {
        type: "object",
        properties: {
          body: { type: "string", description: "The complete message body." },
        },
        required: ["body"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "prepare_email",
      description: "Prepare an email draft for the user to review in their mail app.",
      parameters: {
        type: "object",
        properties: {
          recipient: { type: "string", description: "One recipient email address." },
          subject: { type: "string", description: "The email subject." },
          body: { type: "string", description: "The complete email body." },
        },
        required: ["recipient", "subject", "body"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "prepare_note",
      description: "Prepare note text for the user to review and share to Apple Notes.",
      parameters: {
        type: "object",
        properties: {
          body: { type: "string", description: "The complete note text." },
        },
        required: ["body"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "open_destination",
      description: "Prepare a supported destination to open after user confirmation.",
      parameters: {
        type: "object",
        properties: {
          destination: {
            type: "string",
            enum: [
              "gmail",
              "settings",
              "maps",
              "calendar",
              "music",
              "youtube",
              "spotify",
            ],
            description: "The allowlisted destination to open.",
          },
        },
        required: ["destination"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "run_shortcut",
      description: "Prepare an existing Apple Shortcut to run after explicit user confirmation.",
      parameters: {
        type: "object",
        properties: {
          name: {
            type: "string",
            description: "The exact name of an Apple Shortcut that already exists on the iPhone.",
          },
        },
        required: ["name"],
        additionalProperties: false,
      },
    },
  ],
  tool_choice: "auto",
});
