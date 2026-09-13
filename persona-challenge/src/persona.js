// Persona embedded-flow wrapper.
//
// The Persona SDK (CDN global `Persona`) renders the real identity
// verification widget on top of the page. We drive it with a server-created
// inquiry (inquiryId + sessionToken) so the run is bound to our gate
// session's reference-id, and we never construct it client-side from a
// template id — the API key stays on the backend.
//
// Resolves { status } on onComplete, rejects { reason: "cancel" | "error" }
// when the widget closes any other way.

export function openPersonaFlow({ inquiryId, sessionToken }) {
  return new Promise((resolve, reject) => {
    if (!window.Persona?.Client) {
      reject(new Error("Persona SDK failed to load."));
      return;
    }
    const client = new window.Persona.Client({
      inquiryId,
      sessionToken,
      onReady: () => client.open(),
      onComplete: ({ status }) => {
        client.destroy();
        resolve({ status });
      },
      onCancel: () => {
        client.destroy();
        reject(Object.assign(new Error("Verification closed."), { reason: "cancel" }));
      },
      onError: (err) => {
        client.destroy();
        reject(Object.assign(err instanceof Error ? err : new Error("Verification failed."), { reason: "error" }));
      },
    });
  });
}
