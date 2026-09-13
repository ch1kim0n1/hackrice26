// Store only the opaque session token; credentials never leave form memory.
const SESSION_KEY = "nutriquest.session";

export function saveSession(auth) {
  localStorage.setItem(SESSION_KEY, auth.token);
}

export async function restoreSession() {
  const token = localStorage.getItem(SESSION_KEY);
  if (!token) return null;
  const response = await fetch("/auth/me", {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  if (response.status === 401) {
    localStorage.removeItem(SESSION_KEY);
    return null;
  }
  if (!response.ok) throw new Error("Could not check your session. Please try again.");
  return { ...await response.json(), token };
}

export async function logout() {
  const token = localStorage.getItem(SESSION_KEY);
  if (token) {
    const response = await fetch("/auth/logout", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!response.ok) throw new Error("Could not log out. Please try again.");
  }
  localStorage.removeItem(SESSION_KEY);
}
