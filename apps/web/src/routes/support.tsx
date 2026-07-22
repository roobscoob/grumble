import { Link, createFileRoute } from "@tanstack/react-router";
import { Mark } from "../components/Mark";

export const Route = createFileRoute("/support")({
  component: Support,
});

const REPO = "https://github.com/fcjr/grumble";
const SUPPORT_EMAIL = "support@grumble.computer";

const FAQS = [
  {
    question: "Dictation starts, but nothing gets typed.",
    answer:
      "Grumble needs accessibility access to type into the focused text field. Open System Settings, go to Privacy & Security, then Accessibility, and make sure Grumble is enabled. If it is already enabled and still not working, toggle it off and back on, then restart Grumble.",
  },
  {
    question: "The hotkey does not do anything.",
    answer:
      "The default hotkey is ⌥+Space. Another app may have claimed it; you can change Grumble's hotkey from the menu bar icon under Settings. Also check that Grumble is running: you should see its icon in the menu bar.",
  },
  {
    question: "Does my audio ever leave my Mac?",
    answer:
      "No. Transcription runs entirely on-device using a local speech model. Audio is processed in memory, never written to disk, and never sent anywhere. See the privacy policy for details.",
  },
  {
    question: "Why does Grumble download something on first launch?",
    answer:
      "The speech model is downloaded once from Hugging Face on first launch (or when you switch models). After that, dictation works fully offline.",
  },
  {
    question: "What Macs does Grumble support?",
    answer:
      "Grumble requires macOS 14 or later on Apple Silicon (M1 or newer). Intel Macs are not supported.",
  },
  {
    question: "How do I update Grumble?",
    answer:
      "The direct-download version checks for updates automatically and can update itself from the menu bar. The Mac App Store version is updated through the App Store like any other app.",
  },
] as const;

function Support() {
  return (
    <div className="min-h-screen">
      <header className="mx-auto flex max-w-5xl items-center justify-between px-6 py-6">
        <Link to="/" className="flex items-center gap-3">
          <Mark className="h-7 w-9" />
          <span className="panel-label text-lg text-bone">Grumble</span>
        </Link>
        <a
          href={REPO}
          className="panel-label text-sm text-bone-dim transition-colors hover:text-amber focus-visible:text-amber"
        >
          GitHub
        </a>
      </header>

      <main className="mx-auto max-w-3xl px-6 pb-24">
        <section className="py-16">
          <p className="panel-label mb-4 text-sm text-amber">Support</p>
          <h1 className="panel-label text-5xl leading-none text-bone">
            Something not working?
          </h1>
          <p className="mt-6 max-w-xl text-lg leading-relaxed text-bone-dim">
            Check the answers below first. If you are still stuck, email{" "}
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              {SUPPORT_EMAIL}
            </a>{" "}
            and a human will get back to you.
          </p>
        </section>

        <section className="grid gap-4">
          {FAQS.map((faq) => (
            <div
              key={faq.question}
              className="rounded-2xl border border-white/8 bg-faceplate p-6"
            >
              <h2 className="panel-label mb-3 text-lg text-bone">
                {faq.question}
              </h2>
              <p className="text-sm leading-relaxed text-bone-dim">
                {faq.answer}
              </p>
            </div>
          ))}
        </section>

        <section className="mt-8 rounded-2xl border border-white/8 bg-faceplate px-6 py-5">
          <p className="text-center text-sm text-bone-dim">
            Found a bug? Email{" "}
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              {SUPPORT_EMAIL}
            </a>{" "}
            or{" "}
            <a
              href={`${REPO}/issues`}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              open an issue on GitHub
            </a>
            .
          </p>
        </section>
      </main>

      <footer className="border-t border-white/8">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-2 px-6 py-6 text-xs text-bone-dim">
          <span>© 2026 Left Shift Logical, LLC</span>
          <span>
            Built on{" "}
            <a
              href="https://github.com/FluidInference/FluidAudio"
              className="text-amber-dim transition-colors hover:text-amber"
            >
              FluidAudio
            </a>{" "}
            and NVIDIA Parakeet
          </span>
        </div>
      </footer>
    </div>
  );
}
