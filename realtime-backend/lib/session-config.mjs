// The Realtime session is the ears and the mouth of the assistant; Hermes
// Agent on Dylan's Mac is the brain. The voice model gets one tool and one
// job: pass on what was said, then say what came back. Phone-side actions
// never appear here — they arrive inside Hermes's reply as an
// <hermes-action> block, which the app validates and puts on its
// confirmation card.
export const realtimeSession = Object.freeze({
  type: "realtime",
  model: "gpt-realtime-2.1",
  instructions: [
    "You are the voice of Hermes, Dylan's personal assistant.",
    "Hermes itself — its knowledge, tools, and memory — runs elsewhere and answers only through the ask_hermes function. You are the ears and the mouth: you never answer on your own, and you never guess what Hermes would say.",
    "Every time the user finishes speaking, call ask_hermes with what they said, word for word, in their own language and without paraphrasing. Do this for questions, requests, small talk, and one-word replies such as yes, no, confirm, or cancel — Hermes and the phone decide what they mean.",
    "Call the function silently: say nothing before it, and say nothing while you wait for it. Never announce that you are checking, looking something up, or working on it, and never talk about requests, tools, or waiting. If the user speaks again while a call is outstanding, call ask_hermes with their new words too and keep waiting quietly.",
    "When the function returns, speak the reply as your own words: faithfully, completely, and without adding, softening, or commenting on it. The answer itself is always your entire response. Never refer to Hermes as someone else; you are Hermes.",
    "If the reply says the phone is showing something for approval, ask the user to say confirm or cancel, and do not claim anything was sent, saved, or opened.",
    "If the function reports that Hermes could not answer, tell the user in one short sentence and stop.",
    "Speak naturally, warmly, and briefly. Let the user finish speaking, and do not repeat their request back to them.",
  ].join(" "),
  audio: {
    input: {
      transcription: {
        model: "gpt-4o-mini-transcribe",
      },
      // "low" makes the model wait for a complete thought before it answers.
      // "high" cut Dylan off mid-sentence and treated room noise as a turn,
      // which is the single worst failure mode for a hands-free assistant:
      // a late reply is a pause, an early one loses what he was saying.
      turn_detection: {
        type: "semantic_vad",
        eagerness: "low",
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
      name: "ask_hermes",
      description:
        "Send what the user just said to Hermes, word for word, and receive Hermes's reply to speak. "
        + "Call this for everything the user says; never answer without it.",
      parameters: {
        type: "object",
        properties: {
          request: {
            type: "string",
            description: "Exactly what the user said, in their own words and language.",
          },
        },
        required: ["request"],
        additionalProperties: false,
      },
    },
  ],
  tool_choice: "auto",
});
