// Persona embedded-flow wrapper — same pattern as
// persona-challenge/src/persona.js. Driven by a server-created inquiry
// (inquiryId + sessionToken); the API key never touches the browser.
//
// Resolves { status: "opened" } once the widget closes (complete OR cancel)
// — the *real* status is only ever trusted from the backend's own read of
// Persona (POST /demo/persona/complete), never from this callback.

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
      onComplete: () => {
        client.destroy();
        resolve({ status: "opened" });
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
