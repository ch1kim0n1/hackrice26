import { restoreSession, logout } from "./session.js";

const link = document.getElementById("account-link");
try {
  const auth = await restoreSession();
  if (auth) {
    link.textContent = "Log out";
    link.setAttribute("aria-label", `Log out ${auth.account.displayName || auth.account.username}`);
    link.addEventListener("click", async (event) => {
      event.preventDefault();
      if (link.getAttribute("aria-disabled") === "true") return;
      link.setAttribute("aria-disabled", "true");
      try {
        await logout();
        location.replace("/");
      } catch {
        link.textContent = "Retry log out";
        link.removeAttribute("aria-disabled");
      }
    });
  }
} catch {
  // Keep the login link usable when the API or browser storage is unavailable.
}
