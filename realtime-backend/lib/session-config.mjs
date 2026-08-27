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
    "Notes are saved inside Hermes with save_note; use prepare_note only when the user names Apple Notes.",
    "For reminders use create_reminder with an ISO 8601 due time when the user gives one; today's date is provided in the session.",
    "For anything with a time and a place on it — a meeting, an appointment, a flight, dinner — use create_calendar_event, not a reminder. Always call get_datetime first so the start time you send is real, and send it as ISO 8601 with the user's UTC offset. Give an end time when the user says how long it runs; otherwise leave it out and it becomes an hour.",
    "Use list_calendar_events to answer anything about the user's schedule, and check it before proposing a time so you do not double-book them.",
    "Use search_email to answer questions about mail the user has received and to get the context for a reply. It takes a Gmail search query, so prefer targeted ones like from:sam newer_than:7d. Never read a whole message aloud; summarise it.",
    "When the user asks to send an email, use send_email; use prepare_email only when they ask for a draft to review in their mail app. Either way the client asks the user to confirm first.",
    "search_web, search_notes, list_reminders, list_calendar_events, search_email and get_datetime read only: they run immediately, need no confirmation, and return their result to you. Answer from their result rather than from memory.",
    "Use search_web whenever the answer depends on current facts — news, prices, scores, weather, opening hours, anything after your training data. Never guess at these, and never state a fact you did not verify as though you had.",
    "Call get_datetime before any reasoning about today, tomorrow, or elapsed time; do not assume the date.",
    "Summarise what a tool returned in one or two spoken sentences. Do not read out URLs.",
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
      name: "send_email",
      description: "Send an email from the user's connected Gmail account after the user confirms.",
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
      name: "save_note",
      description: "Save a note inside Hermes after the user confirms. Preferred over prepare_note.",
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
      name: "create_reminder",
      description: "Create a reminder in the iPhone Reminders app after the user confirms.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string", description: "What to remind the user about, as a short imperative." },
          due: {
            type: "string",
            description: "Optional due time as an ISO 8601 timestamp with timezone offset, e.g. 2026-08-27T09:00:00-04:00.",
          },
        },
        required: ["title"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "create_calendar_event",
      description:
        "Create an event in the user's calendar after the user confirms. Use for anything with a time and a place: "
        + "meetings, appointments, travel, dinner. Call get_datetime first so the start time is correct.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string", description: "What the event is, as a short noun phrase." },
          start: {
            type: "string",
            description: "When it starts, as an ISO 8601 timestamp with the user's UTC offset, e.g. 2026-08-27T09:00:00-04:00.",
          },
          end: {
            type: "string",
            description: "Optional end time in the same format. Omit for a one-hour event.",
          },
          all_day: { type: "boolean", description: "True for an event with no particular time of day." },
          location: { type: "string", description: "Optional place, as the user said it." },
          notes: { type: "string", description: "Optional details to keep with the event." },
        },
        required: ["title", "start"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "list_calendar_events",
      description:
        "List the user's upcoming calendar events. Runs immediately without user confirmation. "
        + "Use to answer questions about their schedule and to check for conflicts before proposing a time.",
      parameters: {
        type: "object",
        properties: {
          days: {
            type: "integer",
            description: "How many days ahead to look. Defaults to 7.",
          },
        },
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "search_email",
      description:
        "Search the user's connected Gmail and return the sender, subject, date, and a short snippet of each match. "
        + "Reads only; runs immediately without user confirmation. Use to answer questions about mail they have "
        + "received and to gather context before drafting a reply.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description:
              "A Gmail search query, e.g. 'from:sam@example.com newer_than:7d' or 'subject:invoice'. "
              + "Empty returns the past week's inbox.",
          },
        },
        required: ["query"],
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
      name: "search_web",
      description:
        "Search the web and return a short spoken answer with sources. Runs immediately without user confirmation. "
        + "Use for anything current: news, weather, prices, scores, opening hours, or facts newer than your training data.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "What to search for, as a natural-language question." },
        },
        required: ["query"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "search_notes",
      description:
        "Search the notes saved in Hermes and return the matches. Runs immediately without user confirmation. "
        + "Use when the user asks what they wrote down or saved.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Words to look for. Empty returns the most recent notes." },
        },
        required: ["query"],
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "list_reminders",
      description:
        "List the user's upcoming reminders. Runs immediately without user confirmation. "
        + "Use when the user asks what they have coming up or what they need to do.",
      parameters: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
    },
    {
      type: "function",
      name: "get_datetime",
      description:
        "Get the current date, time, and time zone on the user's iPhone. Runs immediately without user confirmation. "
        + "Call this before any reasoning that depends on today's date.",
      parameters: {
        type: "object",
        properties: {},
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
